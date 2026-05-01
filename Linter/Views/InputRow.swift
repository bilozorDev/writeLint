import SwiftUI

struct InputRow: View {
    @Binding var text: String
    let dark: Bool
    let settingsOpen: Bool
    let isFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onToggleSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Static grammar badge — anchored to the top so it stays put as
            // the text field grows downward. Now that the app is single-
            // template (just grammar polishing), the icon and color are
            // baked in instead of pulled from a Template model.
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: "#0A84FF"))
                Image(systemName: "pencil")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
            .padding(.top, 16)

            // Native multi-line TextField — auto-grows up to ~10 lines.
            // ⌘+⏎ submits and plain ⏎ inserts a newline; both are routed
            // through CommandKeyMonitor in LinterWindow (SwiftUI's vertical
            // TextField select-alls on plain ⏎ on macOS, so the monitor
            // forces a literal newline via insertNewlineIgnoringFieldEditor).
            // Keeping the input as a TextField rather than a custom NSTextView
            // avoids fighting the panel's auto-resize and Writing Tools'
            // affordance windows.
            TextField(
                "Type or paste text to polish…",
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
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
    }
}
