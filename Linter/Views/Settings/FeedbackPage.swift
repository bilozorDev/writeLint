import SwiftUI
import AppKit

/// Right-pane content for the "Help & feedback" sidebar entry. Lets the
/// user open their default mail client with a pre-filled body containing
/// app metadata and (opt-in by default) the last hour of `Hexaget.WriteLint`
/// log entries.
///
/// Two-layer consent gate:
///   - **Preview disclosure** in this view shows the exact bytes that will
///     go into the mailto body (description + metadata + logs section).
///   - **The mail client itself** is the final send gate — we hand off via
///     `mailto:`, never make a network request.
///
/// See `Services/FeedbackService.swift` for the body composition and
/// OSLogStore plumbing.
struct FeedbackPage: View {
    @Bindable var store: PromptStore
    let dark: Bool

    @State private var description: String = ""
    @State private var includeLogs: Bool = true
    @State private var previewExpanded: Bool = false
    @State private var sending: Bool = false
    @State private var resultMessage: String?
    @State private var resultIsError: Bool = false
    /// Captured-at-build-time metadata used to render the Preview body. The
    /// actual mailto body is rebuilt at send time so its timestamp is
    /// current — but for the preview we don't want it ticking every second.
    @State private var snapshotMetadata: FeedbackService.Metadata?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.divider(dark)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    descriptionField
                    logsToggle
                    if includeLogs {
                        logsWarning
                    }
                    previewDisclosure
                    composeBar
                    if let resultMessage {
                        resultRow(text: resultMessage)
                    }
                    recipientLine
                }
                .padding(EdgeInsets(top: 16, leading: 22, bottom: 22, trailing: 22))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { refreshSnapshotMetadata() }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Help & feedback")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Palette.text(dark))
            Text("Found a bug or have a suggestion? Compose in your default mail client, or copy the message and send any way you like (Gmail webmail, Slack, etc.). Logs cover this session only — reproduce the issue before sending.")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.sub(dark))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 20, leading: 22, bottom: 14, trailing: 22))
    }

    @ViewBuilder
    private var descriptionField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Description")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.text(dark))
            TextEditor(text: $description)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 120)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Palette.surface(dark))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Palette.divider(dark), lineWidth: 0.5)
                        )
                )
                .overlay(alignment: .topLeading) {
                    if description.isEmpty {
                        Text("Describe what happened (optional). What were you trying to polish? What did you expect, what did you get?")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.sub(dark))
                            .padding(EdgeInsets(top: 16, leading: 13, bottom: 0, trailing: 13))
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    @ViewBuilder
    private var logsToggle: some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("Include diagnostic logs (last hour)", isOn: $includeLogs)
                .toggleStyle(.switch)
                .font(.system(size: 13))
                .foregroundStyle(Palette.text(dark))
            Spacer()
        }
    }

    @ViewBuilder
    private var logsWarning: some View {
        // Strong wording — deterministic, not probabilistic. Default-ON
        // for the toggle relies on this + the Preview disclosure as the
        // first-line consent gate (mail client is the second).
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(Palette.sub(dark))
                .padding(.top, 1)
            Text("Logs include the text you've polished this session, the model's output, and timing/error metadata. They do **not** include API keys or passwords. Use Preview below to see exactly what will be sent.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.sub(dark))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 4, leading: 8, bottom: 0, trailing: 4))
    }

    @ViewBuilder
    private var previewDisclosure: some View {
        DisclosureGroup(isExpanded: $previewExpanded) {
            previewBody
                .padding(.top, 8)
        } label: {
            Text("Preview message body")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.text(dark))
        }
        .tint(Palette.text(dark))
    }

    @ViewBuilder
    private var previewBody: some View {
        // Renders the exact composed body the mail client will see — minus
        // a real log payload (which is fetched at send-time, not on every
        // keystroke). The placeholder makes the section's presence and
        // shape obvious without spamming OSLogStore.
        let metadata = snapshotMetadata ?? defaultPreviewMetadata()
        let previewLogsPlaceholder = "<diagnostic logs — last hour, fetched on send>"
        let body = FeedbackService.composeBody(
            description: description,
            includeLogs: includeLogs,
            logs: previewLogsPlaceholder,
            metadata: metadata
        )
        ScrollView {
            Text(body)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.sub(dark))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxHeight: 200)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Palette.surface(dark))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Palette.divider(dark), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private var composeBar: some View {
        HStack(spacing: 10) {
            Spacer()
            // "Copy logs only" — tertiary. Useful when the user wants
            // to share logs via chat / issue tracker / anywhere
            // non-email, without dragging app metadata along. Always
            // enabled (no dependency on description); disabled while a
            // copy/compose is in flight.
            Button {
                Task { await copyLogsOnly() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Copy logs")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(Palette.text(dark))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Palette.divider(dark), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .disabled(sending)

            // "Copy message" — secondary. Full To/Subject/Body
            // plain-text dump so users without a default mail client
            // (or who prefer webmail) can paste into Gmail compose,
            // Slack, an issue tracker, etc. Same enablement rule as
            // Compose: needs a description or logs to carry signal.
            Button {
                Task { await copyMessage() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Copy message")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(Palette.text(dark))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Palette.divider(dark), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .disabled(!composeEnabled)

            // "Compose in Mail" — primary. Opens the user's default
            // mail client. Returns `.mailClientUnavailable` when no
            // mail handler is configured; the result row tells the
            // user to use Copy message instead.
            Button {
                Task { await compose() }
            } label: {
                HStack(spacing: 6) {
                    if sending {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text(sending ? "Composing…" : "Compose in Mail")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(composeEnabled ? Color.accentColor : Palette.divider(dark))
                )
            }
            .buttonStyle(.plain)
            .disabled(!composeEnabled)
        }
    }

    @ViewBuilder
    private func resultRow(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: resultIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(resultIsError ? .orange : Palette.added)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.text(dark))
                .textSelection(.enabled)
            Spacer()
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Palette.surface(dark))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Palette.divider(dark), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private var recipientLine: some View {
        Text("Sends to \(FeedbackService.recipient)")
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.sub(dark))
    }

    // MARK: - Behavior

    /// True when the Compose button should be tappable. Empty everything
    /// (no description, no logs) carries no diagnostic signal — disable.
    private var composeEnabled: Bool {
        !sending && !(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !includeLogs)
    }

    private func compose() async {
        sending = true
        let availability = FoundationModelService.shared.availability
        let result = await FeedbackService.sendFeedback(
            description: description,
            includeLogs: includeLogs,
            store: store,
            availability: availability
        )
        sending = false
        switch result {
        case .opened:
            resultMessage = "Opening Mail…"
            resultIsError = false
        case .composeFailed:
            resultMessage = "Couldn't compose feedback. Try again."
            resultIsError = true
        case .mailClientUnavailable:
            // No default mail handler — point the user at the Copy
            // message button (which works regardless of mail setup)
            // and stash the recipient on the pasteboard so they can
            // paste it into any webmail compose form.
            resultMessage = "No default mail client. Use “Copy message” and paste into webmail. Address copied: \(FeedbackService.recipient)"
            resultIsError = true
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(FeedbackService.recipient, forType: .string)
        }
    }

    private func copyMessage() async {
        sending = true
        let availability = FoundationModelService.shared.availability
        await FeedbackService.copyMessageToClipboard(
            description: description,
            includeLogs: includeLogs,
            store: store,
            availability: availability
        )
        sending = false
        resultMessage = "Message copied to clipboard. Paste into your mail app or webmail."
        resultIsError = false
    }

    private func copyLogsOnly() async {
        sending = true
        let ok = await FeedbackService.copyLogsToClipboard()
        sending = false
        if ok {
            resultMessage = "Logs copied to clipboard."
            resultIsError = false
        } else {
            resultMessage = "No logs available yet — try the polish that triggered the issue, then try again."
            resultIsError = true
        }
    }

    private func refreshSnapshotMetadata() {
        snapshotMetadata = FeedbackService.Metadata.capture(
            store: store,
            availability: FoundationModelService.shared.availability
        )
    }

    /// Fallback for the Preview render before `onAppear` populates the
    /// snapshot. Mirrors what `Metadata.capture` would emit so the preview
    /// shape is correct even pre-onAppear.
    private func defaultPreviewMetadata() -> FeedbackService.Metadata {
        FeedbackService.Metadata(
            appVersion: "?",
            buildNumber: "?",
            osVersion: "?",
            locale: "?",
            timestamp: "?",
            backendLabel: "?",
            modelAvailability: "?"
        )
    }
}
