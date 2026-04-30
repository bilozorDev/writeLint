import SwiftUI

struct SlashMenu: View {
    let templates: [Template]
    let query: String
    let dark: Bool
    let onPick: (Template) -> Void

    private var filtered: [Template] {
        guard !query.isEmpty else { return templates }
        return templates.filter { $0.name.lowercased().contains(query.lowercased()) }
    }

    var body: some View {
        if filtered.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(filtered) { tpl in
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
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SlashRowStyle(dark: dark))
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(configuration.isPressed ? Palette.surfaceStrong(dark) : .clear)
            )
            .contentShape(Rectangle())
    }
}
