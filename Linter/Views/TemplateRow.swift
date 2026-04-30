import SwiftUI

struct TemplateRow: View {
    let template: Template
    let index: Int
    let isSelected: Bool
    let isEditing: Bool
    let dark: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onSave: (Template) -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        if isEditing {
            EditView(template: template, dark: dark, onSave: onSave, onCancel: onCancel, onDelete: onDelete)
        } else {
            DisplayView(template: template, index: index, isSelected: isSelected, dark: dark, onSelect: onSelect, onEdit: onEdit)
        }
    }
}

private struct DisplayView: View {
    let template: Template
    let index: Int
    let isSelected: Bool
    let dark: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(hex: template.colorHex))
                    Image(systemName: template.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(template.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.text(dark))
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Palette.accent)
                        }
                    }
                    Text(template.instructions)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.sub(dark))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)

                if index < 9 {
                    Text("⌘\(index + 1)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.sub(dark))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Palette.surfaceStrong(dark)))
                }
                Button { onEdit() } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.sub(dark))
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isSelected
                        ? Palette.accent.opacity(dark ? 0.18 : 0.10)
                        : (hover ? Palette.surface(dark) : .clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct EditView: View {
    let template: Template
    let dark: Bool
    let onSave: (Template) -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    @State private var name: String
    @State private var instructions: String
    @State private var colorHex: String

    init(template: Template, dark: Bool, onSave: @escaping (Template) -> Void, onCancel: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.template = template
        self.dark = dark
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete
        _name = State(initialValue: template.name)
        _instructions = State(initialValue: template.instructions)
        _colorHex = State(initialValue: template.colorHex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Color(hex: colorHex))
                    Image(systemName: template.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 28, height: 28)
                TextField("Template name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text(dark))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Palette.surface(dark)))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.divider(dark), lineWidth: 0.5))
            }

            HStack(spacing: 6) {
                Text("Color").font(.system(size: 11)).foregroundStyle(Palette.sub(dark))
                ForEach(Palette.swatches, id: \.self) { hex in
                    Button { colorHex = hex } label: {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(hex: hex))
                            .frame(width: 18, height: 18)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(colorHex == hex ? Color(hex: hex) : .clear, lineWidth: 2)
                                    .padding(-3)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            TextEditor(text: $instructions)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.text(dark))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 84, maxHeight: 140)
                .background(RoundedRectangle(cornerRadius: 7).fill(Palette.surface(dark)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.divider(dark), lineWidth: 0.5))

            HStack {
                if template.id != "grammar" {
                    Button(role: .destructive) { onDelete() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash").font(.system(size: 11))
                            Text("Delete").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Palette.removed)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.sub(dark))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                Button {
                    var t = template
                    t.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    t.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
                    t.colorHex = colorHex
                    if t.name.isEmpty { t.name = "Untitled" }
                    onSave(t)
                } label: {
                    Text("Save")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.accent))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.surface(dark)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.divider(dark), lineWidth: 0.5))
    }
}
