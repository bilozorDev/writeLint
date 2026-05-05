import Testing
import Foundation
@testable import Write_Lint

@Suite("OpenAIBackend — request shape, response parsing, and error mapping", .serialized)
@MainActor
struct OpenAIBackendTests {

    // MARK: Stub plumbing
    //
    // Mirror of ClaudeBackendTests's stub setup, with a separate
    // `URLProtocol` subclass so the `static var handler` doesn't collide
    // with the Claude suite if the test runner ever interleaves them
    // (the `.serialized` trait already covers within-suite ordering).

    final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let handler = StubProtocol.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        override func stopLoading() {}
    }

    private static func makeBackend() -> (OpenAIBackend, URL) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        let endpoint = URL(string: "https://stub.invalid/v1/chat/completions")!
        return (OpenAIBackend(session: session, endpoint: endpoint), endpoint)
    }

    private static func okResponse(_ url: URL, text: String, finishReason: String = "stop") -> (HTTPURLResponse, Data) {
        let payload: [String: Any] = [
            "id": "chatcmpl-test",
            "object": "chat.completion",
            "model": "gpt-4.1-mini",
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": text],
                "finish_reason": finishReason,
            ]],
        ]
        let body = try! JSONSerialization.data(withJSONObject: payload)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (response, body)
    }

    private static func errorResponse(_ url: URL, status: Int, message: String) -> (HTTPURLResponse, Data) {
        let payload: [String: Any] = [
            "error": [
                "message": message,
                "type": "invalid_request_error",
                "code": "test_error",
            ],
        ]
        let body = try! JSONSerialization.data(withJSONObject: payload)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (response, body)
    }

    // MARK: Request body assembly

    @Test func requestUsesBearerAuthAndJSON() async throws {
        let (backend, url) = Self.makeBackend()
        nonisolated(unsafe) var capturedRequest: URLRequest?
        StubProtocol.handler = { request in
            capturedRequest = request
            return Self.okResponse(url, text: "Hello.")
        }
        defer { StubProtocol.handler = nil }

        _ = try await backend.lint(
            text: "hello",
            instructions: "polish please",
            apiKey: "sk-test-key",
            model: .gpt41Mini
        )

        let req = try #require(capturedRequest)
        // OpenAI uses `Authorization: Bearer <key>`, NOT a custom header
        // like Anthropic's `x-api-key`.
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-key")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(req.httpMethod == "POST")
    }

    @Test func requestBodyHasSystemAndUserMessages() async throws {
        let (backend, url) = Self.makeBackend()
        nonisolated(unsafe) var capturedBody: Data?
        StubProtocol.handler = { request in
            // Same body-stream extraction pattern as ClaudeBackendTests.
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = Data()
                let chunkSize = 4096
                var chunk = [UInt8](repeating: 0, count: chunkSize)
                while stream.hasBytesAvailable {
                    let read = stream.read(&chunk, maxLength: chunkSize)
                    if read <= 0 { break }
                    buffer.append(chunk, count: read)
                }
                capturedBody = buffer
            } else {
                capturedBody = request.httpBody
            }
            return Self.okResponse(url, text: "Hello.")
        }
        defer { StubProtocol.handler = nil }

        _ = try await backend.lint(
            text: "hello",
            instructions: "polish please",
            apiKey: "sk",
            model: .gpt41
        )

        let body = try #require(capturedBody)
        let parsed = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(parsed["model"] as? String == "gpt-4.1")
        // Unlike Anthropic, OpenAI has no top-level `system` field —
        // instructions sit as the first message with role=system.
        #expect(parsed["system"] == nil)
        let messages = try #require(parsed["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "polish please")
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "hello")
    }

    // MARK: Happy path

    @Test func successfulResponseProducesPolishedOutput() async throws {
        let (backend, url) = Self.makeBackend()
        StubProtocol.handler = { _ in
            Self.okResponse(url, text: "Hello, world.")
        }
        defer { StubProtocol.handler = nil }

        let result = try await backend.lint(
            text: "helo world",
            instructions: "fix grammar",
            apiKey: "sk",
            model: .gpt41Mini
        )
        #expect(result.output == "Hello, world.")
        #expect(result.issue == nil)
    }

    @Test func wrappingQuotesAreStripped() async throws {
        let (backend, url) = Self.makeBackend()
        StubProtocol.handler = { _ in
            Self.okResponse(url, text: "\"Hello, world.\"")
        }
        defer { StubProtocol.handler = nil }

        let result = try await backend.lint(
            text: "helo world",
            instructions: "fix grammar",
            apiKey: "sk",
            model: .gpt41Mini
        )
        #expect(result.output == "Hello, world.")
    }

    @Test func emptyInputSkipsModelCallAndReturnsEmpty() async throws {
        let (backend, _) = Self.makeBackend()
        nonisolated(unsafe) var requestCount = 0
        StubProtocol.handler = { _ in
            requestCount += 1
            return Self.errorResponse(URL(string: "https://stub.invalid")!, status: 500, message: "should not be called")
        }
        defer { StubProtocol.handler = nil }

        let result = try await backend.lint(
            text: "",
            instructions: "polish",
            apiKey: "sk",
            model: .gpt41Mini
        )
        #expect(result.output == "")
        #expect(requestCount == 0)
    }

    // MARK: Error mapping

    @Test func unauthorizedMapsToFriendlyIssue() async throws {
        let (backend, url) = Self.makeBackend()
        StubProtocol.handler = { _ in
            Self.errorResponse(url, status: 401, message: "Invalid API key")
        }
        defer { StubProtocol.handler = nil }

        let result = try await backend.lint(
            text: "hello",
            instructions: "polish",
            apiKey: "sk-bad",
            model: .gpt41Mini
        )
        #expect(result.output == "hello")
        switch result.issue {
        case .generationError(let detail):
            #expect(detail.contains("API key"))
        default:
            Issue.record("expected generationError, got \(String(describing: result.issue))")
        }
    }

    @Test func rateLimitMapsToRetryHint() async throws {
        let (backend, url) = Self.makeBackend()
        StubProtocol.handler = { _ in
            Self.errorResponse(url, status: 429, message: "rate-limited")
        }
        defer { StubProtocol.handler = nil }

        let result = try await backend.lint(
            text: "hello",
            instructions: "polish",
            apiKey: "sk",
            model: .gpt41Mini
        )
        #expect(result.output == "hello")
        switch result.issue {
        case .generationError(let detail):
            #expect(detail.localizedCaseInsensitiveContains("rate"))
        default:
            Issue.record("expected generationError, got \(String(describing: result.issue))")
        }
    }

    @Test func offlineMapsToOfflineMessage() async throws {
        let (backend, _) = Self.makeBackend()
        StubProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer { StubProtocol.handler = nil }

        let result = try await backend.lint(
            text: "hello",
            instructions: "polish",
            apiKey: "sk",
            model: .gpt41Mini
        )
        #expect(result.output == "hello")
        switch result.issue {
        case .generationError(let detail):
            #expect(detail.localizedCaseInsensitiveContains("offline"))
        default:
            Issue.record("expected generationError, got \(String(describing: result.issue))")
        }
    }

    @Test func contentFilterSurfacesAsRefusal() async throws {
        let (backend, url) = Self.makeBackend()
        StubProtocol.handler = { _ in
            // OpenAI signals safety refusals via `finish_reason:
            // "content_filter"`; the assistant content may be empty or an
            // apology. Either way, we surface this as a distinct refusal
            // rather than treating the message text as a polish.
            Self.okResponse(url, text: "I can't help with that.", finishReason: "content_filter")
        }
        defer { StubProtocol.handler = nil }

        let result = try await backend.lint(
            text: "hello",
            instructions: "polish",
            apiKey: "sk",
            model: .gpt41Mini
        )
        #expect(result.output == "hello")
        switch result.issue {
        case .generationError(let detail):
            #expect(detail.localizedCaseInsensitiveContains("declined"))
        default:
            Issue.record("expected generationError, got \(String(describing: result.issue))")
        }
    }

    @Test func truncationFallsBackInsteadOfShippingPartial() async throws {
        let (backend, url) = Self.makeBackend()
        StubProtocol.handler = { _ in
            // 200 with `finish_reason: "length"` means the model hit our
            // per-chunk `max_tokens` cap. The text in `message.content`
            // is whatever it managed to emit mid-stream. We don't trust
            // it as the polish; falls back to the original.
            Self.okResponse(url, text: "Hello, wor", finishReason: "length")
        }
        defer { StubProtocol.handler = nil }

        let result = try await backend.lint(
            text: "hello world",
            instructions: "polish",
            apiKey: "sk",
            model: .gpt41Mini
        )
        #expect(result.output == "hello world")
        switch result.issue {
        case .generationError(let detail):
            #expect(detail.localizedCaseInsensitiveContains("cut off")
                 || detail.localizedCaseInsensitiveContains("truncat"))
        default:
            Issue.record("expected generationError, got \(String(describing: result.issue))")
        }
    }

    @Test func malformedJSONFallsBackGracefully() async throws {
        let (backend, _) = Self.makeBackend()
        StubProtocol.handler = { _ in
            let url = URL(string: "https://stub.invalid")!
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data("not json".utf8))
        }
        defer { StubProtocol.handler = nil }

        let result = try await backend.lint(
            text: "hello",
            instructions: "polish",
            apiKey: "sk",
            model: .gpt41Mini
        )
        // Same fallback semantics as the Claude path: malformed responses
        // get treated as a per-chunk pass-through, output preserved.
        #expect(result.output == "hello" || result.output.isEmpty)
    }

    // MARK: Multi-chunk + structure preservation

    @Test func blankLineStructurePreservedAcrossChunks() async throws {
        let (backend, url) = Self.makeBackend()
        StubProtocol.handler = { request in
            // Echo the user message back uppercased to verify the per-chunk
            // loop calls through and stitches separators correctly.
            let body: Data = {
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buf = Data(); var chunk = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let r = stream.read(&chunk, maxLength: 4096)
                        if r <= 0 { break }
                        buf.append(chunk, count: r)
                    }
                    return buf
                }
                return request.httpBody ?? Data()
            }()
            let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let messages = parsed?["messages"] as? [[String: Any]]
            // Find the user message (system is messages[0], user is [1])
            let userText = (messages?.first(where: { ($0["role"] as? String) == "user" })?["content"] as? String) ?? ""
            return Self.okResponse(url, text: userText.uppercased())
        }
        defer { StubProtocol.handler = nil }

        let result = try await backend.lint(
            text: "para one\n\npara two",
            instructions: "uppercase",
            apiKey: "sk",
            model: .gpt41Mini
        )
        #expect(result.output == "PARA ONE\n\nPARA TWO")
    }
}
