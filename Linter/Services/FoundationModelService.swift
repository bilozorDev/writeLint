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

    /// Splits text into paragraph chunks separated by blank lines, preserving
    /// the exact separator characters so the rebuilt output keeps the user's
    /// original spacing.
    private static func splitIntoChunks(_ text: String) -> [Chunk] {
        guard !text.isEmpty else { return [] }
        var chunks: [Chunk] = []
        var current = ""
        var currentIsSep = text.first?.isNewline ?? false

        for ch in text {
            let isSep = ch.isNewline
            if isSep == currentIsSep {
                current.append(ch)
            } else {
                chunks.append(Chunk(text: current, isSeparator: currentIsSep))
                current = String(ch)
                currentIsSep = isSep
            }
        }
        if !current.isEmpty {
            chunks.append(Chunk(text: current, isSeparator: currentIsSep))
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
