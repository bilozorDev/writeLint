import Foundation

enum DiffOpKind: Equatable {
    case equal, insert, delete
}

struct DiffOp: Equatable, Identifiable {
    let id = UUID()
    var kind: DiffOpKind
    var text: String
}

enum Diff {
    static func tokenize(_ s: String) -> [String] {
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

    static func diff(_ original: String, _ corrected: String) -> [DiffOp] {
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

    static func countChanges(_ ops: [DiffOp]) -> (added: Int, removed: Int) {
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
