import SwiftUI

struct SlashMenu: View {
    /// Pre-filtered list — filtering lives in LinterWindow so the keyboard
    /// handler and the renderer agree on the same set.
    let templates: [Template]
    let selectedIndex: Int
    let dark: Bool
    let onPick: (Template) -> Void

    var body: some View {
        if templates.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(templates.enumerated()), id: \.element.id) { idx, tpl in
                    let isSelected = idx == selectedIndex
                    Button { onPick(tpl) } label: {
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color(hex: tpl.colorHex))
                                Image(systemName: tpl.icon)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 18, height: 18)

                            Text(tpl.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Palette.text(dark))
                            Spacer()
                            Text("/\(tpl.id)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Palette.sub(dark))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(isSelected ? Palette.accent.opacity(dark ? 0.22 : 0.12) : .clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SlashRowStyle(dark: dark, isSelected: isSelected))
                }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Palette.divider(dark), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 12, y: 8)
        }
    }
}

private struct SlashRowStyle: ButtonStyle {
    let dark: Bool
    let isSelected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(configuration.isPressed && !isSelected ? Palette.surfaceStrong(dark) : .clear)
            )
            .contentShape(Rectangle())
    }
}
