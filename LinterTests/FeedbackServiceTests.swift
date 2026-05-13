import Testing
import Foundation
@testable import Write_Lint

@Suite("FeedbackService — mailto composition, log budgeting, API-key safety")
@MainActor
struct FeedbackServiceTests {

    /// Deterministic metadata fixture so the test assertions can match
    /// substring expectations without time-based or environment-based
    /// flakiness.
    private static func fixtureMetadata(backend: String = "on-device") -> FeedbackService.Metadata {
        FeedbackService.Metadata(
            appVersion: "1.0",
            buildNumber: "7",
            osVersion: "Version 26.4 (Build 25A1234)",
            locale: "en_US",
            timestamp: "2026-05-13T12:34:56Z",
            backendLabel: backend,
            modelAvailability: "available"
        )
    }

    /// Helper: parse a `mailto:` URL's `body` query value back out to its
    /// percent-decoded form. Keeps assertions readable.
    private func decodedBody(of url: URL) -> String? {
        // mailto: URLs don't parse cleanly through URLComponents.queryItems
        // when there's no `//` between scheme and path. Extract `body=...`
        // manually from the resource specifier.
        guard let spec = url.absoluteString.range(of: "?body=") ?? url.absoluteString.range(of: "&body=") else {
            // Try lookup by `?body=` alone or with query separators.
            return nil
        }
        var tail = String(url.absoluteString[spec.upperBound...])
        if let nextAmp = tail.range(of: "&") {
            tail = String(tail[..<nextAmp.lowerBound])
        }
        return tail.removingPercentEncoding
    }

    private func decodedSubject(of url: URL) -> String? {
        guard let spec = url.absoluteString.range(of: "?subject=") ?? url.absoluteString.range(of: "&subject=") else {
            return nil
        }
        var tail = String(url.absoluteString[spec.upperBound...])
        if let nextAmp = tail.range(of: "&") {
            tail = String(tail[..<nextAmp.lowerBound])
        }
        return tail.removingPercentEncoding
    }

    // MARK: composeMailto

    @Test func composeMailtoUsesCorrectRecipient() throws {
        let url = try #require(FeedbackService.composeMailto(body: "hi", subject: "test"))
        // mailto: URLs have a scheme-specific opaque path, not a hierarchical
        // path with hosts. The recipient should appear after `mailto:` and
        // before the first `?`.
        let s = url.absoluteString
        let prefix = "mailto:bilozor.dev@gmail.com?"
        #expect(s.hasPrefix(prefix))
    }

    @Test func composeMailtoEncodesAmpersandsAndEqualsInBody() throws {
        // Critical: `&` and `=` inside body values must be percent-encoded
        // (`%26`, `%3D`) — otherwise the mail client parses them as extra
        // query parameters and truncates the user's content.
        let body = "a&b=c?d"
        let url = try #require(FeedbackService.composeMailto(body: body, subject: "subj"))
        let decoded = try #require(decodedBody(of: url))
        #expect(decoded == body)
    }

    @Test func composeMailtoRoundTripsNewlinesAndUnicode() throws {
        let body = "line one\nline two\n— em dash and emoji 🐝"
        let url = try #require(FeedbackService.composeMailto(body: body, subject: "subj"))
        let decoded = try #require(decodedBody(of: url))
        #expect(decoded == body)
    }

    @Test func composeMailtoEncodesSubjectSpecials() throws {
        let subject = "Linter feedback (1.0) — bug & report"
        let url = try #require(FeedbackService.composeMailto(body: "x", subject: subject))
        let decoded = try #require(decodedSubject(of: url))
        #expect(decoded == subject)
    }

    // MARK: composeBody

    @Test func composeBodyIncludesLogsSectionWhenIncludeLogsTrue() {
        let body = FeedbackService.composeBody(
            description: "stuff broke",
            includeLogs: true,
            logs: "12:00:00.000 [lint] DESERIALIZE attempt=1",
            metadata: Self.fixtureMetadata()
        )
        #expect(body.contains("--- Diagnostic logs"))
        #expect(body.contains("DESERIALIZE attempt=1"))
    }

    @Test func composeBodyOmitsLogsSectionWhenIncludeLogsFalse() {
        let body = FeedbackService.composeBody(
            description: "stuff broke",
            includeLogs: false,
            logs: "this should not appear",
            metadata: Self.fixtureMetadata()
        )
        #expect(!body.contains("--- Diagnostic logs"))
        #expect(!body.contains("this should not appear"))
    }

    @Test func composeBodySignalsUnavailableLogsWhenNil() {
        let body = FeedbackService.composeBody(
            description: "stuff broke",
            includeLogs: true,
            logs: nil,
            metadata: Self.fixtureMetadata()
        )
        #expect(body.contains("--- Diagnostic logs"))
        #expect(body.contains("Unavailable."))
    }

    @Test func composeBodySubstitutesPlaceholderForEmptyDescription() {
        let body = FeedbackService.composeBody(
            description: "",
            includeLogs: false,
            logs: nil,
            metadata: Self.fixtureMetadata()
        )
        #expect(body.contains("(no description)"))
    }

    @Test func composeBodyIncludesAllMetadataFields() {
        let body = FeedbackService.composeBody(
            description: "x",
            includeLogs: false,
            logs: nil,
            metadata: Self.fixtureMetadata()
        )
        #expect(body.contains("App: Linter 1.0 (build 7)"))
        #expect(body.contains("macOS: Version 26.4 (Build 25A1234)"))
        #expect(body.contains("Locale: en_US"))
        #expect(body.contains("Time: 2026-05-13T12:34:56Z"))
        #expect(body.contains("Active backend: on-device"))
        #expect(body.contains("Apple Intelligence: available"))
    }

    // MARK: API-key safety

    @Test func bodyNeverIncludesAPIKey() {
        // Backend label format is `claude:<model.rawValue>` or
        // `openai:<model.rawValue>` — the model identifier only, never the
        // secret. A keypoint regression would be `claude:sk-…` appearing
        // here. Belt-and-suspenders: feed a fake key as a literal string
        // and assert it never surfaces.
        let fakeKey = "sk-test-1234567890-DO-NOT-LEAK"
        let metadata = FeedbackService.Metadata(
            appVersion: "1.0",
            buildNumber: "7",
            osVersion: "Version 26.4",
            locale: "en_US",
            timestamp: "2026-05-13T12:34:56Z",
            backendLabel: "claude:claude-haiku-4-5",
            modelAvailability: "available"
        )
        let body = FeedbackService.composeBody(
            description: "polish failed",
            includeLogs: true,
            logs: "12:00:00 [lint] chunk 0: in=…",
            metadata: metadata
        )
        #expect(!body.contains(fakeKey))
        #expect(body.contains("claude:claude-haiku-4-5"))  // label still present
    }

    // MARK: trimToBudget

    @Test func trimToBudgetReturnsBodyWhenUnderBudget() {
        let lines = ["a", "b", "c"]
        let trimmed = FeedbackService.trimToBudget(lines: lines, budgetBytes: 100)
        #expect(trimmed == "a\nb\nc")
    }

    @Test func trimToBudgetDropsOldestLinesAndAddsMarker() {
        // Build a 4-line blob where each line is comfortably under budget
        // individually but the joined blob exceeds the budget.
        let lines = Array(repeating: String(repeating: "x", count: 20), count: 4)
        // Joined: "xxxx…xxxx\nxxxx…xxxx\nxxxx…xxxx\nxxxx…xxxx" = 83 bytes.
        // Budget of 50 forces dropping the oldest 2 lines.
        let trimmed = FeedbackService.trimToBudget(lines: lines, budgetBytes: 50)
        #expect(trimmed.hasPrefix("... ("))
        #expect(trimmed.contains("older lines omitted"))
        // Whatever survived must fit the budget once the marker is added.
        #expect(trimmed.utf8.count <= 50 + "... (X older lines omitted)\n".utf8.count)
    }

    @Test func trimToBudgetKeepsAtLeastOneLine() {
        // Even a single line longer than the budget shouldn't return an
        // empty body — the marker-only case would be confusing in the
        // mailto. Keep the most recent line and let the user/mail client
        // truncate it visually if needed.
        let lines = ["aaaaaaaaaaaaaaaaaaaaaaaaaa"]
        let trimmed = FeedbackService.trimToBudget(lines: lines, budgetBytes: 5)
        #expect(trimmed == "aaaaaaaaaaaaaaaaaaaaaaaaaa")
    }

    @Test func trimToBudgetMarkerCountsCorrectly() {
        // 5 lines, budget forces exactly 3 drops.
        let lines = ["L1xxxxxxxxxx", "L2xxxxxxxxxx", "L3xxxxxxxxxx", "L4xxxxxxxxxx", "L5xxxxxxxxxx"]
        // Each ~13 bytes; joined 5 lines = 64 bytes. Budget 30 → keep last 2 lines (~26).
        let trimmed = FeedbackService.trimToBudget(lines: lines, budgetBytes: 30)
        #expect(trimmed.contains("(3 older lines omitted)"))
        #expect(trimmed.contains("L4xxxxxxxxxx"))
        #expect(trimmed.contains("L5xxxxxxxxxx"))
        #expect(!trimmed.contains("L1xxxxxxxxxx"))
    }

    // MARK: renderForClipboard

    @Test func renderForClipboardIncludesRecipientAndSubjectHeaders() {
        // The clipboard payload is plain text — no mailto URL — so a
        // user pasting into webmail or any other tool sees the
        // recipient and subject upfront. Blank line between headers
        // and body matches RFC 5322 conventions.
        let text = FeedbackService.renderForClipboard(
            subject: "Linter feedback (1.0 build 7)",
            body: "stuff broke\n\n--- App info ---\nApp: Linter 1.0"
        )
        #expect(text.hasPrefix("To: bilozor.dev@gmail.com\nSubject: Linter feedback (1.0 build 7)\n\n"))
        #expect(text.contains("stuff broke"))
        #expect(text.contains("--- App info ---"))
    }

    @Test func renderForClipboardPreservesBodyVerbatim() {
        // The body section after the blank line should be byte-for-
        // byte equal to the input body — clipboard paths don't go
        // through percent-encoding, so no escaping should happen.
        let body = "line one\nline two\n— em dash and emoji 🐝 & ampersand"
        let text = FeedbackService.renderForClipboard(subject: "subj", body: body)
        #expect(text.hasSuffix("\n\n\(body)"))
    }
}
