import SwiftUI

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var rgba: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgba)
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((rgba & 0xFF000000) >> 24) / 255
            g = Double((rgba & 0x00FF0000) >> 16) / 255
            b = Double((rgba & 0x0000FF00) >> 8) / 255
            a = Double(rgba & 0x000000FF) / 255
        } else {
            r = Double((rgba & 0xFF0000) >> 16) / 255
            g = Double((rgba & 0x00FF00) >> 8) / 255
            b = Double(rgba & 0x0000FF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

enum Palette {
    static let accent = Color(hex: "#0A84FF")
    static let added = Color(hex: "#30D158")
    static let removed = Color(hex: "#FF453A")
    static let addedBg = Color(red: 48/255, green: 209/255, blue: 88/255).opacity(0.18)
    static let removedBg = Color(red: 255/255, green: 69/255, blue: 58/255).opacity(0.16)
    static let swatches: [String] = ["#0A84FF", "#FF9F0A", "#5E5CE6", "#30D158", "#FF453A", "#BF5AF2", "#64D2FF", "#FFD60A"]

    static func text(_ dark: Bool) -> Color { dark ? .white : Color(hex: "#1a1a1a") }
    static func sub(_ dark: Bool) -> Color { dark ? .white.opacity(0.5) : .black.opacity(0.45) }
    static func divider(_ dark: Bool) -> Color { dark ? .white.opacity(0.08) : .black.opacity(0.07) }
    static func surface(_ dark: Bool) -> Color { dark ? .white.opacity(0.04) : .black.opacity(0.03) }
    static func surfaceStrong(_ dark: Bool) -> Color { dark ? .white.opacity(0.08) : .black.opacity(0.05) }
    static func footerBg(_ dark: Bool) -> Color { dark ? .black.opacity(0.18) : .black.opacity(0.015) }
}

struct KbdLabel: View {
    let text: String
    let dark: Bool
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minWidth: 14)
            .background(Palette.surfaceStrong(dark), in: RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(dark ? .white.opacity(0.06) : .black.opacity(0.04), lineWidth: 0.5)
            )
            .foregroundStyle(Palette.sub(dark))
            .fixedSize()
    }
}
