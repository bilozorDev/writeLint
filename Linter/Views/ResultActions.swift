import SwiftUI

struct ResultActions: View {
    let stats: (added: Int, removed: Int)
    let latencyMs: Int
    let copied: Bool
    let dark: Bool
    let onCopy: () -> Void
    let onReject: () -> Void
    let onAccept: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                statBadge(color: Palette.added, text: "+\(stats.added)")
                statBadge(color: Palette.removed, text: "−\(stats.removed)")
                Text("· \(latencyMs)ms")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.sub(dark))
                HStack(spacing: 3) {
                    Image(systemName: "apple.logo").font(.system(size: 10))
                    Text("on-device").font(.system(size: 11))
                }
                .foregroundStyle(Palette.sub(dark))
            }
            Spacer()
            Button(action: onCopy) {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                    Text(copied ? "Copied" : "Copy")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .foregroundStyle(copied ? Palette.added : Palette.sub(dark))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onReject) {
                Text("Reject")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.text(dark))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Palette.surface(dark))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.divider(dark), lineWidth: 0.5))
                    )
            }
            .buttonStyle(.plain)

            Button(action: onAccept) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    Text("Accept all").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Palette.accent))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Palette.footerBg(dark))
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.divider(dark)).frame(height: 1)
        }
    }

    private func statBadge(color: Color, text: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11)).foregroundStyle(Palette.sub(dark))
        }
    }
}
