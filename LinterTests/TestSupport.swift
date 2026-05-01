import Foundation
@testable import Linter

/// Test-only helper: walk a `[DiffOp]` and reconstruct the `corrected` string
/// from the original. Used by `DiffTests` to assert the LCS-reconstruction
/// invariant `apply(diff(a, b), to: a) == b`. Lives in the test target only —
/// production `Diff.swift` is not changed.
func apply(_ ops: [DiffOp], to original: String) -> String {
    var result = ""
    var cursor = original.startIndex
    for op in ops {
        switch op.kind {
        case .equal:
            result.append(op.text)
            if let range = original.range(of: op.text, range: cursor..<original.endIndex) {
                cursor = range.upperBound
            }
        case .delete:
            if let range = original.range(of: op.text, range: cursor..<original.endIndex) {
                cursor = range.upperBound
            }
        case .insert:
            result.append(op.text)
        }
    }
    return result
}

/// Wraps a uniquely-named `UserDefaults` suite so tests can persist state
/// without touching `.standard`. Always pair `make()` with a `defer
/// scratch.cleanup()` at the test site so the on-disk plist is removed.
struct ScratchDefaults {
    let suiteName: String
    let defaults: UserDefaults

    static func make() -> ScratchDefaults {
        let name = "linter.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return ScratchDefaults(suiteName: name, defaults: d)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
