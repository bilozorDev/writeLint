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

/// User-visible categorization of a chunk-level fallback. Maps to the warning
/// bar shown when output equals input only because the polish failed, not
/// because the text was already clean.
enum LintIssue: Equatable {
    /// Hallucination guard tripped (added parens, word-count drift, leaked
    /// instruction phrase). `reason` is the `HallucinationReason.description`
    /// so the UI can tailor the detail copy.
    case hallucinated(reason: String)
    /// `LanguageModelSession.GenerationError` we chose to swallow (guardrail,
    /// unsupported language, exceeded context window). `detail` is a friendly
    /// message for the user.
    case generationError(detail: String)
    /// Structured-output parsing failed (typically truncation or malformed
    /// JSON from the on-device model).
    case malformedOutput

    /// Headline shown in the warning bar.
    var headline: String {
        switch self {
        case .hallucinated:       return "Couldn't polish reliably"
        case .generationError:    return "Couldn't polish this text"
        case .malformedOutput:    return "Couldn't polish this text"
        }
    }

    /// Body copy below the headline. Short, actionable when possible.
    var detail: String {
        switch self {
        case .hallucinated(let reason):
            if reason.hasPrefix("word-expansion") {
                return "The model wrote new text instead of polishing yours, so we kept your original. If your input is a question, the model may be trying to answer it — try wording it as a statement."
            }
            if reason.hasPrefix("word-shrinkage") {
                return "The model dropped too much content, so we kept your original."
            }
            if reason == "added-parens" {
                return "The model expanded an acronym, so we kept your original."
            }
            if reason.hasPrefix("leaked-phrase") {
                return "The model's output included instruction text, so we kept your original."
            }
            return "We kept your original text."
        case .generationError(let detail):
            return detail
        case .malformedOutput:
            return "The on-device model returned malformed output, so we kept your original."
        }
    }

    /// Priority for surfacing one issue when multiple chunks fall back.
    /// Hallucinations rank highest because they're the most user-actionable
    /// (almost always a prompt-tunable problem), then framework generation
    /// errors (sometimes user-actionable: shorten, change wording), and
    /// finally malformed output, which is rarely something the user can fix.
    /// Used by `LintIssue.upgrade(_:with:)` to keep the highest-priority
    /// issue when a later chunk fires a more-actionable guard than an
    /// earlier one.
    var priority: Int {
        switch self {
        case .hallucinated:     return 2
        case .generationError:  return 1
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

@MainActor
final class FoundationModelService {
    static let shared = FoundationModelService()

    private let model = SystemLanguageModel.default

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

    /// Polish `text` using `instructions` as the entire system prompt sent
    /// to the model. The instructions string is the *only* input that
    /// shapes the model's behavior — no separately-injected few-shot turns,
    /// no schema-side hints layered on top. Examples (if any) live inside
    /// the instructions text so they're visible to the user in Advanced
    /// Mode.
    func lint(text: String, instructions: String) async throws -> LintResult {
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
            for (i, chunk) in chunks.enumerated() {
                if Task.isCancelled { throw LintError.cancelled }
                if chunk.isSeparator {
                    lintLog.debug("chunk \(i): separator (\(chunk.text.count) chars) — passthrough")
                    output += chunk.text
                    continue
                }
                let trimmed = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    lintLog.debug("chunk \(i): blank — passthrough")
                    output += chunk.text
                    continue
                }
                // Fresh session per chunk so context doesn't bleed between
                // independent paragraphs. The session's only input is the
                // user-controlled `instructions` string — examples,
                // constraints, and rules all live in there.
                let session = LanguageModelSession(transcript: Self.buildTranscript(instructions: instructions))
                lintLog.notice("chunk \(i): in=\(Self.quoteForLog(chunk.text), privacy: .private)")

                // Per-chunk options.
                // - greedy + temperature 0.0: deterministic minimal-edit
                //   transduction; sampling adds variance that hurts quality
                //   on this task per the GEC literature (Loem 2023, Coyne
                //   2023, Staruch 2025).
                // - maximumResponseTokens tied to chunk length: anti-
                //   hallucination guard at the decoder. Cap is `chars+256`
                //   so it accommodates JSON-escape inflation (\n, \"
                //   etc) plus a token-count buffer beyond the legitimate
                //   ≤30% growth ceiling the hallucination guard already
                //   enforces. Floor of 128 protects very short chunks;
                //   ceiling of 2048 prevents pathological inputs from
                //   eating the whole 4096-token context window.
                //
                // Earlier we used `chars/2 + 32`, which truncated long
                // outputs mid-string and tripped a deserialize failure
                // (the guided-generation parser saw an unterminated JSON
                // value). The looser cap fixes that without giving up
                // the hallucination protection — that lives in
                // `hallucinationReason` and runs after generation.
                let cap = min(2048, max(128, chunk.text.count + 256))
                let options = GenerationOptions(
                    sampling: .greedy,
                    temperature: 0.0,
                    maximumResponseTokens: cap
                )

                let raw: String
                do {
                    let response = try await session.respond(
                        to: chunk.text,
                        generating: LintOutput.self,
                        // The schema is implicit because the on-device model
                        // is post-trained on guided generation — sending it
                        // again costs tokens for no quality gain.
                        includeSchemaInPrompt: false,
                        options: options
                    )
                    raw = response.content.output
                } catch let e as LanguageModelSession.GenerationError {
                    // Pass through on known-benign generation errors:
                    //   - guardrailViolation: false-positives are common; a
                    //     polish-helper showing the user's text unchanged is
                    //     strictly better than throwing.
                    //   - unsupportedLanguageOrLocale: nothing we can do.
                    //   - exceededContextWindowSize: rare given paragraph
                    //     chunking, but clip-and-pass is acceptable.
                    // Other GenerationError variants (assets downloading,
                    // etc.) propagate so the user sees the toast.
                    if Self.isPassThroughableError(e) {
                        lintLog.notice("chunk \(i): GENERATION ERROR (\(String(describing: e), privacy: .public)) — passing original through")
                        output += chunk.text
                        currentIssue = LintIssue.upgrade(currentIssue, with: .generationError(detail: Self.friendlyGenerationErrorMessage(e)))
                        continue
                    }
                    throw e
                } catch let error {
                    // Some Foundation Models failures arrive as a generic
                    // error rather than a `GenerationError` case — most
                    // notably "Failed to deserialize a Generable type from
                    // model output", which fires when the structured output
                    // is malformed (typically truncation by
                    // `maximumResponseTokens`). Pass through silently rather
                    // than throwing — better UX than an error toast for what
                    // is, from the user's perspective, "the polish didn't
                    // succeed for this chunk." Logged so we can spot a
                    // pattern if it ever happens consistently.
                    let desc = error.localizedDescription.lowercased()
                    if desc.contains("deserialize") || desc.contains("decode") {
                        lintLog.notice("chunk \(i): DESERIALIZE FAILED (\(error.localizedDescription, privacy: .public)) — passing original through")
                        output += chunk.text
                        currentIssue = LintIssue.upgrade(currentIssue, with: .malformedOutput)
                        continue
                    }
                    throw error
                }
                let polished = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = stripWrappingQuotes(polished)
                lintLog.notice("chunk \(i): raw=\(Self.quoteForLog(raw), privacy: .private)")
                if cleaned != polished {
                    lintLog.notice("chunk \(i): stripped wrapping quotes")
                }
                // Hallucination guard — fall back to original chunk if the
                // model expanded the text (acronym expansion, invented
                // connectors). Better to no-op than to ship hallucinations.
                if let reason = Self.hallucinationReason(input: chunk.text, output: cleaned) {
                    lintLog.notice("chunk \(i): HALLUCINATED (\(reason.description, privacy: .public)) — falling back to original")
                    output += chunk.text
                    currentIssue = LintIssue.upgrade(currentIssue, with: .hallucinated(reason: reason.description))
                } else if cleaned == chunk.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                    lintLog.notice("chunk \(i): NO-OP (model returned input verbatim)")
                    output += cleaned
                } else {
                    lintLog.notice("chunk \(i): out=\(Self.quoteForLog(cleaned), privacy: .private)")
                    output += cleaned
                }
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
            return LintResult(output: output, ops: ops, stats: stats, latencyMs: latencyMs, issue: currentIssue)
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
    static func hallucinationReason(input: String, output: String) -> HallucinationReason? {
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

    private func stripWrappingQuotes(_ s: String) -> String {
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
