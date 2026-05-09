#if CloudSaaS
import Testing
import Foundation
@testable import ManifoldBackends
@testable import ManifoldCloudCore
@testable import ManifoldInference
import ManifoldTestSupport

/// Tests for ``CloudErrorSanitizer``. These are the core guarantees — HTML
/// rejection, length cap, control-char stripping, JWT/URL redaction, and
/// idempotence — that keep upstream error bodies from injecting content,
/// leaking tokens, or wedging error banners.
@Suite("CloudErrorSanitizer")
struct CloudErrorSanitizerTests {

    // MARK: - HTML rejection

    @Test func htmlBody_replacedWithGenericError() {
        let html = "<html><body>Bad gateway</body></html>"
        let out = CloudErrorSanitizer.sanitize(html, host: "api.example.com")
        #expect(out == "Server error from api.example.com")
    }

    @Test func htmlBody_withoutHost_usesBareGenericError() {
        let html = "<h1>502 Bad Gateway</h1>"
        let out = CloudErrorSanitizer.sanitize(html, host: nil)
        #expect(out == "Server error")
    }

    @Test func angleBracketInProse_isNotTreatedAsHTML() {
        // `<` followed by space/digit is not a tag opener and should pass.
        let msg = "value < 100 exceeded threshold"
        let out = CloudErrorSanitizer.sanitize(msg, host: "api.example.com")
        #expect(out == msg)
    }

    // Directly exercises the pairwise scan's empty and single-character
    // boundary. `sanitize(_:host:)` early-returns on empty input today, but
    // the scan expresses its upper bound as `scalars.count - 1` and would
    // crash with `0..<-1` if a future reorder let empty input reach it.
    @Test func test_containsHTMLTag_empty_returnsFalse() {
        #expect(CloudErrorSanitizer.containsHTMLTag("") == false)
    }

    @Test func test_containsHTMLTag_singleChar_returnsFalse() {
        // A bare `<` cannot be a tag opener — there is no next scalar to be
        // an ASCII letter.
        #expect(CloudErrorSanitizer.containsHTMLTag("<") == false)
    }

    // MARK: - Length cap

    @Test func longMessage_isTruncatedTo256WithEllipsis() {
        // Wrap the raw string in a fake JSON error body and feed only the
        // message; the sanitiser is the unit under test.
        let long = String(repeating: "a", count: 5000)
        let out = CloudErrorSanitizer.sanitize(long, host: "api.example.com")
        #expect(out.count == 256)
        #expect(out.hasSuffix("\u{2026}"))
    }

    @Test func shortMessage_passesThroughUnchanged() {
        let msg = "Service unavailable"
        let out = CloudErrorSanitizer.sanitize(msg, host: "api.example.com")
        #expect(out == "Service unavailable")
    }

    // MARK: - Control character stripping

    @Test func zeroWidthAndBidiControls_areStripped() {
        // U+200B zero-width space, U+202E RTL override, U+200D ZWJ, BEL 0x07,
        // plus newlines collapsed to a single space.
        let raw = "rate\u{200B}-limit\u{202E}ed\n\nrequest\u{200D}\u{0007}"
        let out = CloudErrorSanitizer.sanitize(raw, host: "api.example.com")
        // Zero-width chars vanish; newline run collapses to single space;
        // letters/hyphen preserved.
        #expect(out == "rate-limited request")
    }

    @Test func multipleWhitespace_collapsesToSingleSpace() {
        let raw = "rate    limited\t\n exceeded"
        let out = CloudErrorSanitizer.sanitize(raw, host: nil)
        #expect(out == "rate limited exceeded")
    }

    // MARK: - JWT redaction

    @Test func jwtShapedMessage_isReplacedWithGenericError() {
        let jwt = "Upstream leaked token: eyJhbGciOiJIUzI1NiJ9.abc.def"
        let out = CloudErrorSanitizer.sanitize(jwt, host: "api.example.com")
        #expect(out == "Server error from api.example.com")
    }

    // MARK: - URL redaction

    @Test func urlInMessage_isReplacedWithGenericError() {
        let msg = "callback failed: http://internal.corp.example/webhook"
        let out = CloudErrorSanitizer.sanitize(msg, host: "api.example.com")
        #expect(out == "Server error from api.example.com")
    }

    @Test func httpsURL_alsoRedacted() {
        let msg = "see https://status.example.com for details"
        let out = CloudErrorSanitizer.sanitize(msg, host: "api.example.com")
        #expect(out == "Server error from api.example.com")
    }

    // MARK: - Nil / empty input

    @Test func nilInput_returnsGenericError() {
        let out = CloudErrorSanitizer.sanitize(nil, host: "api.example.com")
        #expect(out == "Server error from api.example.com")
    }

    @Test func emptyInput_returnsGenericError() {
        let out = CloudErrorSanitizer.sanitize("", host: nil)
        #expect(out == "Server error")
    }

    @Test func allControlChars_returnsGenericError() {
        // After stripping there's nothing left — fall back to generic.
        let raw = "\u{200B}\u{200D}\u{202E}\u{FEFF}"
        let out = CloudErrorSanitizer.sanitize(raw, host: "api.example.com")
        #expect(out == "Server error from api.example.com")
    }

    // MARK: - Idempotence

    @Test func sanitize_isIdempotent() {
        // Running the sanitiser on its own output must produce the same result —
        // this guarantees no double-mutation surprises if the error flows
        // through multiple layers.
        let inputs = [
            "Service unavailable",
            "rate\u{200B}-limit\u{202E}ed",
            String(repeating: "x", count: 1000),
            "<html>bad</html>",
            "tokenish eyJhbGci.abc.def",
            "callback at https://x.test",
            "",
        ]
        for raw in inputs {
            let first = CloudErrorSanitizer.sanitize(raw, host: "api.example.com")
            let second = CloudErrorSanitizer.sanitize(first, host: "api.example.com")
            #expect(first == second, "Sanitiser must be idempotent for input: \(raw.debugDescription)")
        }
    }

    // MARK: - Unicode letters preserved (non-English prose)

    @Test func nonAsciiPunctuationAndLetters_arePreserved() {
        let raw = "Erreur du serveur — réessayez plus tard."
        let out = CloudErrorSanitizer.sanitize(raw, host: nil)
        #expect(out == raw)
    }
}

// MARK: - End-to-end via OpenAI-compatible SSE path

/// Integration-level assertions that the sanitiser is wired into
/// ``SSECloudBackend.checkStatusCode`` so every subclass that relies on the
/// base-class error path automatically benefits.
@Suite("CloudErrorSanitizer E2E (SSECloudBackend)", .serialized)
struct CloudErrorSanitizerE2ETests {

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeBackend() -> (OpenAIBackend, URL, String) {
        let session = makeMockSession()
        let backend = OpenAIBackend(urlSession: session)
        // Disable retries — 5xx is retryable and would balloon test time.
        backend.retryStrategy = ExponentialBackoffStrategy(maxRetries: 0)
        let host = "sanitizer-\(UUID().uuidString).test"
        let baseURL = URL(string: "https://\(host)")!
        backend.configure(baseURL: baseURL, apiKey: "sk-test", modelName: "gpt-4o-mini")
        return (backend, baseURL.appendingPathComponent("v1/chat/completions"), host)
    }

    private func loadBackend(_ backend: OpenAIBackend) async throws {
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
    }

    @Test func htmlErrorBody_surfacedAsGenericServerError() async throws {
        let (backend, url, host) = makeBackend()
        defer { MockURLProtocol.unstub(url: url) }

        // Upstream proxy echoed HTML inside an OpenAI-shaped error envelope.
        // The sanitiser must reject the HTML-shaped message even though
        // `extractErrorMessage` successfully parsed it.
        let body = Data(#"{"error":{"message":"<html><body>502 Bad Gateway</body></html>"}}"#.utf8)
        MockURLProtocol.stub(url: url, response: .immediate(data: body, statusCode: 502))

        try await loadBackend(backend)

        do {
            let stream = try backend.generate(prompt: "Hi", systemPrompt: nil, config: GenerationConfig())
            for try await _ in stream.events {}
            Issue.record("Expected server error")
        } catch {
            guard let cloud = extractCloudError(error) else {
                Issue.record("Expected CloudBackendError, got \(error)")
                return
            }
            guard case .serverError(let code, let message) = cloud else {
                Issue.record("Expected serverError, got \(cloud)")
                return
            }
            #expect(code == 502)
            #expect(message == "Server error from \(host)")
        }
    }

    @Test func longErrorBody_cappedAt256Chars() async throws {
        let (backend, url, _) = makeBackend()
        defer { MockURLProtocol.unstub(url: url) }

        // `checkStatusCode` reads up to 2048 bytes of the upstream body, so
        // fit the entire JSON envelope (plus the long message) inside that
        // budget. The sanitiser should still cap the extracted payload at
        // `maxLength` with an ellipsis.
        let huge = String(repeating: "x", count: 1800)
        let body = Data(#"{"error":{"message":"\#(huge)"}}"#.utf8)
        MockURLProtocol.stub(url: url, response: .immediate(data: body, statusCode: 500))

        try await loadBackend(backend)

        do {
            let stream = try backend.generate(prompt: "Hi", systemPrompt: nil, config: GenerationConfig())
            for try await _ in stream.events {}
            Issue.record("Expected server error")
        } catch {
            guard let cloud = extractCloudError(error) else {
                Issue.record("Expected CloudBackendError, got \(error)")
                return
            }
            guard case .serverError(_, let message) = cloud else {
                Issue.record("Expected serverError, got \(cloud)")
                return
            }
            #expect(message.count <= CloudErrorSanitizer.maxLength)
            #expect(message.hasSuffix("\u{2026}"))
        }
    }

    @Test func plainErrorMessage_passesThroughUnchanged() async throws {
        let (backend, url, _) = makeBackend()
        defer { MockURLProtocol.unstub(url: url) }

        let body = Data(#"{"error":{"message":"Service unavailable"}}"#.utf8)
        MockURLProtocol.stub(url: url, response: .immediate(data: body, statusCode: 503))

        try await loadBackend(backend)

        do {
            let stream = try backend.generate(prompt: "Hi", systemPrompt: nil, config: GenerationConfig())
            for try await _ in stream.events {}
            Issue.record("Expected server error")
        } catch {
            guard let cloud = extractCloudError(error) else {
                Issue.record("Expected CloudBackendError, got \(error)")
                return
            }
            guard case .serverError(let code, let message) = cloud else {
                Issue.record("Expected serverError, got \(cloud)")
                return
            }
            #expect(code == 503)
            #expect(message == "Service unavailable")
        }
    }

    @Test func jwtShapedMessage_redacted() async throws {
        let (backend, url, host) = makeBackend()
        defer { MockURLProtocol.unstub(url: url) }

        let body = Data(#"{"error":{"message":"token leaked eyJhbGciOiJIUzI1NiJ9.payload.sig"}}"#.utf8)
        MockURLProtocol.stub(url: url, response: .immediate(data: body, statusCode: 500))

        try await loadBackend(backend)

        do {
            let stream = try backend.generate(prompt: "Hi", systemPrompt: nil, config: GenerationConfig())
            for try await _ in stream.events {}
            Issue.record("Expected server error")
        } catch {
            guard let cloud = extractCloudError(error) else {
                Issue.record("Expected CloudBackendError, got \(error)")
                return
            }
            guard case .serverError(_, let message) = cloud else {
                Issue.record("Expected serverError, got \(cloud)")
                return
            }
            #expect(!message.contains("eyJ"))
            #expect(message == "Server error from \(host)")
        }
    }
}
#endif
