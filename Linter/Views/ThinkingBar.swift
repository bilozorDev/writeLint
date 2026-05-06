import SwiftUI

/// Snapshot of which backend is producing the polish currently on the
/// thinking spinner. Captured at submit time in `LinterWindow.submit()`
/// so a mid-flight backend switch (via the footer Menu) doesn't relabel
/// the bar to a backend that isn't actually running this lint.
struct ThinkingDescriptor: Equatable {
    /// Phrase shown next to the animated dots.
    let leadingText: String
    /// SF Symbol name for the right-side tag.
    let glyph: String
    /// Right-side tag text — model name (e.g. "Foundation Models",
    /// "Claude Haiku 4.5", "GPT-4.1 mini").
    let tagText: String

    static let onDevice = ThinkingDescriptor(
        leadingText: "Thinking on-device…",
        glyph: "apple.logo",
        tagText: "Foundation Models"
    )

    static func claude(_ model: ClaudeModel) -> ThinkingDescriptor {
        ThinkingDescriptor(
            leadingText: "Thinking on Claude…",
            glyph: "cloud",
            tagText: model.footerLabel
        )
    }

    static func openai(_ model: OpenAIModel) -> ThinkingDescriptor {
        ThinkingDescriptor(
            leadingText: "Thinking on OpenAI…",
            glyph: "cloud",
            tagText: model.footerLabel
        )
    }
}

struct ThinkingBar: View {
    let dark: Bool
    let descriptor: ThinkingDescriptor
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
            Text(descriptor.leadingText)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.sub(dark))
            Spacer()
            HStack(spacing: 3) {
                Image(systemName: descriptor.glyph).font(.system(size: 10))
                Text(descriptor.tagText).font(.system(size: 10.5))
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
