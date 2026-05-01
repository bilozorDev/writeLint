import Foundation
import FoundationModels
import os

/// Lint pipeline tracing. Writes through Apple's unified logging — visible in
/// Xcode's console while running, and in Console.app filtering for subsystem
/// "Hexaget.Linter" / category "lint" while the app runs standalone.
/// Inputs/outputs are marked `.public` so they actually appear in the logs
/// (Logger redacts dynamic strings to `<private>` by default). User text is
/// not sensitive in this app — the whole point is to see exactly what the
/// model received and emitted.
private let lintLog = Logger(subsystem: "Hexaget.Linter", category: "lint")

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
}

/// Guided-generation schema. Forces the model to emit just the polished text
/// in a single JSON field — preamble like "Sure, here is the polished text:"
/// becomes structurally impossible because there's no field for it.
@Generable
struct PolishedText {
    @Guide(description: "The polished text only. No preamble, no commentary, no quote marks.")
    let polished: String
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
    private static func isPassThroughableError(_ error: LanguageModelSession.GenerationError) -> Bool {
        switch error {
        case .guardrailViolation, .unsupportedLanguageOrLocale, .exceededContextWindowSize:
            return true
        default:
            return false
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

        lintLog.notice("─── lint start: chunks=\(chunks.count) input=\(Self.quoteForLog(text), privacy: .public)")

        do {
            var output = ""
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
                lintLog.notice("chunk \(i): in=\(Self.quoteForLog(chunk.text), privacy: .public)")

                // Per-chunk options.
                // - greedy + temperature 0.0: deterministic minimal-edit
                //   transduction; sampling adds variance that hurts quality
                //   on this task per the GEC literature (Loem 2023, Coyne
                //   2023, Staruch 2025).
                // - maximumResponseTokens tied to chunk length: free
                //   anti-hallucination guard at the decoder. Hallucinated
                //   additions tend to be long; clipping at +50% prevents
                //   the model from physically writing a fluency rewrite.
                //   Floor of 64 protects very short chunks.
                let cap = max(64, (chunk.text.count / 2) + 32)
                let options = GenerationOptions(
                    sampling: .greedy,
                    temperature: 0.0,
                    maximumResponseTokens: cap
                )

                let raw: String
                do {
                    let response = try await session.respond(
                        to: chunk.text,
                        generating: PolishedText.self,
                        // The schema is implicit because the on-device model
                        // is post-trained on guided generation — sending it
                        // again costs tokens for no quality gain.
                        includeSchemaInPrompt: false,
                        options: options
                    )
                    raw = response.content.polished
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
                        continue
                    }
                    throw e
                }
                let polished = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = stripWrappingQuotes(polished)
                lintLog.notice("chunk \(i): raw=\(Self.quoteForLog(raw), privacy: .public)")
                if cleaned != polished {
                    lintLog.notice("chunk \(i): stripped wrapping quotes")
                }
                // Hallucination guard — fall back to original chunk if the
                // model expanded the text (acronym expansion, invented
                // connectors). Better to no-op than to ship hallucinations.
                if let reason = Self.hallucinationReason(input: chunk.text, output: cleaned) {
                    lintLog.notice("chunk \(i): HALLUCINATED (\(reason.description, privacy: .public)) — falling back to original")
                    output += chunk.text
                } else if cleaned == chunk.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                    lintLog.notice("chunk \(i): NO-OP (model returned input verbatim)")
                    output += cleaned
                } else {
                    lintLog.notice("chunk \(i): out=\(Self.quoteForLog(cleaned), privacy: .public)")
                    output += cleaned
                }
            }

            let elapsed = clock.now - start
            let latencyMs = Int(Double(elapsed.components.seconds) * 1000.0
                + Double(elapsed.components.attoseconds) / 1e15)
            let ops = Diff.diff(text, output)
            let stats = Diff.countChanges(ops)
            lintLog.notice("─── lint done: latency=\(latencyMs)ms +\(stats.added)/-\(stats.removed) words, final=\(Self.quoteForLog(output), privacy: .public)")
            return LintResult(output: output, ops: ops, stats: stats, latencyMs: latencyMs)
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
    private static func quoteForLog(_ s: String) -> String {
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

        // 2. Length-ratio guard, ±20% around the input word count. Only
        //    enforced for inputs ≥5 words so a 2-word input can still
        //    legitimately gain articles/punctuation fixes. Tightened from
        //    1.3× per the GEC research recommendation of [0.8, 1.2].
        //    The lower bound catches the rare case where the model deletes
        //    legitimate content; gated to ≥8 words to leave room for
        //    duplicate removal ("the the" → "the") on shorter inputs.
        let inputWords = input.split(whereSeparator: { $0.isWhitespace }).count
        let outputWords = output.split(whereSeparator: { $0.isWhitespace }).count
        if inputWords >= 5, Double(outputWords) > Double(inputWords) * 1.2 {
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

    private struct Chunk {
        var text: String
        var isSeparator: Bool
    }

    /// Splits text into paragraph chunks separated by **blank lines** (two or
    /// more consecutive newlines). Single line breaks stay inside a chunk so
    /// the model can see related lines together — necessary for rules like
    /// "blank line between greeting and body". Separators are preserved
    /// verbatim so the rebuilt output keeps the user's original spacing.
    private static func splitIntoChunks(_ text: String) -> [Chunk] {
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
