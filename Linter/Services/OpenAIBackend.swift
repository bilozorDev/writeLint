import Foundation
import os

/// OpenAI cloud lint path. Polishes user text via the Chat Completions API.
/// The surface mirrors `ClaudeBackend.lint(text:instructions:apiKey:model:)`
/// so the router in `FoundationModelService.lint` can delegate to either
/// cloud path without the UI knowing which one ran.
///
/// Per-chunk request structure mirrors the on-device path: input is split
/// via `FoundationModelService.splitIntoChunks`, each non-blank chunk gets
/// its own stateless HTTP request, and outputs are stitched back into a
/// single string. The diff and stats are computed identically — `LintResult`
/// looks the same to the UI regardless of backend.
@MainActor
final class OpenAIBackend {
    /// Subsystem matches the on-device + Claude paths so a developer
    /// filtering for "Hexaget.WriteLint" sees all three backends together.
    /// Category is "openai" so they can also be filtered apart when
    /// triaging a backend-specific issue.
    private let log = Logger(subsystem: "Hexaget.WriteLint", category: "openai")

    private let session: URLSession
    private let endpoint: URL

    /// Per-chunk response token cap. Same reasoning as the Claude path —
    /// a roomy single cap rather than scaling per-chunk, since the
    /// hallucination guard's word-count check is disabled here too.
    private static let maxTokensPerChunk = 2048

    init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!
    ) {
        self.session = session
        self.endpoint = endpoint
    }

    /// Polish `text` using `instructions` as the system prompt. Each chunk
    /// is a fresh HTTP request — Chat Completions is stateless by
    /// construction, so the "no context bleed between paragraphs"
    /// invariant comes for free.
    func lint(
        text: String,
        instructions: String,
        apiKey: String,
        model: OpenAIModel
    ) async throws -> LintResult {
        let clock = ContinuousClock()
        let start = clock.now

        let chunks = FoundationModelService.splitIntoChunks(text)
        log.notice("─── openai lint start: model=\(model.rawValue, privacy: .public) chunks=\(chunks.count) input=\(FoundationModelService.quoteForLog(text), privacy: .private)")

        do {
            var output = ""
            var currentIssue: LintIssue?
            for (i, chunk) in chunks.enumerated() {
                if Task.isCancelled { throw LintError.cancelled }
                if chunk.isSeparator {
                    log.debug("chunk \(i): separator (\(chunk.text.count) chars) — passthrough")
                    output += chunk.text
                    continue
                }
                let trimmed = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    log.debug("chunk \(i): blank — passthrough")
                    output += chunk.text
                    continue
                }

                log.notice("chunk \(i): in=\(FoundationModelService.quoteForLog(chunk.text), privacy: .private)")

                let raw: String
                do {
                    raw = try await sendChunk(
                        chunk.text,
                        systemPrompt: instructions,
                        apiKey: apiKey,
                        model: model
                    )
                } catch let openaiError as OpenAIError {
                    // Pass-through on any API failure — same UX as the
                    // Claude path. Surface the first issue via
                    // `LintResult.issue` so the UI shows a warning bar.
                    log.notice("chunk \(i): OPENAI ERROR (\(openaiError.logDescription, privacy: .public)) — passing original through")
                    output += chunk.text
                    currentIssue = LintIssue.upgrade(currentIssue, with: .generationError(detail: openaiError.userMessage))
                    continue
                }

                let polished = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = FoundationModelService.stripWrappingQuotes(polished)
                log.notice("chunk \(i): raw=\(FoundationModelService.quoteForLog(raw), privacy: .private)")
                if cleaned != polished {
                    log.notice("chunk \(i): stripped wrapping quotes")
                }
                // No hallucination guard on the cloud path (same as Claude).
                // GPT follows prompt directives reliably; users opting into
                // OpenAI usually want freer rewrites than the on-device
                // model allows. Trust the output; let the user judge.
                if cleaned == chunk.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                    log.notice("chunk \(i): NO-OP (model returned input verbatim)")
                    output += cleaned
                } else {
                    log.notice("chunk \(i): out=\(FoundationModelService.quoteForLog(cleaned), privacy: .private)")
                    output += cleaned
                }
            }

            let elapsed = clock.now - start
            let latencyMs = Int(Double(elapsed.components.seconds) * 1000.0
                + Double(elapsed.components.attoseconds) / 1e15)
            let inputCopy = text
            let outputCopy = output
            let ops = await Task.detached(priority: .userInitiated) {
                Diff.diff(inputCopy, outputCopy)
            }.value
            let stats = Diff.countChanges(ops)
            let issueTag: String = currentIssue.map { " issue=\(String(describing: $0))" } ?? ""
            log.notice("─── openai lint done: latency=\(latencyMs)ms +\(stats.added)/-\(stats.removed) words\(issueTag, privacy: .public), final=\(FoundationModelService.quoteForLog(output), privacy: .private)")
            return LintResult(input: text, output: output, ops: ops, stats: stats, latencyMs: latencyMs, issue: currentIssue)
        } catch is CancellationError {
            log.notice("openai lint cancelled")
            throw LintError.cancelled
        } catch let e as LintError {
            log.error("openai lint failed: \(e.localizedDescription, privacy: .public)")
            throw e
        } catch {
            log.error("openai lint failed: \(error.localizedDescription, privacy: .public)")
            throw LintError.underlying(error)
        }
    }

    /// Send a single chunk to Chat Completions and return the model's
    /// response text. The system prompt is the user's full instructions
    /// verbatim, sent as the first message with `role: "system"` (OpenAI's
    /// API has no top-level `system` field — system instructions live
    /// inside the messages array).
    private func sendChunk(
        _ chunk: String,
        systemPrompt: String,
        apiKey: String,
        model: OpenAIModel
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = RequestBody(
            model: model.rawValue,
            max_tokens: Self.maxTokensPerChunk,
            // The currently-exposed gpt-4.1 / gpt-5 family accepts
            // `temperature: 0` for near-deterministic chat-completion
            // output. The o-series reasoning models (o3, o-mini, etc.)
            // 400 on any non-default temperature — we don't expose them,
            // but if a future PR adds one this assumption needs to be
            // revisited (likely by gating the field on the model).
            temperature: 0.0,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: chunk),
            ]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw OpenAIError.offline
            case .timedOut:
                throw OpenAIError.timedOut
            case .cancelled:
                throw CancellationError()
            default:
                throw OpenAIError.network(urlError)
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenAIError.malformedResponse
        }
        switch http.statusCode {
        case 200..<300:
            let decoded: ResponseBody
            do {
                decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
            } catch {
                throw OpenAIError.malformedResponse
            }
            // Refusals come back as `finish_reason == "content_filter"`
            // (sometimes with empty content, sometimes with an apology).
            // Surface as a distinct error so the toast attributes the
            // cause to OpenAI's safety system rather than treating the
            // refusal text as a polish.
            guard let choice = decoded.choices.first else {
                throw OpenAIError.malformedResponse
            }
            if choice.finish_reason == "content_filter" {
                throw OpenAIError.refused(explanation: choice.message?.content)
            }
            // `finish_reason: "length"` means the model hit our
            // per-chunk `max_tokens` cap mid-output. The text returned is
            // *truncated* — accepting it as the polish would silently
            // ship broken output. Fall back to the original chunk and
            // surface a distinct issue. With `maxTokensPerChunk = 2048`
            // this is unlikely on grammar workloads, but the failure
            // mode warrants a real arm rather than silent acceptance.
            if choice.finish_reason == "length" {
                throw OpenAIError.truncated
            }
            guard let content = choice.message?.content, !content.isEmpty else {
                throw OpenAIError.malformedResponse
            }
            return content
        case 401:
            throw OpenAIError.unauthorized
        case 429:
            throw OpenAIError.rateLimited
        case 400..<500:
            throw OpenAIError.client(status: http.statusCode, message: Self.parseErrorMessage(data))
        default:
            throw OpenAIError.server(status: http.statusCode, message: Self.parseErrorMessage(data))
        }
    }

    private static func parseErrorMessage(_ data: Data) -> String? {
        // OpenAI error envelope: { "error": { "message": "...", "type":
        // "invalid_request_error", "code": "..." } }
        struct Envelope: Decodable {
            let error: Inner?
            struct Inner: Decodable { let message: String? }
        }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        return env.error?.message
    }

    private struct RequestBody: Encodable {
        let model: String
        let max_tokens: Int
        let temperature: Double
        let messages: [Message]
        struct Message: Encodable {
            let role: String
            let content: String
        }
    }

    private struct ResponseBody: Decodable {
        let choices: [Choice]
        struct Choice: Decodable {
            let message: Message?
            let finish_reason: String?
        }
        struct Message: Decodable {
            let content: String?
        }
    }
}

/// OpenAI-specific failure cases. Each maps to a user-visible message
/// (`userMessage`) and a one-line log description (`logDescription`). The
/// router in `OpenAIBackend.lint` converts these to `LintIssue
/// .generationError` so the existing UI surfaces them unchanged.
enum OpenAIError: Error {
    case offline
    case timedOut
    case unauthorized
    case rateLimited
    case refused(explanation: String?)
    /// `finish_reason: "length"` — the polish was truncated at our cap.
    /// Better to fall back than ship a half-polished chunk.
    case truncated
    case client(status: Int, message: String?)
    case server(status: Int, message: String?)
    case network(URLError)
    case malformedResponse

    var userMessage: String {
        switch self {
        case .offline:
            return "Can't reach OpenAI — you appear to be offline."
        case .timedOut:
            return "OpenAI took too long to respond. Try again."
        case .unauthorized:
            return "OpenAI rejected the API key. Check it in Settings."
        case .rateLimited:
            return "OpenAI is rate-limiting requests. Try again in a moment."
        case .refused(let explanation):
            return explanation.map { "OpenAI declined to polish this text: \($0)" }
                ?? "OpenAI declined to polish this text."
        case .truncated:
            return "OpenAI's response was cut off. Try a shorter passage."
        case .client(_, let message):
            return message.map { "OpenAI rejected the request: \($0)" } ?? "OpenAI rejected the request."
        case .server(_, let message):
            return message.map { "OpenAI API error: \($0)" } ?? "OpenAI API error."
        case .network:
            return "Couldn't reach OpenAI. Check your network and try again."
        case .malformedResponse:
            return "OpenAI returned an unexpected response."
        }
    }

    var logDescription: String {
        switch self {
        case .offline: return "offline"
        case .timedOut: return "timed-out"
        case .unauthorized: return "401-unauthorized"
        case .rateLimited: return "429-rate-limited"
        case .refused: return "refused"
        case .truncated: return "truncated-length"
        case .client(let s, let m): return "client-\(s)" + (m.map { " (\($0))" } ?? "")
        case .server(let s, let m): return "server-\(s)" + (m.map { " (\($0))" } ?? "")
        case .network(let e): return "network-\(e.code.rawValue)"
        case .malformedResponse: return "malformed-response"
        }
    }
}
