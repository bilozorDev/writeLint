import Testing
@testable import Linter

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

        // Same for generationError vs malformedOutput stays at generationError
        // (it's higher priority than malformedOutput).
        let stays = LintIssue.upgrade(
            .generationError(detail: "first"),
            with: .malformedOutput
        )
        #expect(stays == .generationError(detail: "first"))
    }

    @Test func priorityOrdering() {
        // Simple sanity: hallucinated > generationError > malformedOutput.
        #expect(LintIssue.hallucinated(reason: "x").priority > LintIssue.generationError(detail: "x").priority)
        #expect(LintIssue.generationError(detail: "x").priority > LintIssue.malformedOutput.priority)
    }
}
