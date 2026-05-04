import Testing
@testable import Linter

@Suite("FoundationModelService pure helpers — chunking, hallucination guard, log quoting")
@MainActor
struct FoundationModelHelpersTests {

    // MARK: splitIntoChunks

    @Test func splitEmptyInputReturnsEmpty() {
        #expect(FoundationModelService.splitIntoChunks("") == [])
    }

    @Test func splitSingleLineReturnsOneTextChunk() {
        let chunks = FoundationModelService.splitIntoChunks("hello world")
        #expect(chunks == [.init(text: "hello world", isSeparator: false)])
    }

    @Test func splitSingleNewlineStaysInsideOneChunk() {
        // A single newline is NOT a separator — we want lines like greeting +
        // body to reach the model together so it can apply rules that span
        // lines (e.g. "blank line after greeting"). Only blank lines separate.
        let chunks = FoundationModelService.splitIntoChunks("hi there\nfriend")
        #expect(chunks == [.init(text: "hi there\nfriend", isSeparator: false)])
    }

    @Test func splitOnBlankLinePreservesSeparatorVerbatim() {
        let chunks = FoundationModelService.splitIntoChunks("para one\n\npara two")
        #expect(chunks == [
            .init(text: "para one", isSeparator: false),
            .init(text: "\n\n", isSeparator: true),
            .init(text: "para two", isSeparator: false),
        ])
    }

    @Test func splitMultipleBlankLineRunsKeptVerbatim() {
        // The user wrote three newlines on purpose — preserve them so accept
        // doesn't silently collapse spacing.
        let chunks = FoundationModelService.splitIntoChunks("a\n\n\nb")
        #expect(chunks == [
            .init(text: "a", isSeparator: false),
            .init(text: "\n\n\n", isSeparator: true),
            .init(text: "b", isSeparator: false),
        ])
    }

    @Test func splitTrailingNewlinesAreSeparatorWhenBlank() {
        let chunks = FoundationModelService.splitIntoChunks("body\n\n")
        #expect(chunks == [
            .init(text: "body", isSeparator: false),
            .init(text: "\n\n", isSeparator: true),
        ])
    }

    @Test func splitReassembledOutputEqualsInput() {
        // The whole point of preserving separators verbatim: stitching the
        // chunks back together must yield the original string byte-for-byte.
        // This is the invariant that keeps user spacing from disappearing.
        let inputs = [
            "one\n\ntwo",
            "alpha\nbeta\n\ngamma",
            "a\n\n\n\nb",
            "no separators here just one paragraph",
            "body\n\n",
        ]
        for input in inputs {
            let stitched = FoundationModelService.splitIntoChunks(input)
                .map(\.text)
                .joined()
            #expect(stitched == input, "stitched output for \(input.debugDescription) differs: got \(stitched.debugDescription)")
        }
    }

    // MARK: hallucinationReason — four guards

    @Test func hallucinationFlagsAddedParens() {
        // Classic acronym-expansion mode: "SOP" → "SOP (Standard Operating
        // Procedures)". Trip on any `(` that wasn't in the input.
        let r = FoundationModelService.hallucinationReason(
            input: "the SOP needs updating",
            output: "The SOP (Standard Operating Procedures) needs updating."
        )
        if case .addedParens = r {} else {
            Issue.record("expected .addedParens, got \(String(describing: r))")
        }
    }

    @Test func hallucinationDoesNotFlagParensThatWereInInput() {
        // If the input already had parens, the model passing them through
        // is fine. Don't trip.
        let r = FoundationModelService.hallucinationReason(
            input: "the (SOP) needs updating",
            output: "The (SOP) needs updating."
        )
        #expect(r == nil)
    }

    @Test func hallucinationFlagsLargeExpansionAtFiveOrMoreWords() {
        // Inputs ≥5 words: the upper-bound 1.3× ratio applies (the lower
        // 0.8× bound only kicks in at ≥8 words — see the shrinkage test
        // below). Expanding a 5-word input to 12 words is way over 1.3×.
        let r = FoundationModelService.hallucinationReason(
            input: "she sell that book yo",  // 5 words
            output: "She sells that book to you, and it is very interesting indeed."
        )
        if case .wordCountExpansion = r {} else {
            Issue.record("expected .wordCountExpansion, got \(String(describing: r))")
        }
    }

    @Test func hallucinationFlagsAbsoluteCapForShortInputs() {
        // Inputs <5 words: ratio is meaningless (1×1.2=1.2 rounds to 1), so
        // we cap at input + 3. A 1-word input expanding to 5+ words trips.
        let r = FoundationModelService.hallucinationReason(
            input: "hi",  // 1 word
            output: "Hi! Welcome to the team."  // 5 words
        )
        if case .wordCountExpansion = r {} else {
            Issue.record("expected .wordCountExpansion, got \(String(describing: r))")
        }
    }

    @Test func hallucinationFlagsShrinkageOnlyAtEightOrMoreWords() {
        // Lower bound (0.8×) only applies to inputs ≥8 words — leaves room
        // for short-input dedup like "the the" → "the".
        let r = FoundationModelService.hallucinationReason(
            input: "this is a long enough sentence to count past eight words",
            output: "this is short."
        )
        if case .wordCountShrinkage = r {} else {
            Issue.record("expected .wordCountShrinkage, got \(String(describing: r))")
        }
    }

    @Test func hallucinationDoesNotFlagShrinkageBelowEightWords() {
        // 7-word input shrinking to 4 words is allowed — the lower bound
        // doesn't kick in until 8 words.
        let r = FoundationModelService.hallucinationReason(
            input: "the the the the the the the",  // 7 words
            output: "the"  // 1 word
        )
        // No length-shrinkage trip expected; might still be nil or trip
        // another guard, but specifically NOT wordCountShrinkage.
        if case .wordCountShrinkage = r {
            Issue.record("shrinkage guard should not fire below 8 words; got \(String(describing: r))")
        }
    }

    @Test func hallucinationFlagsLeakedSchemaPhrase() {
        // The model occasionally leaks fragments of its own response-format
        // directive. Any leaked phrase that's in the output but not the input
        // trips. Input/output are kept the same word count so the length
        // guards don't trip first — we want the leaked-phrase guard to be
        // the one that fires.
        let r = FoundationModelService.hallucinationReason(
            input: "send the report tomorrow morning please thanks",  // 7 words
            output: "Send the report tomorrow morning, please. polished:"  // 8 words, ratio 1.14
        )
        if case .leakedPhrase = r {} else {
            Issue.record("expected .leakedPhrase, got \(String(describing: r))")
        }
    }

    @Test func hallucinationDoesNotFlagWhenUserActuallyTypedTheLeakPhrase() {
        // If the user themselves wrote "in JSON", a polished output containing
        // it is fine — we only flag phrases the model invented.
        let r = FoundationModelService.hallucinationReason(
            input: "send the response in JSON",
            output: "Send the response in JSON."
        )
        #expect(r == nil)
    }

    @Test func hallucinationCleanInputCleanOutputReturnsNil() {
        // The most common case: clean grammatical input, clean grammatical
        // output, no edits — guard returns nil.
        let r = FoundationModelService.hallucinationReason(
            input: "The quick brown fox jumps over the lazy dog.",
            output: "The quick brown fox jumps over the lazy dog."
        )
        #expect(r == nil)
    }

    @Test func looksHallucinatedMatchesReason() {
        // Boolean wrapper should agree with the typed return.
        let inputs: [(String, String)] = [
            ("the SOP", "The SOP (Standard Operating Procedures)."),
            ("hi", "Hi."),
            ("clean text passes through", "Clean text passes through."),
        ]
        for (input, output) in inputs {
            let r = FoundationModelService.hallucinationReason(input: input, output: output)
            let b = FoundationModelService.looksHallucinated(input: input, output: output)
            #expect((r != nil) == b)
        }
    }

    // MARK: quoteForLog

    @Test func quoteForLogWrapsAndEscapes() {
        #expect(FoundationModelService.quoteForLog("hi") == "\"hi\"")
        #expect(FoundationModelService.quoteForLog("a\nb") == "\"a\\nb\"")
        #expect(FoundationModelService.quoteForLog("a\tb") == "\"a\\tb\"")
        #expect(FoundationModelService.quoteForLog("say \"hi\"") == "\"say \\\"hi\\\"\"")
        #expect(FoundationModelService.quoteForLog("a\\b") == "\"a\\\\b\"")
    }

    @Test func quoteForLogEmptyStringReturnsEmptyQuotes() {
        #expect(FoundationModelService.quoteForLog("") == "\"\"")
    }
}
