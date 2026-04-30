import SwiftUI

struct HistoryView: View {
    let entries: [PromptEntry]
    let templates: [Template]
    let dark: Bool
    let onPick: (PromptEntry) -> Void
    let onClear: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("RECENT PROMPTS")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Palette.sub(dark))
                Spacer()
                if !entries.isEmpty {
                    Button("Clear", action: onClear)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.sub(dark))
                }
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.sub(dark))
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)

            if entries.isEmpty {
                HStack {
                    Spacer()
                    Text("No history yet — your last 10 prompts will appear here.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.sub(dark))
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(entries) { entry in
                            HistoryRow(
                                entry: entry,
                                template: templates.first { $0.id == entry.templateID },
                                dark: dark,
                                onPick: { onPick(entry) }
                            )
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 6)
                }
                .frame(maxHeight: 280)
            }
        }
        .background(Palette.footerBg(dark))
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.divider(dark)).frame(height: 1)
        }
    }
}

private struct HistoryRow: View {
    let entry: PromptEntry
    let template: Template?
    let dark: Bool
    let onPick: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onPick) {
            HStack(alignment: .top, spacing: 10) {
                if let template {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(hex: template.colorHex))
                        Image(systemName: template.icon)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 18, height: 18)
                    .padding(.top, 1)
                } else {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Palette.surfaceStrong(dark))
                        .frame(width: 18, height: 18)
                        .padding(.top, 1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.text(dark))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if let template {
                            Text(template.name)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Palette.sub(dark))
                        }
                        Text("·")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.sub(dark))
                        Text(entry.date, format: .relative(presentation: .numeric))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.sub(dark))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(hover ? Palette.surface(dark) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
