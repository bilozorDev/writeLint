import Testing
import Foundation
@testable import Write_Lint

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

    // MARK: classify

    /// Helper: build an `NSError` whose `localizedDescription` matches `desc`.
    /// Used to exercise the deserialize-substring branch without constructing
    /// framework-private `LanguageModelSession.GenerationError` cases.
    private func makeError(_ desc: String) -> Error {
        NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: desc])
    }

    @Test func classifyDeserializeMessageMatchesAppleSubstring() {
        // The literal text reported from App Store v1.0 toasts — the
        // canonical case the rework exists to handle.
        let kind = FoundationModelService.classify(
            makeError("Failed to deserialize a Generable type from model output")
        )
        #expect(kind == .deserialize)
    }

    @Test func classifyDecodeSubstringMatches() {
        let kind = FoundationModelService.classify(makeError("Failed to decode response"))
        #expect(kind == .deserialize)
    }

    @Test func classifyGenerableSubstringMatches() {
        // Defensive — catches a future Apple phrasing that drops "deserialize"
        // but keeps "Generable" in the message.
        let kind = FoundationModelService.classify(makeError("Unable to parse Generable output"))
        #expect(kind == .deserialize)
    }

    @Test func classifyCancellationErrorReturnsCancelled() {
        #expect(FoundationModelService.classify(CancellationError()) == .cancelled)
    }

    @Test func classifyUserCancelledNSErrorReturnsCancelled() {
        let e = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        #expect(FoundationModelService.classify(e) == .cancelled)
    }

    @Test func classifyUnrelatedErrorReturnsUnclassified() {
        // Unclassified errors flow into the unstructured fallback, not a
        // raw-error toast. Substring match must NOT trip on noise.
        let kind = FoundationModelService.classify(makeError("Network connection lost"))
        #expect(kind == .unclassified)
    }

    @Test func classifyIsCaseInsensitive() {
        let kind = FoundationModelService.classify(makeError("FAILED TO DESERIALIZE"))
        #expect(kind == .deserialize)
    }

    // MARK: stripPreamble

    @Test func stripPreambleRemovesOutputColon() {
        // "Output:" is the most common preamble label the on-device model
        // emits when guided generation is disabled. Strip it + trailing
        // whitespace.
        let stripped = FoundationModelService.stripPreamble(
            "Output: The quick brown fox jumps over the lazy dog every single day."
        )
        #expect(stripped == "The quick brown fox jumps over the lazy dog every single day.")
    }

    @Test func stripPreambleRemovesPolishedColon() {
        let stripped = FoundationModelService.stripPreamble(
            "Polished: The quick brown fox jumps over the lazy dog every single day."
        )
        #expect(stripped == "The quick brown fox jumps over the lazy dog every single day.")
    }

    @Test func stripPreamblePrefersLongerLabel() {
        // "polished text:" must match before "polished:" — otherwise the
        // shorter prefix would eat the word "text" as content.
        let stripped = FoundationModelService.stripPreamble(
            "Polished text: The quick brown fox jumps over the lazy dog every day."
        )
        #expect(stripped == "The quick brown fox jumps over the lazy dog every day.")
    }

    @Test func stripPreambleRemovesSureWithComma() {
        // Conversational opener — only short punctuated forms match so a
        // plain "Sure thing it works" doesn't lose its first word.
        let stripped = FoundationModelService.stripPreamble(
            "Sure, the quick brown fox jumps over the lazy dog every single day here."
        )
        #expect(stripped == "the quick brown fox jumps over the lazy dog every single day here.")
    }

    @Test func stripPreambleNoOpOnPlainSentence() {
        let input = "The dog runs fast across the field every single morning."
        #expect(FoundationModelService.stripPreamble(input) == input)
    }

    @Test func stripPreambleNoOpWhenNoColonAfterTriggerWord() {
        // "Output of the function is 42." starts with "Output" but no colon
        // follows — the colon requirement protects legitimate prose that
        // happens to start with a label word.
        let input = "Output of the function is 42 across the whole run."
        #expect(FoundationModelService.stripPreamble(input) == input)
    }

    @Test func stripPreambleLengthRatioGuardSavesShortContent() {
        // "Output: 42" — stripping "Output: " leaves "42" (2/10 chars =
        // 20%, well under the 75% retain floor). The guard fires; we
        // return the original so downstream guards can decide.
        let input = "Output: 42"
        #expect(FoundationModelService.stripPreamble(input) == input)
    }

    @Test func stripPreambleIsCaseInsensitive() {
        let stripped = FoundationModelService.stripPreamble(
            "SURE, the quick brown fox jumps over the lazy dog every single day here."
        )
        #expect(stripped == "the quick brown fox jumps over the lazy dog every single day here.")
    }

    @Test func stripPreambleNoOpOnPlainSureWithoutPunctuation() {
        // "Sure thing it works" has no comma/period after "Sure" — must
        // pass through, otherwise we'd eat "Sure" mid-sentence.
        let input = "Sure thing it works as expected on every single day."
        #expect(FoundationModelService.stripPreamble(input) == input)
    }
}
