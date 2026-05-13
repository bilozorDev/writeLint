import Foundation
import FoundationModels
import os

/// Lint pipeline tracing. Writes through Apple's unified logging — visible in
/// Xcode's console while running, and in Console.app filtering for subsystem
/// "Hexaget.WriteLint" / category "lint" while the app runs standalone.
/// User text fields (`in=`, `raw=`, `out=`, `final=`, `input=`) are marked
/// `.private` so they redact to `<private>` in the unified log — pasted
/// content can plausibly include credentials, draft messages, or internal
/// notes, and the app's footer promises "Private · on-device". Structural
/// metadata (chunk counts, latency, error descriptions, hallucination
/// reasons) stays `.public` so the trace remains readable in Xcode and via
/// `log show` for the developer.
private let lintLog = Logger(subsystem: "Hexaget.WriteLint", category: "lint")

enum LintError: Error, LocalizedError {
    case modelUnavailable(String)
    case cancelled
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let r): return r
        case .cancelled: return "Cancelled."
        case .underlying(let e): return e.localizedDescription
        }
    }
}

enum ModelAvailability: Equatable {
    case available
    case unavailable(reason: String, isInstalling: Bool)
}

struct LintResult {
    /// The exact text the user submitted. Stored on the result so the UI
    /// has it on hand without threading a separate variable through accept
    /// handlers — used by `handleAccept` to record the original alongside
    /// the polished output in `PromptHistory`.
    var input: String
    var output: String
    var ops: [DiffOp]
    var stats: (added: Int, removed: Int)
    var latencyMs: Int
    /// Set when at least one chunk fell back to its original text instead of
    /// returning a polished version (hallucination guard fired, model errored
    /// in a pass-throughable way, output was malformed). The UI reads this to
    /// distinguish a *truly clean* run (no issue, output==input) from a
    /// *failed* run that happens to look identical because every chunk fell
    /// back. Holds the first issue encountered — sufficient for the UI's
    /// "couldn't polish reliably" bar; the per-chunk detail is in the log.
    var issue: LintIssue?
}

/// User-visible categorization of a chunk-level outcome. Two flavors:
/// "full fallback" cases (`.hallucinated`, `.generationError`,
/// `.malformedOutput`) where the output equals the input because the
/// polish failed, and `.drifted` where the polish *succeeded* but the
/// output diverged from the input enough to warrant a soft "double-
/// check" warning. The UI distinguishes them — full fallbacks render
/// `PartialIssueNotice` above the diff (or `IssueBar` on no-diff
/// results); drift renders a softer notice below the diff.
enum LintIssue: Equatable {
    /// Hallucination guard tripped on a structural failure (added parens
    /// or leaked instruction phrase). The chunk fell back to the input.
    /// `reason` is the `HallucinationReason.description` so the UI can
    /// tailor the detail copy. On-device only.
    case hallucinated(reason: String)
    /// On-device word-count drift (>1.3× expansion or <0.8× shrinkage).
    /// We KEEP the model's output but surface a soft warning so the user
    /// can review before accepting. On-device only — cloud backends
    /// don't run this check at all (see ClaudeBackend / OpenAIBackend).
    case drifted(reason: String)
    /// `LanguageModelSession.GenerationError` we chose to swallow (guardrail,
    /// unsupported language, exceeded context window). `detail` is a friendly
    /// message for the user.
    case generationError(detail: String)
    /// Structured-output parsing failed (typically truncation or malformed
    /// JSON from the on-device model).
    case malformedOutput

    /// True for issues where the chunk's output was replaced with the
    /// input verbatim. Drives the UI choice between `PartialIssueNotice`
    /// (full fallback — "some sections couldn't be polished") and the
    /// softer drift notice (output kept, just flagged for review).
    var isFullFallback: Bool {
        switch self {
        case .hallucinated, .generationError, .malformedOutput: return true
        case .drifted: return false
        }
    }

    /// Headline shown in the warning bar.
    var headline: String {
        switch self {
        case .hallucinated:       return "Couldn't polish reliably"
        case .drifted:            return "Output may need a quick review"
        case .generationError:    return "Couldn't polish this text"
        case .malformedOutput:    return "Couldn't polish this text"
        }
    }

    /// Body copy below the headline. Short, actionable when possible.
    var detail: String {
        switch self {
        case .hallucinated(let reason):
            if reason == "added-parens" {
                return "The model expanded an acronym, so we kept your original."
            }
            if reason.hasPrefix("leaked-phrase") {
                return "The model's output included instruction text, so we kept your original."
            }
            return "We kept your original text."
        case .drifted(let reason):
            if reason.hasPrefix("word-expansion") {
                return "The polished version is significantly longer than your input. Skim it before accepting."
            }
            if reason.hasPrefix("word-shrinkage") {
                return "The polished version is significantly shorter than your input. Skim it before accepting."
            }
            return "The polished version diverged from your input. Skim it before accepting."
        case .generationError(let detail):
            return detail
        case .malformedOutput:
            return "We couldn't get a reliable polish, so we kept your original."
        }
    }

    /// Priority for surfacing one issue when multiple chunks produce
    /// different issues. Hard structural failures rank highest because
    /// they're the most user-actionable (almost always a prompt-tunable
    /// problem). Drift is the softest signal — only surfaces when
    /// nothing worse fired in the same lint, since the output IS being
    /// used and the user can judge for themselves.
    /// Used by `LintIssue.upgrade(_:with:)` to keep the highest-priority
    /// issue when a later chunk fires a more-actionable guard than an
    /// earlier one.
    var priority: Int {
        switch self {
        case .hallucinated:     return 3
        case .generationError:  return 2
        case .drifted:          return 1
        case .malformedOutput:  return 0
        }
    }

    /// Combines two issues using priority — picks the higher-priority one.
    /// `existing == nil` always loses to `incoming`. When priorities tie,
    /// keep `existing` (the earlier-fired issue) so we don't churn between
    /// equally-actionable issues across the loop.
    static func upgrade(_ existing: LintIssue?, with incoming: LintIssue) -> LintIssue {
        guard let existing else { return incoming }
        return incoming.priority > existing.priority ? incoming : existing
    }
}

/// Guided-generation schema. Forces the model to emit a single string field
/// — preamble like "Sure, here is..." becomes structurally impossible
/// because there's no field for it. Field name and Guide are deliberately
/// transformation-neutral (not "polished") because they steer decoding even
/// with `includeSchemaInPrompt: false` — anything semantic here would bias
/// every Advanced-Mode custom prompt back toward polishing. The structural
/// anti-preamble guidance ("only", "no commentary") is preserved.
@Generable
struct LintOutput {
    @Guide(description: "The output text only. No preamble, no commentary, no quote marks.")
    let output: String
}

/// Selects which model path `FoundationModelService.lint` runs. Constructed
/// at the UI layer (`LinterWindow.submit`) by reading `PromptStore` —
/// keeping the choice in one place at the call site rather than reaching
/// into the store from inside the service.
enum BackendChoice {
    case onDevice
    case claude(apiKey: String, model: ClaudeModel)
    case openai(apiKey: String, model: OpenAIModel)
}

@MainActor
final class FoundationModelService {
    static let shared = FoundationModelService()

    private let model = SystemLanguageModel.default
    private let claude = ClaudeBackend()
    private let openai = OpenAIBackend()

    var availability: ModelAvailability {
        switch model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            let (msg, installing) = Self.describe(reason)
            return .unavailable(reason: msg, isInstalling: installing)
        }
    }

    /// Pre-load the on-device model weights into memory so the first lint
    /// after the user summons the panel doesn't pay the 100–300 ms cold-
    /// start tax. Safe to call multiple times. No-ops if the model isn't
    /// available (Apple Intelligence off, downloading, etc.).
    func prewarm() {
        guard case .available = availability else { return }
        let session = LanguageModelSession(
            transcript: Self.buildTranscript(instructions: "")
        )
        session.prewarm()
    }

    /// `true` for `GenerationError` cases where the right UX is to silently
    /// return the user's original text instead of surfacing an error toast.
    /// All three cases here are model-side conditions the user can't act on.
    ///
    /// Not unit-tested: constructing `LanguageModelSession.GenerationError`
    /// instances in tests is brittle (the cases have framework-private inits),
    /// and the body is an exhaustive switch — a regression would show up as
    /// a compile error or be caught by the integration tests in Layer 3.
    private static func isPassThroughableError(_ error: LanguageModelSession.GenerationError) -> Bool {
        switch error {
        case .guardrailViolation, .unsupportedLanguageOrLocale, .exceededContextWindowSize:
            return true
        default:
            return false
        }
    }

    /// Friendly rendering of a pass-throughable `GenerationError` for the
    /// in-panel warning bar. Kept narrow — these are the only three cases
    /// `isPassThroughableError` accepts; everything else propagates as a
    /// toast and never reaches here. If a future contributor adds a fourth
    /// pass-throughable case to `isPassThroughableError` without adding a
    /// matching arm here, the assertion makes it loud in dev (Release falls
    /// back to a generic message rather than crashing the user).
    private static func friendlyGenerationErrorMessage(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .guardrailViolation:
            return "Apple Intelligence's safety filter blocked this input. Try different wording."
        case .unsupportedLanguageOrLocale:
            return "The on-device model doesn't support this language yet."
        case .exceededContextWindowSize:
            return "This text is too long for the on-device model. Try a shorter passage."
        default:
            assertionFailure("isPassThroughableError accepted a case friendlyGenerationErrorMessage doesn't render: \(error)")
            return "The on-device model couldn't process this input."
        }
    }

    /// Categorization of an error raised by `session.respond(...)` inside the
    /// per-chunk retry ladder. The deserialize family is matched by substring
    /// on `localizedDescription` rather than by typed case: we cannot
    /// pattern-match a hypothetical `GenerationError.decodingFailure`
    /// (deployment floor is macOS 26.0 and the case shape is undocumented
    /// here), and substring matching covers both the typed-throw path and
    /// the generic-`Error` path. The token set is broader than any single
    /// Apple phrasing so future drift falls through to `.unclassified`,
    /// which the retry ladder then funnels into the unstructured fallback.
    internal enum ChunkFailureKind: Equatable {
        case passThroughGeneration(LintIssue)
        case deserialize
        case cancelled
        case unclassified
    }

    internal static func classify(_ error: Error) -> ChunkFailureKind {
        if error is CancellationError { return .cancelled }
        let nsErr = error as NSError
        if nsErr.domain == NSCocoaErrorDomain, nsErr.code == NSUserCancelledError {
            return .cancelled
        }
        if let gen = error as? LanguageModelSession.GenerationError,
           isPassThroughableError(gen) {
            return .passThroughGeneration(.generationError(detail: friendlyGenerationErrorMessage(gen)))
        }
        let desc = error.localizedDescription.lowercased()
        for needle in ["deserialize", "decode", "generable"] {
            if desc.contains(needle) { return .deserialize }
        }
        return .unclassified
    }

    /// Removes at most one leading conversational preamble from raw,
    /// unstructured model output ("Sure, here is …", "Output: …",
    /// "Polished: …"). Only the colon-suffixed labels (`output:`,
    /// `polished:`, `polished text:`) and short conversational openers
    /// (`sure,`/`sure!`/`sure.`) are stripped — open-prefix matching
    /// against bare words like "Output" over-strips legitimate prose
    /// ("Output of the function is …"), and the model rarely emits a
    /// label without a colon when it leaks one at all. A length-ratio
    /// guard is the final safety net: a strip that drops more than 25%
    /// of the content is treated as suspicious and skipped — the
    /// downstream hallucination guards (parens, word-count, leaked-
    /// phrase) cover any residue.
    ///
    /// Only runs on the unstructured (Attempt 3) path. The guided path
    /// uses `@Generable` so preamble is structurally impossible.
    internal static func stripPreamble(_ s: String) -> String {
        let lower = s.lowercased()

        // Colon-bearing labels — longest first so "polished text:" wins
        // before "polished:" matches.
        let colonLabels = ["polished text:", "polished:", "output:"]
        for label in colonLabels {
            if lower.hasPrefix(label) {
                return strippedOrOriginal(s, prefixLen: label.count)
            }
        }
        // Conversational openers — must carry punctuation so a plain
        // "Sure thing it works" doesn't get its first word eaten.
        let sureOpeners = ["sure,", "sure!", "sure.", "sure:"]
        for opener in sureOpeners {
            if lower.hasPrefix(opener) {
                return strippedOrOriginal(s, prefixLen: opener.count)
            }
        }
        return s
    }

    /// Helper for `stripPreamble`: walks past a fixed-length prefix and any
    /// trailing whitespace/newlines, then applies the length-ratio guard.
    /// Returns the original string if the strip would drop more than 25%
    /// of the content (heuristic anti-overstrip — protects short legitimate
    /// outputs like "Output: 42").
    private static func strippedOrOriginal(_ s: String, prefixLen: Int) -> String {
        guard let prefixEnd = s.index(s.startIndex, offsetBy: prefixLen, limitedBy: s.endIndex) else {
            return s
        }
        var idx = prefixEnd
        while idx < s.endIndex, s[idx].isWhitespace || s[idx].isNewline {
            idx = s.index(after: idx)
        }
        let candidate = String(s[idx...])
        if Double(candidate.count) < Double(s.count) * 0.75 {
            return s
        }
        return candidate
    }

    /// Polish `text` using `instructions` as the entire system prompt sent
    /// to the model. The instructions string is the *only* input that
    /// shapes the model's behavior — no separately-injected few-shot turns,
    /// no schema-side hints layered on top. Examples (if any) live inside
    /// the instructions text so they're visible to the user in Advanced
    /// Mode.
    ///
    /// `backend` controls which model path runs. Default `.onDevice`
    /// preserves the existing call site signature; the UI passes `.claude`
    /// when the user has opted in via Settings (Advanced Mode + key
    /// present).
    func lint(
        text: String,
        instructions: String,
        backend: BackendChoice = .onDevice,
        templateName: String = ""
    ) async throws -> LintResult {
        // Single dispatch-level log line so "wrong prompt" complaints are
        // debuggable from the log alone — without changing any backend's
        // request body or chunk-level logging. Empty name (the default for
        // call sites that don't supply one — e.g. integration tests)
        // prints as `template=""` rather than mangled output. Backend is
        // logged as a short tag (`on-device` / `claude` / `openai`) so the
        // line stays readable and never leaks the API key payload from the
        // associated value.
        let backendTag: String = {
            switch backend {
            case .onDevice: return "on-device"
            case .claude(_, let model): return "claude:\(model.rawValue)"
            case .openai(_, let model): return "openai:\(model.rawValue)"
            }
        }()
        lintLog.notice("lint dispatch: backend=\(backendTag, privacy: .public) template=\"\(templateName, privacy: .public)\"")
        switch backend {
        case .onDevice:
            return try await lintOnDevice(text: text, instructions: instructions)
        case .claude(let apiKey, let model):
            return try await claude.lint(
                text: text,
                instructions: instructions,
                apiKey: apiKey,
                model: model
            )
        case .openai(let apiKey, let model):
            return try await openai.lint(
                text: text,
                instructions: instructions,
                apiKey: apiKey,
                model: model
            )
        }
    }

    /// On-device path. Extracted from `lint(text:instructions:)` so the
    /// router stays a thin two-case switch and the cloud path lives next to
    /// it as a sibling method.
    private func lintOnDevice(text: String, instructions: String) async throws -> LintResult {
        guard case .available = availability else {
            if case .unavailable(let reason, _) = availability {
                lintLog.error("model unavailable: \(reason, privacy: .public)")
                throw LintError.modelUnavailable(reason)
            }
            throw LintError.modelUnavailable("Model unavailable.")
        }

        let clock = ContinuousClock()
        let start = clock.now

        // Split into paragraph-size chunks (preserving the exact separators)
        // so a long multi-paragraph input never blows past the model's response
        // token cap. Each chunk gets its own session for predictable behavior.
        let chunks = Self.splitIntoChunks(text)

        lintLog.notice("─── lint start: chunks=\(chunks.count) input=\(Self.quoteForLog(text), privacy: .private)")

        do {
            var output = ""
            // Highest-priority fallback we've seen so far across the loop.
            // Surfaced in `LintResult` so the UI can distinguish a clean run
            // from "every chunk fell back". The warning bar shows one headline
            // (per-chunk detail goes to the log), so we keep the most
            // actionable one — see `LintIssue.upgrade(_:with:)` for priority.
            // Reassigned on every fallback (with the same value, when upgrade
            // keeps the existing issue) — fine because this is a local. If
            // this ever migrates to a property with a `didSet`, switch to
            // `if let upgraded = ..., upgraded != currentIssue` to avoid
            // spurious notifications.
            var currentIssue: LintIssue?
            // Per-chunk retry budget. The first failing chunk gets the
            // full ladder (Attempt 1 → 2 → 3); once any chunk exhausts
            // retries, subsequent chunks short-circuit (Attempt 1 → 3,
            // skipping the wider-cap retry). Latency floor for
            // multi-paragraph all-fail inputs.
            var allowRetry = true
            for (i, chunk) in chunks.enumerated() {
                if Task.isCancelled { throw LintError.cancelled }
                let (out, issue, exhausted) = try await processChunk(
                    chunk,
                    index: i,
                    instructions: instructions,
                    allowRetry: allowRetry
                )
                output += out
                if let issue {
                    currentIssue = LintIssue.upgrade(currentIssue, with: issue)
                }
                if exhausted { allowRetry = false }
            }

            let elapsed = clock.now - start
            let latencyMs = Int(Double(elapsed.components.seconds) * 1000.0
                + Double(elapsed.components.attoseconds) / 1e15)
            // `Diff.diff` is the longest pure-CPU step in the pipeline (LCS is
            // O(n·m) over whitespace-aware tokens). Pure functional — safe to
            // run off the main actor so we don't block UI updates while the
            // diff computes.
            let inputCopy = text
            let outputCopy = output
            let ops = await Task.detached(priority: .userInitiated) {
                Diff.diff(inputCopy, outputCopy)
            }.value
            let stats = Diff.countChanges(ops)
            let issueTag: String = currentIssue.map { " issue=\(String(describing: $0))" } ?? ""
            lintLog.notice("─── lint done: latency=\(latencyMs)ms +\(stats.added)/-\(stats.removed) words\(issueTag, privacy: .public), final=\(Self.quoteForLog(output), privacy: .private)")
            return LintResult(input: text, output: output, ops: ops, stats: stats, latencyMs: latencyMs, issue: currentIssue)
        } catch is CancellationError {
            lintLog.notice("lint cancelled")
            throw LintError.cancelled
        } catch let e as LintError {
            lintLog.error("lint failed: \(e.localizedDescription, privacy: .public)")
            throw e
        } catch {
            lintLog.error("lint failed: \(error.localizedDescription, privacy: .public)")
            throw LintError.underlying(error)
        }
    }

    /// Per-chunk pipeline with a 3-attempt retry ladder:
    ///   1. guided (`@Generable LintOutput`), cap = `min(2048, max(128, chars+256))`
    ///   2. guided, wider cap = `min(4096, max(512, chars*4))` — only when
    ///      `allowRetry` is true and the Attempt-1 cap isn't already saturated
    ///   3. unstructured (`session.respond(to:options:)` without `generating:`)
    ///      with preamble stripping before downstream shaping
    ///
    /// `allowRetry` is `true` for chunks before any chunk in this lint has
    /// hit the wider-cap retry; once one chunk takes the full ladder, the
    /// caller flips it to `false` and subsequent chunks skip Attempt 2
    /// (latency floor for multi-paragraph all-fail inputs).
    ///
    /// `exhaustedRetries` in the return tuple is `true` whenever the chunk
    /// reached Attempt 2 or 3 — the caller uses it to flip `allowRetry`.
    ///
    /// `Task.isCancelled` is checked before each attempt so a user cancel
    /// mid-ladder propagates within one `session.respond` latency rather
    /// than after the full 3-attempt budget.
    ///
    /// Internal so tests can reach it via `@testable import` if needed.
    internal func processChunk(
        _ chunk: Chunk,
        index i: Int,
        instructions: String,
        allowRetry: Bool
    ) async throws -> (output: String, issue: LintIssue?, exhaustedRetries: Bool) {
        if Task.isCancelled { throw CancellationError() }
        if chunk.isSeparator {
            lintLog.debug("chunk \(i): separator (\(chunk.text.count) chars) — passthrough")
            return (chunk.text, nil, false)
        }
        let trimmed = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            lintLog.debug("chunk \(i): blank — passthrough")
            return (chunk.text, nil, false)
        }

        // Fresh session per chunk so context doesn't bleed between
        // independent paragraphs. The session's only input is the
        // user-controlled `instructions` string — examples, constraints,
        // and rules all live in there.
        let session = LanguageModelSession(transcript: Self.buildTranscript(instructions: instructions))
        lintLog.notice("chunk \(i): in=\(Self.quoteForLog(chunk.text), privacy: .private)")

        // --- Attempt 1: guided, current cap ---
        //
        // Cap is `chars+256` so it accommodates JSON-escape inflation
        // (\n, \" etc) plus a token-count buffer beyond the legitimate
        // ≤30% growth ceiling the hallucination guard already enforces.
        // Floor of 128 protects very short chunks; ceiling of 2048
        // prevents pathological inputs from eating the whole 4096-token
        // context window.
        let cap1 = min(2048, max(128, chunk.text.count + 256))
        lintLog.notice("chunk \(i): attempt=1 cap=\(cap1, privacy: .public)")
        do {
            let raw = try await guidedRespond(session: session, prompt: chunk.text, cap: cap1)
            return shapeGuidedOutput(raw: raw, chunk: chunk, index: i, exhaustedRetries: false)
        } catch {
            switch Self.classify(error) {
            case .cancelled:
                throw CancellationError()
            case .passThroughGeneration(let issue):
                logCatch(i, attempt: 1, error: error)
                lintLog.notice("chunk \(i): GENERATION ERROR attempt=1 — passing original through")
                return (chunk.text, issue, false)
            case .deserialize:
                logCatch(i, attempt: 1, error: error)
                if !allowRetry || cap1 >= 2048 {
                    lintLog.notice("chunk \(i): DESERIALIZE attempt=1 — cap saturated or budget spent, falling back to unstructured")
                    return try await runUnstructured(session: session, chunk: chunk, index: i)
                }
                lintLog.notice("chunk \(i): DESERIALIZE attempt=1 — retrying with wider cap")
                // Fall through to Attempt 2 below.
            case .unclassified:
                logCatch(i, attempt: 1, error: error)
                lintLog.notice("chunk \(i): UNCLASSIFIED attempt=1 — falling back to unstructured")
                return try await runUnstructured(session: session, chunk: chunk, index: i)
            }
        }

        // --- Attempt 2: guided, wider cap ---
        //
        // ~4× the Attempt-1 cap, bounded by the 4096-token context
        // window. If 4× still doesn't fit, truncation isn't the root
        // cause and further retries waste latency — Attempt 3
        // (unstructured) is the recovery path for non-truncation
        // deserialize failures.
        if Task.isCancelled { throw CancellationError() }
        let cap2 = min(4096, max(512, chunk.text.count * 4))
        lintLog.notice("chunk \(i): attempt=2 cap=\(cap2, privacy: .public)")
        do {
            let raw = try await guidedRespond(session: session, prompt: chunk.text, cap: cap2)
            return shapeGuidedOutput(raw: raw, chunk: chunk, index: i, exhaustedRetries: true)
        } catch {
            switch Self.classify(error) {
            case .cancelled:
                throw CancellationError()
            case .passThroughGeneration(let issue):
                logCatch(i, attempt: 2, error: error)
                lintLog.notice("chunk \(i): GENERATION ERROR attempt=2 — passing original through")
                return (chunk.text, issue, true)
            case .deserialize:
                logCatch(i, attempt: 2, error: error)
                lintLog.notice("chunk \(i): DESERIALIZE attempt=2 — falling back to unstructured")
                return try await runUnstructured(session: session, chunk: chunk, index: i)
            case .unclassified:
                logCatch(i, attempt: 2, error: error)
                lintLog.notice("chunk \(i): UNCLASSIFIED attempt=2 — falling back to unstructured")
                return try await runUnstructured(session: session, chunk: chunk, index: i)
            }
        }
    }

    /// Attempt 3: unstructured generation (no `@Generable` schema). After
    /// success the raw text runs through `stripPreamble` (Attempt-3 only)
    /// then the same `stripWrappingQuotes` + `hallucinationReason`
    /// pipeline as the guided path. A `.leakedPhrase` hallucination from
    /// the unstructured path is downgraded to `.malformedOutput` (the
    /// schema-leak persisted even without guided generation — the user
    /// can't prompt-tune their way out; correct UX is "couldn't polish
    /// reliably," not "hallucinated").
    private func runUnstructured(
        session: LanguageModelSession,
        chunk: Chunk,
        index i: Int
    ) async throws -> (output: String, issue: LintIssue?, exhaustedRetries: Bool) {
        if Task.isCancelled { throw CancellationError() }
        let cap3 = min(4096, max(512, chunk.text.count * 4))
        lintLog.notice("chunk \(i): UNSTRUCTURED attempt=3 cap=\(cap3, privacy: .public)")
        do {
            let raw = try await unstructuredRespond(session: session, prompt: chunk.text, cap: cap3)
            return shapeUnstructuredOutput(raw: raw, chunk: chunk, index: i)
        } catch {
            switch Self.classify(error) {
            case .cancelled:
                throw CancellationError()
            case .passThroughGeneration(let issue):
                logCatch(i, attempt: 3, error: error)
                return (chunk.text, issue, true)
            case .deserialize, .unclassified:
                logCatch(i, attempt: 3, error: error)
                lintLog.notice("chunk \(i): ALL ATTEMPTS FAILED — fallback to original, issue=malformedOutput")
                return (chunk.text, .malformedOutput, true)
            }
        }
    }

    private func guidedRespond(session: LanguageModelSession, prompt: String, cap: Int) async throws -> String {
        let options = GenerationOptions(
            sampling: .greedy,
            temperature: 0.0,
            maximumResponseTokens: cap
        )
        let response = try await session.respond(
            to: prompt,
            generating: LintOutput.self,
            // The schema is implicit because the on-device model is
            // post-trained on guided generation — sending it again
            // costs tokens for no quality gain.
            includeSchemaInPrompt: false,
            options: options
        )
        return response.content.output
    }

    private func unstructuredRespond(session: LanguageModelSession, prompt: String, cap: Int) async throws -> String {
        let options = GenerationOptions(
            sampling: .greedy,
            temperature: 0.0,
            maximumResponseTokens: cap
        )
        let response = try await session.respond(to: prompt, options: options)
        return response.content
    }

    /// Hypothesis-validation log line: captures BOTH the localized
    /// description (the substring `classify` matches on) AND the typed
    /// `String(describing:)` form (which reveals whether deserialize
    /// arrived as a typed `GenerationError.someCase(...)` or as a
    /// generic Error). Both `.public` — structural diagnostic, no user
    /// text. Lets us confirm post-ship the framework's error shape
    /// without re-instrumenting.
    private func logCatch(_ i: Int, attempt n: Int, error: Error) {
        lintLog.notice("chunk \(i): catch attempt=\(n, privacy: .public) localized=\(Self.quoteForLog(error.localizedDescription), privacy: .public) raw=\(String(describing: error), privacy: .public)")
    }

    /// Post-success shaping for the guided path. Trim, strip wrapping
    /// quotes, then route through the existing hallucination guard.
    /// Identical to the unstructured shaper except it doesn't run
    /// `stripPreamble` (guided generation makes preamble structurally
    /// impossible — running the stripper would be pure overhead).
    private func shapeGuidedOutput(
        raw: String,
        chunk: Chunk,
        index i: Int,
        exhaustedRetries: Bool
    ) -> (output: String, issue: LintIssue?, exhaustedRetries: Bool) {
        lintLog.notice("chunk \(i): raw=\(Self.quoteForLog(raw), privacy: .private)")
        let polished = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = Self.stripWrappingQuotes(polished)
        if cleaned != polished {
            lintLog.notice("chunk \(i): stripped wrapping quotes")
        }
        return resolveHallucination(
            cleaned: cleaned,
            chunk: chunk,
            index: i,
            exhaustedRetries: exhaustedRetries,
            fromUnstructured: false
        )
    }

    /// Post-success shaping for the unstructured path. Trim, strip
    /// preamble, strip wrapping quotes, then route through the
    /// hallucination guard with the `fromUnstructured` flag set (used
    /// to downgrade `.leakedPhrase` → `.malformedOutput`).
    private func shapeUnstructuredOutput(
        raw: String,
        chunk: Chunk,
        index i: Int
    ) -> (output: String, issue: LintIssue?, exhaustedRetries: Bool) {
        lintLog.notice("chunk \(i): raw=\(Self.quoteForLog(raw), privacy: .private)")
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let depreambled = Self.stripPreamble(trimmed)
        if depreambled != trimmed {
            // Length-only log (no content) since preamble residue can
            // include private user-adjacent text.
            lintLog.notice("chunk \(i): stripped preamble (\(trimmed.count - depreambled.count, privacy: .public) chars)")
        }
        let cleaned = Self.stripWrappingQuotes(depreambled)
        if cleaned != depreambled {
            lintLog.notice("chunk \(i): stripped wrapping quotes")
        }
        return resolveHallucination(
            cleaned: cleaned,
            chunk: chunk,
            index: i,
            exhaustedRetries: true,
            fromUnstructured: true
        )
    }

    /// Shared tail for guided + unstructured shaping. Applies the same
    /// hallucination policy as before (`.wordCount*` keeps the output +
    /// flags as `.drifted`; `.addedParens` falls back to input as
    /// `.hallucinated`) with one new branch: a `.leakedPhrase` from the
    /// unstructured path becomes `.malformedOutput` (see
    /// `shapeUnstructuredOutput` for why).
    private func resolveHallucination(
        cleaned: String,
        chunk: Chunk,
        index i: Int,
        exhaustedRetries: Bool,
        fromUnstructured: Bool
    ) -> (output: String, issue: LintIssue?, exhaustedRetries: Bool) {
        if let reason = Self.hallucinationReason(input: chunk.text, output: cleaned) {
            switch reason {
            case .wordCountExpansion, .wordCountShrinkage:
                lintLog.notice("chunk \(i): DRIFTED (\(reason.description, privacy: .public)) — keeping output, flagging for review")
                lintLog.notice("chunk \(i): out=\(Self.quoteForLog(cleaned), privacy: .private)")
                return (cleaned, .drifted(reason: reason.description), exhaustedRetries)
            case .addedParens:
                lintLog.notice("chunk \(i): HALLUCINATED (\(reason.description, privacy: .public)) — falling back to original")
                return (chunk.text, .hallucinated(reason: reason.description), exhaustedRetries)
            case .leakedPhrase:
                if fromUnstructured {
                    lintLog.notice("chunk \(i): LEAKED PHRASE on unstructured (\(reason.description, privacy: .public)) — falling back to original, issue=malformedOutput")
                    return (chunk.text, .malformedOutput, exhaustedRetries)
                }
                lintLog.notice("chunk \(i): HALLUCINATED (\(reason.description, privacy: .public)) — falling back to original")
                return (chunk.text, .hallucinated(reason: reason.description), exhaustedRetries)
            }
        }
        if cleaned == chunk.text.trimmingCharacters(in: .whitespacesAndNewlines) {
            lintLog.notice("chunk \(i): NO-OP (model returned input verbatim)")
            return (cleaned, nil, exhaustedRetries)
        }
        lintLog.notice("chunk \(i): out=\(Self.quoteForLog(cleaned), privacy: .private)")
        return (cleaned, nil, exhaustedRetries)
    }

    /// Render a string for log output: wrap in quotes, escape literal newlines
    /// to `\n` so a multi-line value stays on one log line and is comparable
    /// to other one-line values.
    static func quoteForLog(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    /// Builds a minimal session transcript: just the user's instructions
    /// as a system message. We deliberately don't inject transcript-based
    /// few-shot turns — the on-device model overfits to specific phrases
    /// in those turns and parrots them into responses (we hit this with
    /// a "Hey, Katie" example that ended up prefixing every output). Any
    /// few-shot examples now live inline in the `instructions` string,
    /// where they're visible to the user in Advanced Mode.
    ///
    /// Not unit-tested: `Transcript`'s init takes framework-internal
    /// `Transcript.Entry` cases (`.instructions(...)`, etc.) whose own
    /// inner-init signatures aren't documented as stable test API. The
    /// body is also a five-line constructor; the integration tests in
    /// Layer 3 exercise it indirectly via the real lint() path.
    private static func buildTranscript(instructions: String) -> Transcript {
        Transcript(entries: [
            .instructions(.init(
                segments: [.text(.init(content: instructions))],
                toolDefinitions: []
            ))
        ])
    }

    /// Specific reason `hallucinationReason` flagged an output. Surfaced via
    /// `lintLog` so we can tell from the log which guard tripped, instead of
    /// just "the fallback fired."
    enum HallucinationReason: CustomStringConvertible {
        case addedParens
        case wordCountExpansion(input: Int, output: Int)
        case wordCountShrinkage(input: Int, output: Int)
        case leakedPhrase(String)

        var description: String {
            switch self {
            case .addedParens:
                return "added-parens"
            case .wordCountExpansion(let i, let o):
                return "word-expansion \(i)→\(o)"
            case .wordCountShrinkage(let i, let o):
                return "word-shrinkage \(i)→\(o)"
            case .leakedPhrase(let p):
                return "leaked-phrase \"\(p)\""
            }
        }
    }

    /// Heuristic check that catches the most common hallucination modes
    /// observed in production:
    ///   1. Parenthetical expansion (e.g. "SOP" → "SOP (Standard Operating Procedures)").
    ///   2. Significant word-count expansion (model invented connecting phrases).
    ///   3. Schema/instruction leakage: the on-device model occasionally
    ///      regurgitates fragments of its own response-format directive
    ///      (e.g. trailing "response format in json.") inside the polished
    ///      string. Reject any output that introduces those phrases.
    ///
    /// `includeWordCountChecks` is `true` for the on-device model where the
    /// 0.8×–1.3× envelope is calibrated to its GEC failure mode. The Claude
    /// path passes `false`: Claude rewrites more freely (and that freedom is
    /// usually *why* a user opted in), so the length envelope would trip on
    /// legitimate output. Parens and leaked-phrase guards stay in both
    /// paths — those catch real, model-agnostic failure modes.
    static func hallucinationReason(
        input: String,
        output: String,
        includeWordCountChecks: Bool = true
    ) -> HallucinationReason? {
        // 1. Parens in output that weren't in input.
        if output.contains("(") && !input.contains("(") {
            return .addedParens
        }

        // 2. Length guards.
        //    - Inputs ≥5 words: upper bound 1.3×. GEC literature suggests
        //      ±20%, but real-world dictation/typing routinely drops articles,
        //      prepositions, and helping verbs that a polish should restore —
        //      a terse 42-word status note can grow to 51 (1.21×) just from
        //      adding "the"/"a" and splitting run-on sentences. 1.3× still
        //      catches the typical hallucination shape ("like im talking to
        //      Tim" → "Hey Tim, how are you doing today?", 5→7 = 1.4×).
        //    - Inputs <5 words: the ratio is meaningless (1 word × 1.3
        //      rounds to 1), so a 1-word input could expand to 16 words and
        //      slip through. Use an absolute cap of input + 3 instead —
        //      legitimate short-input fixes ("he sell book" → "He sells the
        //      book.") don't add more than a couple of words.
        //    Lower bound (shrinkage): ≥8 words to leave room for duplicate
        //    removal ("the the" → "the") on shorter inputs.
        if includeWordCountChecks {
            let inputWords = input.split(whereSeparator: { $0.isWhitespace }).count
            let outputWords = output.split(whereSeparator: { $0.isWhitespace }).count
            if inputWords >= 5, Double(outputWords) > Double(inputWords) * 1.3 {
                return .wordCountExpansion(input: inputWords, output: outputWords)
            }
            if inputWords < 5, outputWords > inputWords + 3 {
                return .wordCountExpansion(input: inputWords, output: outputWords)
            }
            if inputWords >= 8, Double(outputWords) < Double(inputWords) * 0.8 {
                return .wordCountShrinkage(input: inputWords, output: outputWords)
            }
        }

        // 3. Schema/instruction leakage. These are phrases the user almost
        //    never types but the model emits when it fails to stay inside the
        //    `polished` field. Only trip if the phrase is in the output AND
        //    not in the input (so a user actually writing "in JSON" passes).
        let lowerOut = output.lowercased()
        let lowerIn = input.lowercased()
        // Excludes phrases that can appear naturally in user prose (e.g.
        // "no preamble" — "the doctor began without preamble"). Each entry
        // here should be something the user is overwhelmingly unlikely to
        // type but the model emits when it leaks its own directives.
        let leakedPhrases = [
            "response format",
            "in json",
            "json format",
            "polished:",
            "polished text:",
        ]
        for phrase in leakedPhrases {
            if lowerOut.contains(phrase), !lowerIn.contains(phrase) {
                return .leakedPhrase(phrase)
            }
        }
        return nil
    }

    /// Convenience boolean wrapper around `hallucinationReason` — kept so
    /// existing callers / tests don't need to unpack the enum.
    static func looksHallucinated(input: String, output: String) -> Bool {
        hallucinationReason(input: input, output: output) != nil
    }

    struct Chunk: Equatable {
        var text: String
        var isSeparator: Bool
    }

    /// Splits text into paragraph chunks separated by **blank lines** (two or
    /// more consecutive newlines). Single line breaks stay inside a chunk so
    /// the model can see related lines together — necessary for rules like
    /// "blank line between greeting and body". Separators are preserved
    /// verbatim so the rebuilt output keeps the user's original spacing.
    static func splitIntoChunks(_ text: String) -> [Chunk] {
        guard !text.isEmpty else { return [] }
        let scalars = Array(text)
        var chunks: [Chunk] = []
        var i = 0
        while i < scalars.count {
            // Collect a separator run only if it spans at least 2 newlines
            // (i.e. a blank line). Otherwise treat newlines as part of the
            // surrounding text chunk.
            if scalars[i].isNewline {
                var newlineCount = 0
                var j = i
                while j < scalars.count, scalars[j].isNewline {
                    newlineCount += 1
                    j += 1
                }
                if newlineCount >= 2 {
                    chunks.append(Chunk(text: String(scalars[i..<j]), isSeparator: true))
                    i = j
                    continue
                }
                // Single newline — fall through and let it be appended to the
                // current text chunk below.
            }
            // Build a text chunk: everything up to (but not including) the
            // next blank-line run, OR end of input.
            var j = i
            while j < scalars.count {
                if scalars[j].isNewline {
                    var k = j
                    var count = 0
                    while k < scalars.count, scalars[k].isNewline {
                        count += 1
                        k += 1
                    }
                    if count >= 2 { break } // stop before the blank line
                    j = k                   // single newline: keep walking
                } else {
                    j += 1
                }
            }
            if j > i {
                chunks.append(Chunk(text: String(scalars[i..<j]), isSeparator: false))
                i = j
            } else {
                i += 1 // safety: avoid infinite loop on degenerate input
            }
        }
        return chunks
    }

    static func stripWrappingQuotes(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let first = s.first!, last = s.last!
        let pairs: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}"), ("'", "'"), ("`", "`")]
        if pairs.contains(where: { $0.0 == first && $0.1 == last }) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> (String, Bool) {
        // The exact enum cases depend on the SDK version; we render whatever
        // the system tells us into a friendly message.
        let raw = String(describing: reason)
        let lower = raw.lowercased()
        if lower.contains("appleintelligence") || lower.contains("apple_intelligence") {
            return ("Apple Intelligence is off. Enable it in System Settings to use Write Lint.", false)
        }
        if lower.contains("notenabled") || lower.contains("disabled") {
            return ("Apple Intelligence isn't enabled on this Mac. Turn it on in System Settings.", false)
        }
        if lower.contains("download") || lower.contains("install") {
            return ("The on-device model is still downloading. Try again in a moment.", true)
        }
        if lower.contains("region") || lower.contains("locale") || lower.contains("language") {
            return ("This Mac's region or language doesn't support the on-device model yet.", false)
        }
        if lower.contains("device") || lower.contains("hardware") || lower.contains("notsupported") {
            return ("This Mac doesn't support Apple Intelligence's on-device model.", false)
        }
        return ("On-device model isn't available right now (\(raw)).", false)
    }
}
