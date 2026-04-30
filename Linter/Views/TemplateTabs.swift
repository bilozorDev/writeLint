import SwiftUI

struct TemplateTabs: View {
    let templates: [Template]
    let selectedID: String
    let dark: Bool
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(templates) { tpl in
                    let isActive = tpl.id == selectedID
                    Button { onSelect(tpl.id) } label: {
                        VStack(spacing: 0) {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(Color(hex: tpl.colorHex))
                                    .frame(width: 7, height: 7)
                                    .opacity(isActive ? 1 : 0.65)
                                Text(tpl.name)
                                    .font(.system(size: 12.5, weight: isActive ? .semibold : .medium))
                                    .foregroundStyle(isActive ? Palette.text(dark) : Palette.sub(dark))
                                    .fixedSize()
                            }
                            .padding(.horizontal, 11)
                            .padding(.top, 10)
                            .padding(.bottom, 12)
                            // Underline sits flush at bottom of the tab bar.
                            Rectangle()
                                .fill(isActive ? Color(hex: tpl.colorHex) : .clear)
                                .frame(height: 2)
                                .padding(.horizontal, 10)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }
}
