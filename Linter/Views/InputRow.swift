import SwiftUI

struct InputRow: View {
    @Binding var text: String
    let dark: Bool
    let settingsOpen: Bool
    let isFocused: FocusState<Bool>.Binding
    let template: Template
    let justSwitched: Bool
    let onSubmit: () -> Void
    let onToggleSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Active-template badge — color + icon driven by the active
            // `Template`. Pulses (scale + matching halo) when the user
            // ⌘1..⌘9-switches templates so the change is visible without
            // looking down at the tab strip. Anchored to the top so it
            // stays put as the text field grows downward.
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: template.colorHex))
                Image(systemName: TemplateIcon(rawValue: template.iconName)?.systemName ?? "pencil")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            .scaleEffect(justSwitched ? 1.08 : 1.0)
            .shadow(
                color: Color(hex: template.colorHex).opacity(justSwitched ? 0.2 : 0),
                radius: 4
            )
            .animation(.spring(response: 0.4, dampingFraction: 0.55), value: justSwitched)
            .padding(.top, 16)
            .accessibilityLabel("Active template: \(template.name)")

            // Native multi-line TextField — auto-grows up to ~10 lines.
            // ⌘+⏎ submits and plain ⏎ inserts a newline; both are routed
            // through CommandKeyMonitor in LinterWindow (SwiftUI's vertical
            // TextField select-alls on plain ⏎ on macOS, so the monitor
            // forces a literal newline via insertNewlineIgnoringFieldEditor).
            // Keeping the input as a TextField rather than a custom NSTextView
            // avoids fighting the panel's auto-resize and Writing Tools'
            // affordance windows.
            TextField(
                "Type or paste text to \(template.name.lowercased())…",
                text: $text,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .foregroundStyle(Palette.text(dark))
            .lineLimit(1...10)
            .focused(isFocused)
            // Disable Apple Writing Tools on this field — its affordance
            // window kept stealing focus and select-all'ing the text on
            // Enter (showed up as `WTAffordanceWindow` in the console).
            .writingToolsBehavior(.disabled)
            .padding(.vertical, 22)
            .accessibilityIdentifier("Linter.InputField")

            Button(action: onToggleSettings) {
                Image(systemName: "gear")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Palette.sub(dark))
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(settingsOpen ? Palette.surfaceStrong(dark) : .clear)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
            .accessibilityLabel(settingsOpen ? "Close settings" : "Open settings")
            .accessibilityIdentifier("Linter.SettingsButton")
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
    }
}
