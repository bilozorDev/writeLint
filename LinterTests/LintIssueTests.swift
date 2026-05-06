import Testing
@testable import Write_Lint

@Suite("LintIssue.upgrade — priority-aware merge across multi-chunk fallbacks")
struct LintIssueTests {

    @Test func upgradeFromNilTakesIncomingRegardless() {
        #expect(LintIssue.upgrade(nil, with: .malformedOutput) == .malformedOutput)
        #expect(LintIssue.upgrade(nil, with: .generationError(detail: "x")) == .generationError(detail: "x"))
        #expect(LintIssue.upgrade(nil, with: .hallucinated(reason: "added-parens")) == .hallucinated(reason: "added-parens"))
    }

    @Test func hallucinationReplacesLowerPriorityIssues() {
        // The user-facing scenario: chunk 1 hits .malformedOutput (rarely
        // user-actionable), chunk 4 hits .hallucinated (often user-actionable
        // via prompt). The warning bar should show the hallucination so the
        // user has something to act on.
        let upgraded = LintIssue.upgrade(.malformedOutput, with: .hallucinated(reason: "added-parens"))
        #expect(upgraded == .hallucinated(reason: "added-parens"))

        let upgradedFromGenError = LintIssue.upgrade(
            .generationError(detail: "blocked"),
            with: .hallucinated(reason: "word-expansion 5→9")
        )
        #expect(upgradedFromGenError == .hallucinated(reason: "word-expansion 5→9"))
    }

    @Test func hallucinationDoesNotDowngradeForLaterLowerPriorityIssues() {
        // If chunk 1 hallucinated and chunk 4 hit malformed output, keep
        // the hallucination — it's more actionable.
        let kept = LintIssue.upgrade(.hallucinated(reason: "added-parens"), with: .malformedOutput)
        #expect(kept == .hallucinated(reason: "added-parens"))
    }

    @Test func equalPriorityKeepsExistingIssue() {
        // Two hallucinations of different reasons across the loop — keep the
        // first one. We don't want the warning bar's reason copy to flicker
        // between guards as later chunks fire.
        let kept = LintIssue.upgrade(
            .hallucinated(reason: "added-parens"),
            with: .hallucinated(reason: "word-expansion 5→9")
        )
        #expect(kept == .hallucinated(reason: "added-parens"))

        // Same shape for two generationErrors with different detail strings
        // (e.g., guardrail violation in chunk 1, context-window-exceeded in
        // chunk 4). Equal priority, keep the first one.
        let keptGenError = LintIssue.upgrade(
            .generationError(detail: "blocked"),
            with: .generationError(detail: "too long")
        )
        #expect(keptGenError == .generationError(detail: "blocked"))
    }

    @Test func priorityOrdering() {
        // Hard structural failures beat soft signals; drifted is the
        // softest issue — only surfaces when nothing worse fired in the
        // same lint, since the model's output IS being shown to the user.
        // Order: hallucinated > generationError > drifted > malformedOutput.
        #expect(LintIssue.hallucinated(reason: "x").priority > LintIssue.generationError(detail: "x").priority)
        #expect(LintIssue.generationError(detail: "x").priority > LintIssue.drifted(reason: "x").priority)
        #expect(LintIssue.drifted(reason: "x").priority > LintIssue.malformedOutput.priority)
    }

    @Test func driftedLosesToHardFailures() {
        // A lint that produced one drift chunk + one hallucination chunk
        // should surface the hallucination — the drift output is fine to
        // show, but a chunk hard-failing is the more important signal.
        let upgraded = LintIssue.upgrade(.drifted(reason: "word-expansion 5→9"),
                                          with: .hallucinated(reason: "added-parens"))
        #expect(upgraded == .hallucinated(reason: "added-parens"))

        let fromGenError = LintIssue.upgrade(.drifted(reason: "word-shrinkage 9→4"),
                                              with: .generationError(detail: "blocked"))
        #expect(fromGenError == .generationError(detail: "blocked"))
    }

    @Test func driftedBeatsMalformedOutput() {
        // Drift IS user-actionable (read it, judge it) — malformed output
        // is rarely fixable from the user side, so drift wins surfacing.
        let upgraded = LintIssue.upgrade(.malformedOutput, with: .drifted(reason: "word-expansion 5→9"))
        #expect(upgraded == .drifted(reason: "word-expansion 5→9"))
    }

    @Test func isFullFallbackDistinguishesDriftFromOthers() {
        // The UI uses `isFullFallback` to pick between the destructive
        // PartialIssueNotice (above the diff) and the soft DriftWarning
        // (below the diff). Drift is the only non-fallback issue.
        #expect(LintIssue.drifted(reason: "x").isFullFallback == false)
        #expect(LintIssue.hallucinated(reason: "x").isFullFallback == true)
        #expect(LintIssue.generationError(detail: "x").isFullFallback == true)
        #expect(LintIssue.malformedOutput.isFullFallback == true)
    }

    @Test func driftedDetailUsesSoftLanguage() {
        // The drift detail copy must NOT say "we kept your original" —
        // we DIDN'T keep the original, we used the model's output.
        // Different policy from the hallucinated copy, so guard-rail it.
        let expansion = LintIssue.drifted(reason: "word-expansion 5→9").detail
        #expect(expansion.contains("longer"))
        #expect(!expansion.contains("kept your original"))

        let shrinkage = LintIssue.drifted(reason: "word-shrinkage 12→4").detail
        #expect(shrinkage.contains("shorter"))
        #expect(!shrinkage.contains("kept your original"))
    }
}
