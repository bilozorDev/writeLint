import SwiftUI

struct DiffView: View {
    let ops: [DiffOp]
    let dark: Bool

    var body: some View {
        // Allow text selection across the whole diff so users can copy a
        // partial linted result by hand (the Copy button copies the full
        // corrected output; selection covers everything in between).
        VStack(alignment: .leading, spacing: 0) {
            // Original
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(Palette.removed).frame(width: 8, height: 8)
                    Text("ORIGINAL").tracking(0.6).font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Palette.sub(dark))
                }
                renderTokens(filter: .original).font(.system(size: 14)).lineSpacing(4)
                    .foregroundStyle(Palette.text(dark))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            // Connector
            HStack(spacing: 8) {
                Rectangle().fill(Palette.divider(dark)).frame(height: 1)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down").font(.system(size: 9, weight: .bold))
                    Text("LINTED").tracking(0.8).font(.system(size: 9.5, weight: .bold))
                }
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(Palette.surfaceStrong(dark)))
                .foregroundStyle(Palette.sub(dark))
                Rectangle().fill(Palette.divider(dark)).frame(height: 1)
            }
            .padding(.horizontal, 16)

            // Corrected
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(Palette.added).frame(width: 8, height: 8)
                    Text("CORRECTED").tracking(0.6).font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Palette.sub(dark))
                }
                renderTokens(filter: .corrected).font(.system(size: 14)).lineSpacing(4)
                    .foregroundStyle(Palette.text(dark))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .textSelection(.enabled)
        .accessibilityIdentifier("Linter.DiffView")
    }

    private enum Filter { case original, corrected }

    private func renderTokens(filter: Filter) -> Text {
        var attr = AttributedString()
        for op in ops {
            switch op.kind {
            case .equal:
                attr.append(AttributedString(op.text))
            case .delete where filter == .original:
                var seg = AttributedString(op.text)
                seg.foregroundColor = NSColor(Palette.removed)
                seg.strikethroughStyle = .single
                seg.strikethroughColor = NSColor(Palette.removed.opacity(0.7))
                attr.append(seg)
            case .insert where filter == .corrected:
                var seg = AttributedString(op.text)
                seg.foregroundColor = NSColor(Color(hex: "#1A8C3E"))
                // The green color is enough emphasis; setting NSFont here
                // would warn under strict concurrency (NSFont not Sendable).
                attr.append(seg)
            default:
                break
            }
        }
        return Text(attr)
    }
}
