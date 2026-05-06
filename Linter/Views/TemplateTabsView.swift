import SwiftUI

/// Top-of-input template tab strip. Visible above `InputRow` when the user
/// has more than one template — a single template would just clone the
/// active-template badge below, so we hide it.
///
/// Layout: a horizontal `ScrollView` with one tab per template. Each tab
/// renders a colored dot (template's `colorHex`), the template name, and a
/// `⌘N` mono pill for the first 9 entries. The active tab is bold + gets
/// a 2pt colored bar at the bottom anchored under its dot+name region.
/// Names use `.lineLimit(1).truncationMode(.tail)` so long names never wrap
/// or grow the panel beyond `pageWidth`.
struct TemplateTabsView: View {
    @Bindable var store: PromptStore
    let dark: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(store.templates.enumerated()), id: \.element.id) { idx, template in
                    tab(idx: idx, template: template)
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 36)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.divider(dark)).frame(height: 1)
        }
    }

    @ViewBuilder
    private func tab(idx: Int, template: Template) -> some View {
        let active = template.id == store.selectedTemplateID
        Button {
            store.selectTemplate(id: template.id)
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    // 8pt colored dot. Active gets full opacity + 3pt halo
                    // shadow in the same color (matches design's
                    // `boxShadow: 0 0 0 3px ${color}22`).
                    Circle()
                        .fill(Color(hex: template.colorHex).opacity(active ? 1.0 : 0.55))
                        .frame(width: 8, height: 8)
                        .shadow(
                            color: active ? Color(hex: template.colorHex).opacity(0.22) : .clear,
                            radius: 0
                        )
                        .overlay {
                            if active {
                                Circle()
                                    .stroke(Color(hex: template.colorHex).opacity(0.22), lineWidth: 3)
                                    .frame(width: 14, height: 14)
                            }
                        }
                    Text(template.name)
                        .font(.system(size: 12.5, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? Palette.text(dark) : Palette.sub(dark))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if idx < 9 {
                        Text("⌘\(idx + 1)")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Palette.sub(dark).opacity(active ? 0.85 : 0.55))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Palette.surface(dark))
                            )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 11)
                .padding(.bottom, 12)
                .overlay(alignment: .bottom) {
                    if active {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color(hex: template.colorHex))
                            .frame(height: 2)
                            .padding(.horizontal, 12)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(template.name)\(idx < 9 ? ", shortcut Command \(idx + 1)" : "")")
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}
