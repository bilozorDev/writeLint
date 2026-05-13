import Foundation
import AppKit
import OSLog

/// In-app "Help & feedback" channel. Opens the user's default mail client
/// via `mailto:` with a pre-filled body containing app metadata and (opt-in
/// by default) the last hour of `Hexaget.WriteLint` log entries. We never
/// make a network call from the app — the user's mail client is the final
/// consent + send gate; the in-app Preview disclosure is the first-line
/// consent gate.
///
/// Wired to the "Compose feedback in Mail" button in
/// `Views/Settings/FeedbackPage.swift`. The recipient is hard-coded to the
/// dev's address; replace `recipient` to redirect.
enum FeedbackService {
    /// Where feedback emails go. Matches the commit `Co-Authored-By` for
    /// the rest of the project.
    static let recipient = "bilozor.dev@gmail.com"

    /// Cap for the assembled mailto body in UTF-8 bytes. macOS Mail
    /// handles ~100KB cleanly, but other mail clients (corporate webmail
    /// shims, third-party apps) sometimes truncate around 32KB. 30KB is
    /// a safe floor and still captures a substantial log tail — the
    /// median app session emits well under that.
    static let mailtoBodyCapBytes = 30 * 1024

    /// Result surfaced to the caller (FeedbackPage). `.opened` and
    /// `.mailClientUnavailable` both mean we successfully composed the
    /// URL; `.composeFailed` means URL construction itself fell over.
    enum SendResult: Equatable {
        case opened
        case composeFailed
        case mailClientUnavailable
    }

    /// Snapshot of the app/system context to embed in the feedback body.
    /// `backendLabel` carries the provider+model identifier but never an
    /// `apiKey` — see the API-key safety unit test.
    struct Metadata: Equatable {
        let appVersion: String
        let buildNumber: String
        let osVersion: String
        let locale: String
        let timestamp: String
        let backendLabel: String
        let modelAvailability: String

        /// Build a Metadata snapshot from current app + store state.
        /// Pure — does not perform I/O — so callers can stamp the
        /// `timestamp` field deterministically in tests by passing an
        /// override (this overload always reads `Date()`; tests
        /// construct `Metadata` directly).
        @MainActor
        static func capture(store: PromptStore, availability: ModelAvailability) -> Metadata {
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
            let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
            let locale = Locale.current.identifier
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let backendLabel: String
            switch store.activeBackend {
            case .onDevice: backendLabel = "on-device"
            case .claude:   backendLabel = "claude:\(store.selectedClaudeModel.rawValue)"
            case .openai:   backendLabel = "openai:\(store.selectedOpenAIModel.rawValue)"
            }
            let modelAvailability: String
            switch availability {
            case .available:
                modelAvailability = "available"
            case .unavailable(let reason, let installing):
                modelAvailability = installing ? "unavailable (installing): \(reason)" : "unavailable: \(reason)"
            }
            return Metadata(
                appVersion: appVersion,
                buildNumber: buildNumber,
                osVersion: osVersion,
                locale: locale,
                timestamp: timestamp,
                backendLabel: backendLabel,
                modelAvailability: modelAvailability
            )
        }

        /// Rendered metadata block — one fact per line, no leading or
        /// trailing newline. Stable so the snapshot test in
        /// `FeedbackServiceTests` doesn't churn on format changes.
        var rendered: String {
            """
            App: Linter \(appVersion) (build \(buildNumber))
            macOS: \(osVersion)
            Locale: \(locale)
            Time: \(timestamp)
            Active backend: \(backendLabel)
            Apple Intelligence: \(modelAvailability)
            """
        }
    }

    /// Compose the literal UTF-8 body that will be percent-encoded into
    /// the mailto URL. Used by both `sendFeedback` and the in-app
    /// Preview disclosure (so the user sees the truth, not an
    /// approximation).
    ///
    /// Layout (literal section markers):
    /// ```
    /// <description, or "(no description)">
    ///
    /// --- App info ---
    /// <metadata>
    ///
    /// --- Diagnostic logs (last 1h) ---
    /// <logs, or "Unavailable.">
    /// ```
    /// The trailing Diagnostic-logs section appears only when
    /// `includeLogs` is true.
    static func composeBody(
        description: String,
        includeLogs: Bool,
        logs: String?,
        metadata: Metadata
    ) -> String {
        var parts: [String] = []
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append(trimmed.isEmpty ? "(no description)" : trimmed)
        parts.append("")
        parts.append("--- App info ---")
        parts.append(metadata.rendered)
        if includeLogs {
            parts.append("")
            parts.append("--- Diagnostic logs (last 1h) ---")
            parts.append(logs ?? "Unavailable.")
        }
        return parts.joined(separator: "\n")
    }

    /// Compose the mailto URL. Returns nil if percent-encoding fails on
    /// either subject or body — should not happen in practice but
    /// surfaced as `.composeFailed` if it does.
    ///
    /// Uses an `.urlQueryAllowed` baseline minus `&=?` so query
    /// separators inside subject/body values are encoded properly. The
    /// recipient is constant and ASCII-only — no encoding needed.
    static func composeMailto(body: String, subject: String) -> URL? {
        guard
            let subjectEnc = subject.addingPercentEncoding(withAllowedCharacters: mailtoValueAllowed),
            let bodyEnc = body.addingPercentEncoding(withAllowedCharacters: mailtoValueAllowed)
        else {
            return nil
        }
        return URL(string: "mailto:\(recipient)?subject=\(subjectEnc)&body=\(bodyEnc)")
    }

    /// Character set used to percent-encode subject and body values. Built
    /// from `.urlQueryAllowed` with the query separators (`&`, `=`, `?`)
    /// removed so they get encoded as `%26`, `%3D`, `%3F` inside values.
    private static let mailtoValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=?")
        return set
    }()

    /// Subject derived from the running bundle's marketing version + build
    /// number. Same source as `Metadata.appVersion`/`buildNumber` so
    /// subject and body never disagree.
    static func defaultSubject() -> String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Linter feedback (\(v) build \(b))"
    }

    /// Fetch the last hour of `Hexaget.WriteLint` log entries via
    /// `OSLogStore(scope: .currentProcessIdentifier)`. Runs on a
    /// detached task — `getEntries(at:matching:)` is synchronous I/O,
    /// and holding the main actor across it would jank the Settings
    /// window on slower hosts.
    ///
    /// `budgetBytes` is the UTF-8 budget for the formatted output. If
    /// the formatted blob exceeds budget, the oldest lines are dropped
    /// until it fits and a `... (N older lines omitted)\n` marker is
    /// prepended.
    ///
    /// Returns nil if OSLogStore is unavailable (sandbox refusal,
    /// underlying error, or no matching entries). Caller renders that
    /// as "Unavailable." in the email body.
    ///
    /// Note: `.currentProcessIdentifier` scope limits results to the
    /// current PID — a crashed-and-relaunched session has no history.
    /// This is documented in the FeedbackPage copy ("Logs cover this
    /// session only — reproduce the issue before sending").
    static func collectLogs(budgetBytes: Int) async -> String? {
        await Task.detached(priority: .userInitiated) {
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let position = store.position(date: Date().addingTimeInterval(-3600))
                let predicate = NSPredicate(format: "subsystem == %@", "Hexaget.WriteLint")
                let entries = try store.getEntries(at: position, matching: predicate)
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss.SSS"
                formatter.locale = Locale(identifier: "en_US_POSIX")
                var lines: [String] = []
                for entry in entries {
                    let date = formatter.string(from: entry.date)
                    let category: String
                    if let logEntry = entry as? OSLogEntryLog {
                        category = logEntry.category
                    } else {
                        category = "?"
                    }
                    lines.append("\(date) [\(category)] \(entry.composedMessage)")
                }
                if lines.isEmpty { return nil }
                return trimToBudget(lines: lines, budgetBytes: budgetBytes)
            } catch {
                return nil
            }
        }.value
    }

    /// Pure helper extracted from `collectLogs` so the truncation logic
    /// is unit-testable without an `OSLogStore`. Drops oldest lines
    /// until the joined UTF-8 byte length fits the budget. If anything
    /// was dropped, prepends a `... (N older lines omitted)\n` marker.
    /// Keeps at least one line so the email never shows the marker
    /// alone.
    internal static func trimToBudget(lines: [String], budgetBytes: Int) -> String {
        var remaining = lines
        var omitted = 0
        while remaining.count > 1 {
            let joined = remaining.joined(separator: "\n")
            if joined.utf8.count <= budgetBytes { break }
            remaining.removeFirst()
            omitted += 1
        }
        let body = remaining.joined(separator: "\n")
        if omitted > 0 {
            return "... (\(omitted) older lines omitted)\n" + body
        }
        return body
    }

    /// Assemble the final subject + body the user will send. Captures
    /// metadata, fetches logs (constrained by the mailto byte budget so
    /// the same body can also drive a mailto URL), and stitches them
    /// through `composeBody`. Shared by `sendFeedback` (which opens
    /// `mailto:`) and `copyMessageToClipboard` (which doesn't) so both
    /// paths see the exact same content.
    @MainActor
    static func prepareMessage(
        description: String,
        includeLogs: Bool,
        store: PromptStore,
        availability: ModelAvailability
    ) async -> (subject: String, body: String) {
        let metadata = Metadata.capture(store: store, availability: availability)
        let subject = defaultSubject()

        // Header overhead = body byte cost after percent-encoding, when
        // the logs section is empty. Anything left over is the log
        // budget. Computed against the percent-encoded form because
        // that matches the actual mailto URL size, not the raw text —
        // and we want clipboard copies to fit the same budget so a
        // user who copies and pastes into a mail-client compose form
        // doesn't blow past the URL cap if they later switch to the
        // Compose-in-Mail button.
        let dryBody = composeBody(description: description, includeLogs: includeLogs, logs: "", metadata: metadata)
        let percentEncoded = dryBody.addingPercentEncoding(withAllowedCharacters: mailtoValueAllowed) ?? dryBody
        let overheadBytes = percentEncoded.utf8.count
        let budgetBytes = max(0, mailtoBodyCapBytes - overheadBytes)

        let logs: String? = includeLogs ? await collectLogs(budgetBytes: budgetBytes) : nil
        let body = composeBody(description: description, includeLogs: includeLogs, logs: logs, metadata: metadata)
        return (subject, body)
    }

    /// Render a clipboard-friendly plain-text version of the message —
    /// includes `To:` and `Subject:` headers so a user pasting into
    /// webmail or another tool has the recipient and subject ready to
    /// transcribe. The blank line between headers and body matches
    /// RFC 5322 conventions so paste-into-Mail-as-text Just Works in
    /// most clients.
    static func renderForClipboard(subject: String, body: String) -> String {
        """
        To: \(recipient)
        Subject: \(subject)

        \(body)
        """
    }

    /// Top-level "Compose feedback in Mail" handler. Builds the
    /// message, builds the mailto URL, asks `NSWorkspace` to open it.
    /// Returns `.mailClientUnavailable` when the user has no default
    /// mail client configured — caller surfaces the recipient address
    /// and the "Copy message" affordance so the user can still send
    /// manually.
    @MainActor
    static func sendFeedback(
        description: String,
        includeLogs: Bool,
        store: PromptStore,
        availability: ModelAvailability
    ) async -> SendResult {
        let (subject, body) = await prepareMessage(
            description: description,
            includeLogs: includeLogs,
            store: store,
            availability: availability
        )
        guard let url = composeMailto(body: body, subject: subject) else {
            return .composeFailed
        }
        let opened = NSWorkspace.shared.open(url)
        return opened ? .opened : .mailClientUnavailable
    }

    /// "Copy message" handler — writes the full To/Subject/Body to the
    /// pasteboard so a user with no default mail client (or one who
    /// prefers webmail) can paste into Gmail compose, Slack, an issue
    /// tracker, anywhere. Includes the recipient address in the
    /// pasted text so they don't have to remember it.
    @MainActor
    static func copyMessageToClipboard(
        description: String,
        includeLogs: Bool,
        store: PromptStore,
        availability: ModelAvailability
    ) async {
        let (subject, body) = await prepareMessage(
            description: description,
            includeLogs: includeLogs,
            store: store,
            availability: availability
        )
        let text = renderForClipboard(subject: subject, body: body)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// "Copy logs only" handler — writes just the last hour of
    /// `Hexaget.WriteLint` log entries to the pasteboard. Useful when
    /// the user wants to share logs via chat, an issue tracker, or
    /// any non-email surface without dragging app metadata along.
    /// Budget is the full `mailtoBodyCapBytes` since there's no
    /// description/metadata overhead to subtract.
    @MainActor
    static func copyLogsToClipboard() async -> Bool {
        let logs = await collectLogs(budgetBytes: mailtoBodyCapBytes)
        guard let logs, !logs.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(logs, forType: .string)
        return true
    }
}
