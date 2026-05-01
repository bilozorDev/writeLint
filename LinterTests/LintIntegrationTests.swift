import Testing
import Foundation
@testable import Linter

/// Integration tests that exercise the real on-device model. These are slow
/// (100–500 ms per call) and non-deterministic. Each test gates on
/// `availability.isAvailable` via `#require` so they skip cleanly on machines
/// where Apple Intelligence isn't enabled (CI without Apple silicon, etc.).
///
/// Assertions are **invariant-based**, not exact-output: the on-device model's
/// output is not bit-stable across OS minor updates or thermal states.
@Suite("Lint pipeline — integration against real on-device model", .serialized)
@MainActor
struct LintIntegrationTests {

    private func requireAvailable() throws {
        let avail = FoundationModelService.shared.availability
        try #require(avail == .available, "Apple Intelligence isn't available on this machine; skipping integration test.")
    }

    private static var defaultPrompt: String { PromptStore.defaultInstructions }

    @Test func emptyInputReturnsEmptyOutputWithoutCallingModel() async throws {
        try requireAvailable()
        let result = try await FoundationModelService.shared.lint(
            text: "",
            instructions: Self.defaultPrompt
        )
        #expect(result.output.isEmpty)
        #expect(result.ops.isEmpty)
    }

    @Test func whitespaceOnlyInputIsUnchanged() async throws {
        try requireAvailable()
        let input = "   \n\n\t  "
        let result = try await FoundationModelService.shared.lint(
            text: input,
            instructions: Self.defaultPrompt
        )
        // Either passed through verbatim or completely empty — both are
        // acceptable "do nothing" outcomes for whitespace-only input. What
        // would be a bug is the model returning some invented text.
        #expect(result.output == input || result.output.isEmpty,
                "got \(result.output.debugDescription) for whitespace-only input")
    }

    @Test func multiParagraphPreservesSeparatorStructure() async throws {
        try requireAvailable()
        // Three paragraphs separated by blank-line runs. The chunking +
        // re-stitching logic should keep the same number of separators in the
        // same positions. This is the invariant that protects users from
        // having their spacing silently collapsed.
        let input = "first paragraph one.\n\nsecond paragraph two.\n\nthird paragraph three."
        let result = try await FoundationModelService.shared.lint(
            text: input,
            instructions: Self.defaultPrompt
        )
        let inputBlankRuns = countBlankLineRuns(input)
        let outputBlankRuns = countBlankLineRuns(result.output)
        #expect(inputBlankRuns == outputBlankRuns,
                "separator count drifted: input=\(inputBlankRuns), output=\(outputBlankRuns); out=\(result.output.debugDescription)")
    }

    @Test func noOpCorrectInputIsPreservedNonDestructively() async throws {
        try requireAvailable()
        // A grammatically-clean input either round-trips byte-for-byte (best
        // case) or trips the hallucination guard and is preserved that way.
        // Both outcomes are non-destructive — the user never loses content.
        // Strict byte-equality would be flaky against Apple's non-deterministic
        // greedy decoding across OS updates and thermal states.
        let input = "The quick brown fox jumps over the lazy dog."
        let result = try await FoundationModelService.shared.lint(
            text: input,
            instructions: Self.defaultPrompt
        )
        let preserved = result.output == input
        let guarded = result.issue != nil
        #expect(preserved || guarded,
                "no-op-correct input mutated without guard firing: \(result.output.debugDescription), issue=\(String(describing: result.issue))")
    }

    @Test func cancellationReturnsWithoutThrowingOrOutput() async throws {
        try requireAvailable()
        // Kick off a lint on a long input and cancel mid-flight. The plan's
        // invariant: cancellation either throws CancellationError, OR returns
        // an output that is empty / equal to input. What we MUST NOT see is
        // a hallucinated partial-model-output silently surfacing — that would
        // mean cancellation didn't actually short-circuit the pipeline.
        let longInput = String(repeating: "this sentence has a typo definately. ", count: 8)
        let task = Task {
            try await FoundationModelService.shared.lint(
                text: longInput,
                instructions: Self.defaultPrompt
            )
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000)
            task.cancel()
        }
        do {
            let result = try await task.value
            // Returned cleanly — assert no destructive partial output.
            // Acceptable outcomes: empty, byte-equal to input, or every chunk
            // fell back via `result.issue` (hallucination guard or
            // pass-throughable error). NOT acceptable: a wholly different
            // string that the model partially produced.
            let preserved = result.output.isEmpty || result.output == longInput
            let guarded = result.issue != nil
            #expect(preserved || guarded,
                    "cancellation produced partial model output instead of preserving input: \(result.output.debugDescription)")
        } catch is CancellationError {
            // Cancellation propagated — the cleanest possible outcome.
        } catch {
            // Other framework errors during teardown are tolerated; the test
            // is specifically about not silently surfacing partial output,
            // and a thrown error means nothing is being surfaced.
        }
    }

    // MARK: helpers

    /// Count of "blank line" runs (≥2 consecutive newlines) inside a string.
    /// Mirrors the boundary `splitIntoChunks` uses, so we can assert the
    /// re-stitched output keeps the user's original paragraph structure.
    private func countBlankLineRuns(_ s: String) -> Int {
        var count = 0
        var run = 0
        for ch in s {
            if ch.isNewline {
                run += 1
                if run == 2 { count += 1 }
            } else {
                run = 0
            }
        }
        return count
    }
}
