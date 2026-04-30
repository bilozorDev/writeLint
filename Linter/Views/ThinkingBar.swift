import SwiftUI

struct ThinkingBar: View {
    let dark: Bool
    @State private var animate = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Palette.accent)
                        .frame(width: 6, height: 6)
                        .opacity(animate ? 1 : 0.25)
                        .scaleEffect(animate ? 1 : 0.8)
                        .animation(
                            .easeInOut(duration: 1.2).repeatForever().delay(Double(i) * 0.2),
                            value: animate
                        )
                }
            }
            Text("Thinking on-device…").font(.system(size: 12.5)).foregroundStyle(Palette.sub(dark))
            Spacer()
            HStack(spacing: 3) {
                Image(systemName: "apple.logo").font(.system(size: 10))
                Text("Foundation Models").font(.system(size: 10.5))
            }
            .opacity(0.7)
            .foregroundStyle(Palette.sub(dark))
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.divider(dark)).frame(height: 1)
        }
        .onAppear { animate = true }
    }
}

struct InlineErrorBar: View {
    let message: String
    let isInstalling: Bool
    let dark: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isInstalling ? "arrow.down.circle" : "exclamationmark.triangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(hex: "#FF9F0A"))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Palette.text(dark))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.AppleIntelligence-Settings.extension") {
                    NSWorkspace.shared.open(url)
                } else if let url = URL(string: "x-apple.systempreferences:") {
                    NSWorkspace.shared.open(url)
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(Palette.accent)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color(hex: "#FF9F0A").opacity(dark ? 0.10 : 0.08))
        .overlay(alignment: .top) { Rectangle().fill(Palette.divider(dark)).frame(height: 1) }
    }
}
