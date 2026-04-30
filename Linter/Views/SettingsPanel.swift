import SwiftUI

struct SettingsPanel: View {
    @Bindable var store: TemplateStore
    @Binding var hotkey: Hotkey
    @Binding var diffStyle: DiffStyle
    @Binding var autoHide: Bool
    let dark: Bool

    @State private var editingID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Templates
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    sectionLabel("Templates")
                    Spacer()
                    if editingID == nil {
                        Button {
                            // UUID instead of timestamp — two clicks within the
                            // same second would otherwise collide and `update`
                            // / `delete` would target only the first match.
                            let new = Template(
                                id: "tpl_" + UUID().uuidString,
                                name: "New Template",
                                icon: "sparkles",
                                colorHex: "#BF5AF2",
                                instructions: ""
                            )
                            store.add(new)
                            editingID = new.id
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                                Text("New").font(.system(size: 11.5, weight: .semibold))
                            }
                            .foregroundStyle(Palette.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 4)

                VStack(spacing: 2) {
                    ForEach(Array(store.templates.enumerated()), id: \.element.id) { idx, tpl in
                        TemplateRow(
                            template: tpl,
                            index: idx,
                            isSelected: store.selectedID == tpl.id,
                            isEditing: editingID == tpl.id,
                            dark: dark,
                            onSelect: { store.selectedID = tpl.id },
                            onEdit: { editingID = tpl.id },
                            onSave: { updated in
                                store.update(updated)
                                editingID = nil
                            },
                            onCancel: { editingID = nil },
                            onDelete: {
                                store.delete(id: tpl.id)
                                editingID = nil
                            }
                        )
                    }
                }
            }

            divider

            // Shortcut
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Global Shortcut").padding(.leading, 4)
                HStack {
                    Image(systemName: "keyboard")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.sub(dark))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Summon Linter")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.text(dark))
                        Text("Opens with focus, ready to type")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.sub(dark))
                    }
                    Spacer()
                    ShortcutRecorderView(hotkey: $hotkey, dark: dark)
                }
                .padding(.horizontal, 4)
            }

            divider

            // Diff style
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Diff Style").padding(.leading, 4)
                HStack(spacing: 6) {
                    diffTile(.stacked, label: "Stacked", desc: "Original above, corrected below")
                    diffTile(.hover,   label: "Hover reveal", desc: "Clean text, hover to peek")
                }
                .padding(.horizontal, 4)
            }

            divider

            // Auto-hide after accept
            HStack {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.sub(dark))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-hide after accept")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.text(dark))
                    Text("Dismiss the panel after copying the corrected text")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.sub(dark))
                }
                Spacer()
                Toggle("", isOn: $autoHide)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.horizontal, 4)

            // Footer
            HStack(spacing: 6) {
                Image(systemName: "apple.logo").font(.system(size: 11))
                Text("Running on Apple Foundation Models · On-device · Private")
                    .font(.system(size: 11))
            }
            .foregroundStyle(Palette.sub(dark))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
        }
        .padding(14)
    }

    private var divider: some View {
        Rectangle().fill(Palette.divider(dark)).frame(height: 1)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .tracking(0.6)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(Palette.sub(dark))
    }

    private func diffTile(_ kind: DiffStyle, label: String, desc: String) -> some View {
        let active = diffStyle == kind
        return Button { diffStyle = kind } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active ? Palette.accent : Palette.text(dark))
                Text(desc)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.sub(dark))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(active ? Palette.accent.opacity(dark ? 0.18 : 0.10) : Palette.surface(dark))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(active ? Palette.accent : Palette.divider(dark), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
