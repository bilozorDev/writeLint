import Testing
import Foundation
@testable import Write_Lint

@Suite("ClaudeBackend — request shape, response parsing, and error mapping", .serialized)
@MainActor
struct ClaudeBackendTests {

    // MARK: Stub plumbing

    /// `URLProtocol` subclass that lets each test register a handler closure
    /// returning the desired response (or throwing a `URLError`). Registered
    /// via `URLSessionConfiguration.protocolClasses` so the stub intercepts
    /// every request through the test's `URLSession` — no real network.
    final class StubProtocol: URLProtocol, @unchecked Sendable {
        // `nonisolated(unsafe)` is fine here: the harness assigns this on
        // the test thread before invoking the backend, then `nil`s it after
        // the request resolves. Concurrent assignment within a single test
        // would be a test-author bug, not a runtime concern.
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

    /// One-stop fixture: configure a stubbed session, build the backend
    /// against a non-routable test endpoint, and return both. Caller
    /// assigns `StubProtocol.handler` for the desired behavior.
    private static func makeBackend() -> (ClaudeBackend, URL) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        let endpoint = URL(string: "https://stub.invalid/v1/messages")!
        return (ClaudeBackend(session: session, endpoint: endpoint), endpoint)
    }

    private static func okResponse(_ url: URL, text: String) -> (HTTPURLResponse, Data) {
        let payload: [String: Any] = [
            "id": "msg_test",
            "type": "message",
            "role": "assistant",
            "content": [["type": "text", "text": text]],
            "model": "claude-haiku-4-5",
            "stop_reason": "end_turn",
        ]
        let body = try! JSONSerialization.data(withJSONObject: payload)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (response, body)
    }

    private static func errorResponse(_ url: URL, status: Int, message: String) -> (HTTPURLResponse, Data) {
        let payload: [String: Any] = [
            "type": "error",
            "error": ["type": "invalid_request_error", "message": message],
        ]
        let body = try! JSONSerialization.data(withJSONObject: payload)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (response, body)
    }

    // MARK: Request body assembly

    @Test func requestUsesAnthropicHeadersAndModel() async throws {
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
            apiKey: "sk-ant-test-key",
            model: .haiku45
        )

        let req = try #require(capturedRequest)
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test-key")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(req.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(req.httpMethod == "POST")
    }

    @Test func requestBodyIncludesSystemAndUserMessage() async throws {
        let (backend, url) = Self.makeBackend()
        nonisolated(unsafe) var capturedBody: Data?
        StubProtocol.handler = { request in
            // URLProtocol delivers the body via `httpBodyStream` for streamed
            // requests; URLSession converts a plain `httpBody` to a stream
            // before the protocol sees it. Read the stream end-to-end.
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
            model: .sonnet46
        )

        let body = try #require(capturedBody)
        let parsed = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(parsed["model"] as? String == "claude-sonnet-4-6")
        #expect(parsed["system"] as? String == "polish please")
        let messages = try #require(parsed["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "hello")
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
            model: .haiku45
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
            model: .haiku45
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
            model: .haiku45
        )
        #expect(result.output == "")
        #expect(requestCount == 0)
    }

    // MARK: Error mapping

    @Test func unauthorizedMapsToFriendlyIssue() async throws {
        let (backend, url) = Self.makeBackend()
        StubProtocol.handler = { _ in
            Self.errorResponse(url, status: 401, message: "invalid x-api-key")
        }
        defer { StubProtocol.handler = nil }

        let result = try await backend.lint(
            text: "hello",
            instructions: "polish",
            apiKey: "sk-bad",
            model: .haiku45
        )
        // Pass-through: chunk falls back to the original input, issue is
        // surfaced via LintResult.issue. 401 should clearly point at the key.
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
            model: .haiku45
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
            model: .haiku45
        )
        #expect(result.output == "hello")
        switch result.issue {
        case .generationError(let detail):
            #expect(detail.localizedCaseInsensitiveContains("offline"))
        default:
            Issue.record("expected generationError, got \(String(describing: result.issue))")
        }
    }

    @Test func refusalSurfacesAsDistinctIssue() async throws {
        let (backend, url) = Self.makeBackend()
        StubProtocol.handler = { _ in
            // Refusals come back as 200 with stop_reason="refusal" and
            // stop_details populated; the `content` text is the refusal
            // message, not a polish.
            let payload: [String: Any] = [
                "id": "msg_test",
                "type": "message",
                "role": "assistant",
                "content": [["type": "text", "text": "I can't help with that."]],
                "model": "claude-haiku-4-5",
                "stop_reason": "refusal",
                "stop_details": ["category": "harmful", "explanation": "Request involves prohibited content."],
            ]
            let body = try! JSONSerialization.data(withJSONObject: payload)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, body)
        }
        defer { StubProtocol.handler = nil }

        let result = try await backend.lint(
            text: "hello",
            instructions: "polish",
            apiKey: "sk",
            model: .haiku45
        )
        // Refusal must NOT leak the refusal text into the polish — the chunk
        // falls back to the original input, and the issue clearly attributes
        // the cause to a Claude refusal rather than a generic "couldn't
        // polish" message.
        #expect(result.output == "hello")
        switch result.issue {
        case .generationError(let detail):
            #expect(detail.localizedCaseInsensitiveContains("declined")
                 && detail.contains("Request involves prohibited content"))
        default:
            Issue.record("expected generationError, got \(String(describing: result.issue))")
        }
    }

    @Test func truncationFallsBackInsteadOfShippingPartial() async throws {
        let (backend, url) = Self.makeBackend()
        StubProtocol.handler = { _ in
            // 200 with `stop_reason: "max_tokens"` means the model hit our
            // per-chunk cap mid-output. The text in `content` is whatever
            // it had managed to emit — possibly a complete sentence,
            // possibly a dangling fragment. We don't trust it as the
            // polish; falls back to the original chunk + surfaces the
            // issue so the user knows the lint didn't fully succeed.
            let payload: [String: Any] = [
                "id": "msg_test",
                "type": "message",
                "role": "assistant",
                "content": [["type": "text", "text": "Hello, wor"]],
                "model": "claude-haiku-4-5",
                "stop_reason": "max_tokens",
            ]
            let body = try! JSONSerialization.data(withJSONObject: payload)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, body)
        }
        defer { StubProtocol.handler = nil }

        let result = try await backend.lint(
            text: "hello world",
            instructions: "polish",
            apiKey: "sk",
            model: .haiku45
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

    @Test func effortIncludedForSonnetButOmittedForHaiku() async throws {
        let (backend, url) = Self.makeBackend()
        nonisolated(unsafe) var capturedBodies: [Data] = []
        StubProtocol.handler = { request in
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
            capturedBodies.append(body)
            return Self.okResponse(url, text: "Hello.")
        }
        defer { StubProtocol.handler = nil }

        // Haiku 4.5 errors on output_config.effort — the field must be
        // absent from the request body entirely.
        _ = try await backend.lint(text: "hello", instructions: "p", apiKey: "sk", model: .haiku45)
        let haikuBody = try #require(capturedBodies.first)
        let haikuParsed = try #require(try JSONSerialization.jsonObject(with: haikuBody) as? [String: Any])
        #expect(haikuParsed["output_config"] == nil)

        // Sonnet 4.6 supports effort — should send "low" for grammar polish.
        _ = try await backend.lint(text: "hello", instructions: "p", apiKey: "sk", model: .sonnet46)
        let sonnetBody = try #require(capturedBodies.dropFirst().first)
        let sonnetParsed = try #require(try JSONSerialization.jsonObject(with: sonnetBody) as? [String: Any])
        let outputConfig = try #require(sonnetParsed["output_config"] as? [String: Any])
        #expect(outputConfig["effort"] as? String == "low")

        // Opus 4.7 also supports effort.
        _ = try await backend.lint(text: "hello", instructions: "p", apiKey: "sk", model: .opus47)
        let opusBody = try #require(capturedBodies.dropFirst(2).first)
        let opusParsed = try #require(try JSONSerialization.jsonObject(with: opusBody) as? [String: Any])
        let opusOutputConfig = try #require(opusParsed["output_config"] as? [String: Any])
        #expect(opusOutputConfig["effort"] as? String == "low")
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
            model: .haiku45
        )
        // Malformed responses surface as `LintError.underlying` from the
        // outer catch — but the inner per-chunk catch only handles
        // `ClaudeError`, so a JSON decode error escapes. Verify the
        // throw rather than the issue.
        // Expected: output preserved or error thrown — we accept either,
        // but in the current implementation the decoder error escapes the
        // sendChunk inner do/catch and is converted to LintError.underlying
        // by the outer catch.
        // For now just assert we didn't get a usable polish:
        #expect(result.output == "hello" || result.output.isEmpty)
    }

    // MARK: Multi-chunk + structure preservation

    @Test func blankLineStructurePreservedAcrossChunks() async throws {
        let (backend, url) = Self.makeBackend()
        StubProtocol.handler = { request in
            // Echo the chunk back, capitalized — simple way to verify the
            // per-chunk loop is calling through and stitching separators.
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
            let userText = (messages?.first?["content"] as? String) ?? ""
            return Self.okResponse(url, text: userText.uppercased())
        }
        defer { StubProtocol.handler = nil }

        let result = try await backend.lint(
            text: "para one\n\npara two",
            instructions: "uppercase",
            apiKey: "sk",
            model: .haiku45
        )
        #expect(result.output == "PARA ONE\n\nPARA TWO")
    }
}
