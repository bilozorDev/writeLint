import Foundation

// `nonisolated` to match `Diff`'s static methods — without it, the
// default-MainActor build setting makes `DiffOpKind`/`DiffOp` (and their
// auto-synthesized `Equatable` conformances) MainActor-isolated, which
// trips warnings inside the nonisolated `diff` body.
nonisolated enum DiffOpKind: Equatable {
    case equal, insert, delete
}

nonisolated struct DiffOp: Equatable, Identifiable {
    let id = UUID()
    var kind: DiffOpKind
    var text: String
}

// `Diff` is a pure value-only namespace — every operation is a function of
// its inputs with no shared state. The project's
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` build setting would otherwise
// make these methods MainActor-isolated and trip warnings when callers
// invoke `Diff.diff(...)` inside `Task.detached { ... }` (the whole point
// of the detached call is to run *off* the main actor). `nonisolated`
// makes them callable from any isolation domain.
enum Diff {
    nonisolated static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inWhitespace = false
        for ch in s {
            let isWS = ch.isWhitespace
            if current.isEmpty {
                current.append(ch)
                inWhitespace = isWS
            } else if isWS == inWhitespace {
                current.append(ch)
            } else {
                tokens.append(current)
                current = String(ch)
                inWhitespace = isWS
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    nonisolated static func diff(_ original: String, _ corrected: String) -> [DiffOp] {
        // Common case: model returned the input unchanged (every passthrough,
        // every NO-OP chunk, every hallucination-fallback). Skip the O(n·m)
        // LCS table — at 100k chars it allocates ~3 GB of Ints to discover
        // what we already know.
        if original == corrected {
            return original.isEmpty ? [] : [DiffOp(kind: .equal, text: original)]
        }
        let a = tokenize(original)
        let b = tokenize(corrected)
        let n = a.count, m = b.count

        // LCS table — same algorithm as the JSX prototype.
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    if a[i] == b[j] {
                        dp[i][j] = dp[i + 1][j + 1] + 1
                    } else {
                        dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                    }
                }
            }
        }

        var ops: [DiffOp] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                ops.append(DiffOp(kind: .equal, text: a[i])); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                ops.append(DiffOp(kind: .delete, text: a[i])); i += 1
            } else {
                ops.append(DiffOp(kind: .insert, text: b[j])); j += 1
            }
        }
        while i < n { ops.append(DiffOp(kind: .delete, text: a[i])); i += 1 }
        while j < m { ops.append(DiffOp(kind: .insert, text: b[j])); j += 1 }

        // Collapse adjacent same-kind ops.
        var merged: [DiffOp] = []
        for op in ops {
            if var last = merged.last, last.kind == op.kind {
                last.text += op.text
                merged[merged.count - 1] = last
            } else {
                merged.append(op)
            }
        }
        return merged
    }

    nonisolated static func countChanges(_ ops: [DiffOp]) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for op in ops {
            let words = op.text.split(whereSeparator: \.isWhitespace).count
            switch op.kind {
            case .insert: added += words
            case .delete: removed += words
            case .equal: break
            }
        }
        return (added, removed)
    }
}
