import Foundation
import os

/// Cloud lint path. Polishes user text via Anthropic's Messages API. The
/// surface mirrors `FoundationModelService.lint(text:instructions:)` so the
/// router in `FoundationModelService.lint` can delegate to either path
/// without the UI knowing which one ran.
///
/// Per-chunk request structure mirrors the on-device path: input is split via
/// `FoundationModelService.splitIntoChunks` (preserving blank-line separators
/// verbatim), each non-blank chunk gets its own stateless HTTP request, and
/// outputs are stitched back into a single string. The diff and stats are
/// computed identically — `LintResult` looks the same to the UI regardless
/// of backend.
@MainActor
final class ClaudeBackend {
    /// Subsystem matches the on-device path so a developer filtering for
    /// "Hexaget.WriteLint" sees both backends together. Category is "claude"
    /// so they can also be filtered apart when triaging a backend-specific
    /// issue.
    private let log = Logger(subsystem: "Hexaget.WriteLint", category: "claude")

    private let session: URLSession
    private let endpoint: URL
    private let anthropicVersion = "2023-06-01"

    /// Per-chunk response token cap. The on-device path scales the cap with
    /// chunk length; for Claude we use a single roomy cap because (a) tokens
    /// are cheaper than the latency hit of a too-tight cap forcing a retry,
    /// and (b) the hallucination guard's word-count check is disabled on
    /// this path anyway, so the structural anti-runaway is at the API layer.
    private static let maxTokensPerChunk = 2048

    init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!
    ) {
        self.session = session
        self.endpoint = endpoint
    }

    /// Polish `text` using `instructions` as the system prompt. Each chunk is
    /// a fresh HTTP request — Claude's API is stateless by construction, so
    /// the "no context bleed between paragraphs" invariant comes for free.
    func lint(
        text: String,
        instructions: String,
        apiKey: String,
        model: ClaudeModel
    ) async throws -> LintResult {
        let clock = ContinuousClock()
        let start = clock.now

        let chunks = FoundationModelService.splitIntoChunks(text)
        log.notice("─── claude lint start: model=\(model.rawValue, privacy: .public) chunks=\(chunks.count) input=\(FoundationModelService.quoteForLog(text), privacy: .private)")

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
                } catch let claudeError as ClaudeError {
                    // All HTTP / network failures convert to pass-through:
                    // returning the user's original text is strictly better
                    // than erroring out the whole lint when only one chunk
                    // failed. The first such issue is surfaced via
                    // `LintResult.issue` so the UI can show a warning bar.
                    log.notice("chunk \(i): CLAUDE ERROR (\(claudeError.logDescription, privacy: .public)) — passing original through")
                    output += chunk.text
                    currentIssue = LintIssue.upgrade(currentIssue, with: .generationError(detail: claudeError.userMessage))
                    continue
                }

                let polished = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = FoundationModelService.stripWrappingQuotes(polished)
                log.notice("chunk \(i): raw=\(FoundationModelService.quoteForLog(raw), privacy: .private)")
                if cleaned != polished {
                    log.notice("chunk \(i): stripped wrapping quotes")
                }
                // No hallucination guard on the cloud path. Claude follows
                // prompt directives reliably (no spontaneous acronym
                // expansion or instruction-leak in our usage), and a key
                // reason users opt into a cloud backend is exactly to
                // unlock more freeform rewrites. Trust the output; let the
                // user judge.
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
            log.notice("─── claude lint done: latency=\(latencyMs)ms +\(stats.added)/-\(stats.removed) words\(issueTag, privacy: .public), final=\(FoundationModelService.quoteForLog(output), privacy: .private)")
            return LintResult(input: text, output: output, ops: ops, stats: stats, latencyMs: latencyMs, issue: currentIssue)
        } catch is CancellationError {
            log.notice("claude lint cancelled")
            throw LintError.cancelled
        } catch let e as LintError {
            log.error("claude lint failed: \(e.localizedDescription, privacy: .public)")
            throw e
        } catch {
            log.error("claude lint failed: \(error.localizedDescription, privacy: .public)")
            throw LintError.underlying(error)
        }
    }

    /// Send a single chunk to the Messages API and return the model's
    /// `text` response. The system prompt is the user's full instructions
    /// verbatim (no code-side few-shot, matching the on-device invariant —
    /// "everything the model sees is in store.instructions").
    ///
    /// Anthropic's Messages API is well-suited to per-chunk lints: stateless
    /// by construction, so no transcript leakage between paragraphs.
    private func sendChunk(
        _ chunk: String,
        systemPrompt: String,
        apiKey: String,
        model: ClaudeModel
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body = RequestBody(
            model: model.rawValue,
            max_tokens: Self.maxTokensPerChunk,
            system: systemPrompt,
            messages: [.init(role: "user", content: chunk)],
            // Grammar polishing is a short, scoped task — `low` is the
            // right cost/latency tradeoff per Anthropic's effort guide.
            // Haiku 4.5 doesn't accept the field and would 400, so omit
            // the whole `output_config` object on that model.
            output_config: model.supportsEffort ? .init(effort: "low") : nil
        )
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw ClaudeError.offline
            case .timedOut:
                throw ClaudeError.timedOut
            case .cancelled:
                // URLSession surfaces `.cancelled` when the task was cancelled
                // — propagate as Swift CancellationError so the caller's
                // `catch is CancellationError` arm fires.
                throw CancellationError()
            default:
                throw ClaudeError.network(urlError)
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeError.malformedResponse
        }
        switch http.statusCode {
        case 200..<300:
            // Decode failure here means a 200 with a body that doesn't match
            // the Messages API schema — convert to `malformedResponse` so the
            // caller treats it as a per-chunk pass-through, matching how the
            // on-device path handles its analogous "deserialize failed" case.
            let decoded: ResponseBody
            do {
                decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
            } catch {
                throw ClaudeError.malformedResponse
            }
            // Refusals carry a 200 with `content` populated and
            // `stop_reason: "refusal"`. The text in `content` is the
            // refusal message ("I can't help with that"), not a polish —
            // surface it as its own error case so the toast reads
            // "Claude declined…" instead of treating the refusal text as
            // the polished output.
            if decoded.stop_reason == "refusal" {
                throw ClaudeError.refused(explanation: decoded.stop_details?.explanation)
            }
            // `stop_reason: "max_tokens"` means the model hit our
            // per-chunk cap mid-output. The text returned is *truncated*
            // — accepting it as the polish would silently ship broken
            // output (cut-off sentence, dangling parenthesis). Fall back
            // to the original chunk and surface a distinct issue. With
            // `maxTokensPerChunk = 2048` this is unlikely on grammar
            // workloads, but the failure mode warrants a real arm rather
            // than a silent acceptance.
            if decoded.stop_reason == "max_tokens" {
                throw ClaudeError.truncated
            }
            // Concatenate every text block. In practice the Messages API
            // returns a single text block for a non-tool-use request, but
            // the schema is an array — defending against a future variant
            // is one line.
            let combined = decoded.content
                .compactMap { $0.type == "text" ? $0.text : nil }
                .joined()
            if combined.isEmpty {
                throw ClaudeError.malformedResponse
            }
            return combined
        case 401:
            throw ClaudeError.unauthorized
        case 429:
            throw ClaudeError.rateLimited
        case 400..<500:
            throw ClaudeError.client(status: http.statusCode, message: Self.parseErrorMessage(data))
        default:
            throw ClaudeError.server(status: http.statusCode, message: Self.parseErrorMessage(data))
        }
    }

    private static func parseErrorMessage(_ data: Data) -> String? {
        // Anthropic error envelope: { "type":"error", "error": { "type":..., "message":... } }
        struct Envelope: Decodable { let error: Inner?; struct Inner: Decodable { let message: String? } }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        return env.error?.message
    }

    private struct RequestBody: Encodable {
        let model: String
        let max_tokens: Int
        let system: String
        let messages: [Message]
        let output_config: OutputConfig?
        struct Message: Encodable {
            let role: String
            let content: String
        }
        struct OutputConfig: Encodable {
            let effort: String
        }
    }

    private struct ResponseBody: Decodable {
        let content: [Block]
        let stop_reason: String?
        let stop_details: StopDetails?
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        struct StopDetails: Decodable {
            let category: String?
            let explanation: String?
        }
    }
}

/// Backend-specific failure cases. Each maps to a user-visible message
/// (`userMessage`) and a one-line log description (`logDescription`). The
/// router in `ClaudeBackend.lint` converts these to `LintIssue
/// .generationError` so the existing UI surfaces them unchanged.
enum ClaudeError: Error {
    case offline
    case timedOut
    case unauthorized
    case rateLimited
    case refused(explanation: String?)
    /// `stop_reason: "max_tokens"` — the polish was truncated at our cap.
    /// Better to fall back than ship a half-polished chunk.
    case truncated
    case client(status: Int, message: String?)
    case server(status: Int, message: String?)
    case network(URLError)
    case malformedResponse

    /// What the user sees in the warning bar / toast.
    var userMessage: String {
        switch self {
        case .offline:
            return "Can't reach Claude — you appear to be offline."
        case .timedOut:
            return "Claude took too long to respond. Try again."
        case .unauthorized:
            return "Claude rejected the API key. Check it in Settings."
        case .rateLimited:
            return "Claude is rate-limiting requests. Try again in a moment."
        case .refused(let explanation):
            return explanation.map { "Claude declined to polish this text: \($0)" }
                ?? "Claude declined to polish this text."
        case .truncated:
            return "Claude's response was cut off. Try a shorter passage."
        case .client(_, let message):
            return message.map { "Claude rejected the request: \($0)" } ?? "Claude rejected the request."
        case .server(_, let message):
            return message.map { "Claude API error: \($0)" } ?? "Claude API error."
        case .network:
            return "Couldn't reach Claude. Check your network and try again."
        case .malformedResponse:
            return "Claude returned an unexpected response."
        }
    }

    /// Compact form for the unified log. Stays `.public` because none of
    /// these contain user text.
    var logDescription: String {
        switch self {
        case .offline:
            return "offline"
        case .timedOut:
            return "timed-out"
        case .unauthorized:
            return "401-unauthorized"
        case .rateLimited:
            return "429-rate-limited"
        case .refused:
            return "refused"
        case .truncated:
            return "truncated-max-tokens"
        case .client(let s, let m):
            return "client-\(s)" + (m.map { " (\($0))" } ?? "")
        case .server(let s, let m):
            return "server-\(s)" + (m.map { " (\($0))" } ?? "")
        case .network(let e):
            return "network-\(e.code.rawValue)"
        case .malformedResponse:
            return "malformed-response"
        }
    }
}
