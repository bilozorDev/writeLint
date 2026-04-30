import Foundation
import FoundationModels

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

    func lint(text: String, template: Template) async throws -> LintResult {
        guard case .available = availability else {
            if case .unavailable(let reason, _) = availability {
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

        // Generous per-chunk cap so a long single paragraph still completes.
        let options = GenerationOptions(maximumResponseTokens: 4096)

        do {
            var output = ""
            for chunk in chunks {
                if Task.isCancelled { throw LintError.cancelled }
                if chunk.isSeparator {
                    output += chunk.text
                    continue
                }
                let trimmed = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    output += chunk.text
                    continue
                }
                let session = LanguageModelSession(instructions: template.instructions)
                let response = try await session.respond(to: chunk.text, options: options)
                let raw = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = stripWrappingQuotes(raw)
                output += cleaned
            }

            let elapsed = clock.now - start
            let latencyMs = Int(Double(elapsed.components.seconds) * 1000.0
                + Double(elapsed.components.attoseconds) / 1e15)
            let ops = Diff.diff(text, output)
            let stats = Diff.countChanges(ops)
            return LintResult(output: output, ops: ops, stats: stats, latencyMs: latencyMs)
        } catch is CancellationError {
            throw LintError.cancelled
        } catch let e as LintError {
            throw e
        } catch {
            throw LintError.underlying(error)
        }
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
            return ("Apple Intelligence is off. Enable it in System Settings to use Linter.", false)
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
