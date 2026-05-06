import SwiftUI

/// Slack/Discord-style autocomplete popup for `/<template>` slash commands.
/// Pure presentation — all selection state lives in `LinterWindow` as
/// `slashMenu: SlashMenuState?`. Tap or arrow-key navigation drives
/// `onPick`, which the parent uses to switch the active template and
/// strip the `/foo` prefix from the input.
///
/// Rendered as a sibling row inside `mainPage`, NOT as a SwiftUI
/// `.overlay(...)` — see the comment in `LinterWindow.mainPage` for why
/// (the panel's `NSHostingController` uses preferred-content-size sizing
/// and overlays don't participate in that, so an overlay would render
/// past the panel's visible bounds when the input is empty).
struct SlashMenu: View {
    let state: LinterWindow.SlashMenuState
    let dark: Bool
    let onPick: (Template) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(state.matches.enumerated()), id: \.element.id) { idx, template in
                row(idx: idx, template: template)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.surface(dark)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Palette.divider(dark), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(dark ? 0.32 : 0.14), radius: 8, y: 4)
        // The popup must NOT participate in the keyboard focus chain.
        // Rows expose `.isButton` accessibility traits below for VoiceOver,
        // but Tab focus must stay on the input — our CommandKeyMonitor's
        // accept-selection branch is the only Tab path. Without this, Tab
        // would move SwiftUI focus into a row, flip `inputFocused` false,
        // and break the monitor's slashMenuActive gate.
        .focusable(false)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func row(idx: Int, template: Template) -> some View {
        let isHighlighted = idx == state.highlightedIndex
        HStack {
            Text(template.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.text(dark))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            if idx < 9 {
                Text("⌘\(idx + 1)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.sub(dark))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isHighlighted ? Palette.surfaceStrong(dark) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onPick(template) }
        .focusable(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(idx < 9
            ? "\(template.name), shortcut Command \(idx + 1)"
            : template.name)
        .accessibilityAddTraits(
            isHighlighted ? [.isButton, .isSelected] : [.isButton]
        )
    }
}
