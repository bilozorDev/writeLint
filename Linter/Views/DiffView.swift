import SwiftUI

enum DiffStyle: String, CaseIterable, Codable {
    case stacked, hover
}

struct DiffView: View {
    let ops: [DiffOp]
    let style: DiffStyle
    let dark: Bool

    var body: some View {
        switch style {
        case .stacked: StackedDiffView(ops: ops, dark: dark)
        case .hover:   HoverDiffView(ops: ops, dark: dark)
        }
    }
}

private struct StackedDiffView: View {
    let ops: [DiffOp]
    let dark: Bool

    var body: some View {
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

private struct HoverDiffView: View {
    let ops: [DiffOp]
    let dark: Bool

    private struct Segment: Identifiable {
        let id = UUID()
        let kind: Kind
        let eqText: String
        let del: String
        let ins: String
        enum Kind { case equal, change }
    }

    private struct Line: Identifiable {
        let id = UUID()
        let segments: [Segment]
    }

    /// Walk ops left-to-right, merging consecutive del/ins into single change
    /// segments, AND splitting equal text on `\n` so the renderer can emit
    /// real line breaks (FlowLayout itself only word-wraps; without splitting
    /// here, multi-line input would pile onto one row).
    private var lines: [Line] {
        var out: [Line] = []
        var current: [Segment] = []

        func breakLine() {
            out.append(Line(segments: current))
            current = []
        }

        var i = 0
        while i < ops.count {
            let op = ops[i]
            if op.kind == .equal {
                let parts = op.text.components(separatedBy: "\n")
                for (idx, part) in parts.enumerated() {
                    if !part.isEmpty {
                        current.append(Segment(kind: .equal, eqText: part, del: "", ins: ""))
                    }
                    if idx < parts.count - 1 {
                        breakLine()
                    }
                }
                // If the equal text ended with a newline, the last "part" is
                // empty; commit the current line so the trailing newline
                // becomes a visible blank line in the rendered diff.
                if op.text.hasSuffix("\n") {
                    breakLine()
                }
                i += 1
            } else {
                var del = "", ins = ""
                while i < ops.count, ops[i].kind != .equal {
                    if ops[i].kind == .delete { del += ops[i].text } else { ins += ops[i].text }
                    i += 1
                }
                // Split inserted text on newlines so a multi-line change
                // wraps across multiple lines instead of becoming one tall
                // FlowLayout block. Deletion text shows in the hover tooltip
                // — attach it only to the first piece so it isn't repeated.
                let insParts = ins.components(separatedBy: "\n")
                for (idx, insPart) in insParts.enumerated() {
                    let segDel = (idx == 0) ? del : ""
                    current.append(Segment(kind: .change, eqText: "", del: segDel, ins: insPart))
                    if idx < insParts.count - 1 {
                        breakLine()
                    }
                }
            }
        }
        if !current.isEmpty || out.isEmpty {
            breakLine()
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines) { line in
                if line.segments.isEmpty {
                    // Preserve blank lines.
                    Text(" ").font(.system(size: 14))
                } else {
                    FlowLayout(spacing: 0, lineSpacing: 4) {
                        ForEach(line.segments) { seg in
                            if seg.kind == .equal {
                                Text(seg.eqText)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Palette.text(dark))
                            } else {
                                HoverChange(del: seg.del, ins: seg.ins, dark: dark)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 14)
    }
}

private struct HoverChange: View {
    let del: String
    let ins: String
    let dark: Bool
    @State private var hover = false

    var body: some View {
        let display = ins.trimmingCharacters(in: .whitespaces).isEmpty ? "·" : ins
        Text(display)
            .font(.system(size: 14))
            .foregroundStyle(Palette.text(dark))
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(hover ? Color(hex: "#30D158").opacity(0.28) : Color(hex: "#30D158").opacity(0.13))
            )
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(hex: "#30D158").opacity(0.7)).frame(height: 2)
            }
            .onHover { hover = $0 }
            .help(del.trimmingCharacters(in: .whitespaces).isEmpty ? "Inserted" : "was: \(del)")
    }
}

/// Tiny manual flow layout so word chunks wrap naturally.
struct FlowLayout: Layout {
    var spacing: CGFloat = 0
    var lineSpacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let arr = arrange(subviews: subviews, maxWidth: maxWidth)
        return arr.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arr = arrange(subviews: subviews, maxWidth: bounds.width)
        for (idx, frame) in arr.frames.enumerated() {
            subviews[idx].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            totalWidth = max(totalWidth, x)
            lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: totalWidth, height: y + lineHeight), frames)
    }
}
