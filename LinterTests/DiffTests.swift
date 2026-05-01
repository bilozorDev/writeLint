import Testing
@testable import Linter

@Suite("Diff — pure LCS over whitespace-aware tokens")
struct DiffTests {

    // MARK: tokenize

    @Test func tokenizeEmptyInputReturnsEmpty() {
        #expect(Diff.tokenize("") == [])
    }

    @Test func tokenizeSplitsOnWhitespaceTransitions() {
        // Each whitespace run and each non-whitespace run is its own token.
        #expect(Diff.tokenize("the cat") == ["the", " ", "cat"])
    }

    @Test func tokenizeKeepsContiguousWhitespaceAsOneToken() {
        #expect(Diff.tokenize("a  b") == ["a", "  ", "b"])
        #expect(Diff.tokenize("a\n\nb") == ["a", "\n\n", "b"])
        #expect(Diff.tokenize("a \tb") == ["a", " \t", "b"])
    }

    @Test func tokenizeHandlesUnicodeAndEmoji() {
        // Each emoji is a single Character; word/whitespace switching is what
        // splits tokens, so an emoji surrounded by spaces is its own word run.
        #expect(Diff.tokenize("hi 🐝 bye") == ["hi", " ", "🐝", " ", "bye"])
    }

    // MARK: diff — short-circuit and basic ops

    @Test func diffIdenticalStringsReturnsSingleEqualOp() {
        let ops = Diff.diff("hello world", "hello world")
        #expect(ops.count == 1)
        #expect(ops.first?.kind == .equal)
        #expect(ops.first?.text == "hello world")
    }

    @Test func diffEmptyToEmptyReturnsEmpty() {
        #expect(Diff.diff("", "") == [])
    }

    @Test func diffPureInsertionReportsInsertOnly() {
        let ops = Diff.diff("", "new")
        #expect(ops.count == 1)
        #expect(ops.first?.kind == .insert)
        #expect(ops.first?.text == "new")
    }

    @Test func diffPureDeletionReportsDeleteOnly() {
        let ops = Diff.diff("old", "")
        #expect(ops.count == 1)
        #expect(ops.first?.kind == .delete)
        #expect(ops.first?.text == "old")
    }

    @Test func diffSingleWordSubstitutionReportsDeleteThenInsert() {
        let ops = Diff.diff("teh", "the")
        // tokenize splits to ["teh"] and ["the"] (no whitespace) — both differ
        // so we expect a delete and an insert in some order.
        #expect(ops.contains(where: { $0.kind == .delete && $0.text == "teh" }))
        #expect(ops.contains(where: { $0.kind == .insert && $0.text == "the" }))
    }

    @Test func diffMergesAdjacentSameKindOps() {
        // "foo bar baz" → "foo qux baz" should report a single delete-then-insert
        // pair around "bar" (with surrounding spaces possibly bunched).
        let ops = Diff.diff("foo bar baz", "foo qux baz")
        // Verify no two adjacent ops share a kind (the merge invariant).
        for (a, b) in zip(ops, ops.dropFirst()) {
            #expect(a.kind != b.kind, "adjacent same-kind ops were not merged: \(a) then \(b)")
        }
    }

    // MARK: LCS reconstruction invariant (uses test-only `apply` helper)

    @Test(
        "Reconstruction invariant: apply(diff(a, b), to: a) == b",
        arguments: [
            ("", ""),
            ("hello", "hello"),
            ("teh quick brown fox", "the quick brown fox"),
            ("i has went to store", "I have gone to the store"),
            ("a b c", "a c"),
            ("a c", "a b c"),
            ("hello world", ""),
            ("", "hello world"),
            ("Hi 🐝 bye", "Hi 🐝🐝 bye"),
            ("one\n\ntwo", "One\n\nTwo"),
        ] as [(String, String)]
    )
    func diffReconstructionInvariant(_ pair: (String, String)) {
        let (a, b) = pair
        let ops = Diff.diff(a, b)
        #expect(apply(ops, to: a) == b, "diff failed to reconstruct \(b.debugDescription) from \(a.debugDescription); ops=\(ops)")
    }

    // MARK: countChanges

    @Test func countChangesIdenticalReturnsZeros() {
        let ops = Diff.diff("hello world", "hello world")
        let stats = Diff.countChanges(ops)
        #expect(stats.added == 0)
        #expect(stats.removed == 0)
    }

    @Test func countChangesCountsWordsNotWhitespace() {
        // "a b c" → "a b c d" inserts " d" (a whitespace run + a word). Only
        // the word ("d") contributes to `added`; whitespace tokens don't.
        let ops = Diff.diff("a b c", "a b c d")
        let stats = Diff.countChanges(ops)
        #expect(stats.added == 1)
        #expect(stats.removed == 0)
    }

    @Test func countChangesCountsBothDirections() {
        let ops = Diff.diff("foo bar baz", "foo qux baz")
        let stats = Diff.countChanges(ops)
        #expect(stats.added == 1)
        #expect(stats.removed == 1)
    }
}
