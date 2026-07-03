import Testing
import XCTest
import Foundation
@testable import ManifoldFoundation
// v0.48 product split: internal symbols moved into the family targets and
// ManifoldCloudCore; the ManifoldCloud shim only re-exports public surface.
@testable import ManifoldOllama
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport

// MARK: - Helpers

/// Creates a `URLSession` whose traffic is intercepted by `MockURLProtocol`.
private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

/// Formats a single Ollama NDJSON line.
private func ndjsonLine(_ json: String) -> Data {
    Data("\(json)\n".utf8)
}

/// Thread-safe recorder of distinct, consecutive `GenerationStream.Phase`
/// values sampled from a concurrent task. Collapses repeats so the recorded
/// sequence is the ordered set of phase transitions the stream passed through.
private final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _phases: [GenerationStream.Phase] = []

    func record(_ phase: GenerationStream.Phase) {
        lock.lock(); defer { lock.unlock() }
        if _phases.last != phase { _phases.append(phase) }
    }

    var phases: [GenerationStream.Phase] {
        lock.lock(); defer { lock.unlock() }
        return _phases
    }
}

// MARK: - OllamaBackend Tests

@Suite("OllamaBackend", .serialized)
struct OllamaBackendTests {

    init() {
        // UUID-based test hostnames don't resolve; return a public IP so
        // DNSRebindingGuard passes for mock endpoints.
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
    }

    // MARK: - Setup helpers

    private func makeConfiguredBackend() -> (OllamaBackend, URL) {
        let session = makeMockSession()
        let backend = OllamaBackend(urlSession: session)
        let baseURL = URL(string: "http://ollama-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, modelName: "llama3.2")
        return (backend, baseURL.appendingPathComponent("api/chat"))
    }

    /// Returns both the `/api/chat` URL and the matching `/api/show` URL for
    /// tests that want to stub the thinking-capability probe explicitly.
    private func makeConfiguredBackendWithShow() -> (OllamaBackend, chatURL: URL, showURL: URL) {
        let session = makeMockSession()
        let backend = OllamaBackend(urlSession: session)
        let baseURL = URL(string: "http://ollama-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, modelName: "llama3.2")
        return (
            backend,
            chatURL: baseURL.appendingPathComponent("api/chat"),
            showURL: baseURL.appendingPathComponent("api/show")
        )
    }

    private func loadBackend(_ backend: OllamaBackend) async throws {
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
    }

    /// Builds a minimal `/api/show` JSON response body with an explicit
    /// `capabilities` array (and optional `template` for the fallback-path test).
    private func apiShowBody(capabilities: [String], template: String? = nil) -> Data {
        var obj: [String: Any] = ["capabilities": capabilities]
        if let template { obj["template"] = template }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    // MARK: - Init & State

    @Test func init_defaultState() {
        let backend = OllamaBackend()
        #expect(!backend.isModelLoaded)
        #expect(!backend.isGenerating)
    }

    @Test func loadModel_withoutConfigure_throws() async {
        let backend = OllamaBackend()
        do {
            try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
            Issue.record("Expected throw when no base URL configured")
        } catch {
            // expected
        }
    }

    @Test func configure_thenLoad_succeeds() async throws {
        let (backend, _) = makeConfiguredBackend()
        try await loadBackend(backend)
        #expect(backend.isModelLoaded)
    }

    @Test func unloadModel_clearsState() async throws {
        let (backend, _) = makeConfiguredBackend()
        try await loadBackend(backend)
        backend.unloadModel()
        #expect(!backend.isModelLoaded)
        #expect(!backend.isGenerating)
    }

    @Test func generate_withoutLoad_throws() {
        let backend = OllamaBackend()
        #expect(throws: (any Error).self) {
            try backend.generate(prompt: "hello", systemPrompt: nil, config: .init())
        }
    }

    // MARK: - Capabilities

    @Test func capabilities_supportsExpectedParameters() {
        let caps = OllamaBackend().capabilities
        #expect(caps.supportedParameters.contains(.temperature))
        #expect(caps.supportedParameters.contains(.topP))
        #expect(caps.supportedParameters.contains(.topK))
        #expect(caps.supportedParameters.contains(.repeatPenalty))
        // Additive penalties + min_p added in the per-generation knobs PR.
        #expect(caps.supportedParameters.contains(.minP))
        #expect(caps.supportedParameters.contains(.presencePenalty))
        #expect(caps.supportedParameters.contains(.frequencyPenalty))
    }

    /// New per-generation knobs (`min_p`, `presence_penalty`, `frequency_penalty`,
    /// `repeat_last_n`) flow into Ollama's `options` dict only when the caller set
    /// them. Omitting preserves whatever Ollama's server-side default is and keeps
    /// wire payloads identical for callers that haven't migrated.
    ///
    /// Sabotage check: drop one of the `if let … = config.X` guards in
    /// `OllamaBackend.swift` and the corresponding assertion below will fail.
    @Test func generate_includesAdditivePenaltyOptionsWhenSet() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"ok"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        var config = GenerationConfig()
        // Values chosen for clean Float→JSON→Double roundtripping (binary-fraction friendly).
        config.minP = 0.0625
        config.presencePenalty = 0.5
        config.frequencyPenalty = 0.25
        config.repetitionContextSize = 96

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: config)
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: {
            $0.url?.absoluteString.contains("api/chat") == true
        })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let options = try #require(json["options"] as? [String: Any])

        #expect((options["min_p"] as? Double) == 0.0625)
        #expect((options["presence_penalty"] as? Double) == 0.5)
        #expect((options["frequency_penalty"] as? Double) == 0.25)
        #expect((options["repeat_last_n"] as? Int) == 96)
    }

    /// Mirror of the previous test confirming default omission. The wire payload
    /// for callers that didn't set the new fields must not carry them, so on-disk
    /// preset compactness and Ollama Modelfile defaults stay untouched.
    @Test func generate_omitsAdditivePenaltyOptionsWhenNil() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"ok"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: {
            $0.url?.absoluteString.contains("api/chat") == true
        })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let options = try #require(json["options"] as? [String: Any])

        #expect(options["min_p"] == nil)
        #expect(options["presence_penalty"] == nil)
        #expect(options["frequency_penalty"] == nil)
        #expect(options["repeat_last_n"] == nil)
    }

    @Test func capabilities_supportsSystemPrompt() {
        #expect(OllamaBackend().capabilities.supportsSystemPrompt)
    }

    @Test func capabilities_noPromptTemplate() {
        #expect(!OllamaBackend().capabilities.requiresPromptTemplate)
    }

    @Test func capabilities_supportsNativeJSONMode() {
        #expect(OllamaBackend().capabilities.supportsNativeJSONMode)
    }

    @Test func buildRequest_jsonModeEnabled_addsFormat() throws {
        let (backend, _) = makeConfiguredBackend()
        let request = try backend.buildRequest(
            prompt: "hello",
            systemPrompt: nil,
            config: GenerationConfig(jsonMode: true)
        )

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["format"] as? String == "json")
    }

    @Test func buildRequest_jsonModeDisabled_omitsFormat() throws {
        let (backend, _) = makeConfiguredBackend()
        let request = try backend.buildRequest(
            prompt: "hello",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["format"] == nil)
    }

    // MARK: - Stop sequences (#1944)

    @Test func buildRequest_stopSequencesSet_addsOptionsStop() throws {
        let (backend, _) = makeConfiguredBackend()
        let request = try backend.buildRequest(
            prompt: "hello",
            systemPrompt: nil,
            config: GenerationConfig(stopSequences: ["</s>", "User:"])
        )

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let options = try #require(json["options"] as? [String: Any])
        #expect((options["stop"] as? [String]) == ["</s>", "User:"])
    }

    @Test func buildRequest_stopSequencesEmpty_omitsOptionsStop() throws {
        let (backend, _) = makeConfiguredBackend()
        let request = try backend.buildRequest(
            prompt: "hello",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let options = try #require(json["options"] as? [String: Any])
        #expect(options["stop"] == nil)
    }

    // MARK: - Streaming

    @Test func streaming_yieldsTokens() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"Hello"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":" world"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"!"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "Say hello", systemPrompt: nil, config: .init())
        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let text) = event {
                tokens.append(text)
            }
        }

        #expect(tokens == ["Hello", " world", "!"])
    }

    @Test func streaming_withSystemPrompt_includesInMessages() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"ok"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: "You are a test bot.", config: .init())
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: {
            $0.url?.absoluteString.contains("api/chat") == true
        })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.first?["role"] == "system")
        #expect(messages.first?["content"] == "You are a test bot.")
    }

    /// Ollama's final NDJSON chunk can carry several `done_reason` values —
    /// `stop` (normal termination), `length` (hit `num_predict`), `load` /
    /// `unload` (server-side model swap). None of these should produce an
    /// extra `.token` event because their `message.content` is empty. This
    /// fixture pins the current behaviour so future wiring of `done_reason`
    /// into `GenerationStream.phase` has a green baseline to diff against.
    /// Closes #507.
    @Test func streaming_doneReasonVariants_notYielded() async throws {
        let variants = ["length", "load", "unload"]
        for reason in variants {
            let (backend, chatURL) = makeConfiguredBackend()
            try await loadBackend(backend)

            let chunks: [Data] = [
                ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true,"done_reason":"\#(reason)","total_duration":42000000,"eval_count":128}"#),
            ]
            MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
            defer { MockURLProtocol.unstub(url: chatURL) }

            let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
            var tokens: [String] = []
            for try await event in stream.events {
                if case .token(let t) = event { tokens.append(t) }
            }
            #expect(tokens.isEmpty, "done_reason=\(reason) should produce no .token events (got \(tokens))")
        }
    }

    @Test func streaming_doneChunk_notYielded() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        // "done":true chunk should produce no token.
        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"Hi"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","total_duration":1234}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
        var tokens: [String] = []
        for try await event in stream.events { if case .token(let text) = event { tokens.append(text) } }

        #expect(tokens == ["Hi"])
    }

    // MARK: - Chunk Boundary

    /// Under real network conditions, `URLSession.AsyncBytes` will deliver a
    /// JSON object split across TCP reads — a partial payload followed by the
    /// rest on the next chunk, with the newline landing on the second read.
    /// Every other streaming test delivers one complete JSON object per chunk,
    /// so the byte-buffer path is otherwise untested for splits. A refactor
    /// that swaps the per-byte reader for a chunked reader must still assemble
    /// pre-newline bytes with post-newline bytes before JSON parse.
    /// Closes #509.
    @Test func streaming_midLineSplit_reassembles() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        // Split a single JSON object across two chunks. The newline arrives
        // on the second chunk so the parser must join the two buffers.
        let chunks: [Data] = [
            Data(#"{"model":"llama3.2","message":{"role":"assistant","content":"Hel"#.utf8),
            Data(#"lo"},"done":false}"#.utf8) + Data("\n".utf8),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let t) = event { tokens.append(t) }
        }

        #expect(tokens == ["Hello"], "mid-line split must be reassembled before JSON parse")
    }

    // MARK: - Loading Phase (#189)

    /// The Ollama backend opts into the load-stall phase contract: a stalled
    /// connection (open `200 OK`, no token yet) must read `.loading`, not
    /// `.streaming`. This pins the opt-in flag so a regression that drops the
    /// override is caught even if the runner-level integration test below is
    /// timing-sensitive. Closes #189.
    @Test func backend_signalsLoadingUntilFirstToken_isEnabled() {
        let backend = OllamaBackend()
        #expect(backend.signalsLoadingUntilFirstToken)
    }

    /// Ollama can hold an open `200 OK` connection for minutes while it loads
    /// the model into VRAM and prefills the prompt — no token has arrived yet.
    /// During that pre-first-token window the `GenerationStream.phase` must read
    /// `.loading`, not `.streaming`; it transitions to `.streaming` only when
    /// the first event is yielded, then `.done` at completion. Closes #189.
    @Test func streaming_phaseIsLoadingBeforeFirstToken_thenStreaming() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        // `asyncSSE` delivers chunks on a background thread with `chunkDelay`
        // BEFORE each chunk — including the first. That first-chunk delay is the
        // Ollama model-load stall (connection open, no byte yet). Spacing the
        // chunks keeps the stream in `.streaming` long enough to observe before
        // it finishes. A separate content chunk precedes the done chunk so the
        // stream is still live when the first token is observed.
        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"Hi"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(
            url: chatURL,
            response: .asyncSSE(chunks: chunks, chunkDelay: 0.12, statusCode: 200)
        )
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())

        // Sample the observable phase continuously on a concurrent task and
        // record every distinct value, in order, until the stream finishes.
        // This captures the `.loading → .streaming → .done` progression without
        // racing a single point-in-time read against the producer.
        let recorder = PhaseRecorder()
        let sampler = Task {
            while !Task.isCancelled {
                let phase = await MainActor.run { stream.phase }
                recorder.record(phase)
                if phase == .done || phase == .failed("") { break }
                try? await Task.sleep(for: .milliseconds(3))
            }
        }

        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let t) = event { tokens.append(t) }
        }
        // Await the sampler to completion rather than racing a fixed sleep.
        // The runner sets `.done` before `continuation.finish()`, so by the time
        // the events loop above has drained the phase is already terminal; the
        // sampler self-terminates on observing `.done`/`.failed` (see its loop),
        // so `await` here deterministically captures the terminal phase instead
        // of depending on a 20ms window that the serial-suite scheduler can miss
        // under load (flake surfaced on main, not on the isolated-PR run).
        _ = await sampler.value

        let phases = recorder.phases
        #expect(tokens == ["Hi"])
        #expect(phases.contains(.loading), "phase must be .loading during the pre-first-token stall (saw \(phases))")
        #expect(phases.contains(.streaming), "phase must reach .streaming once tokens arrive (saw \(phases))")
        #expect(phases.last == .done, "phase must end at .done (saw \(phases))")

        // Ordering: .loading must appear before .streaming.
        if let loadingIdx = phases.firstIndex(of: .loading),
           let streamingIdx = phases.firstIndex(of: .streaming) {
            #expect(loadingIdx < streamingIdx, "phase must be .loading before .streaming (saw \(phases))")
        }
    }

    @Test func streaming_malformedLine_skipped() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine("not valid json"),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"OK"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hello", systemPrompt: nil, config: .init())
        var tokens: [String] = []
        for try await event in stream.events { if case .token(let text) = event { tokens.append(text) } }

        #expect(tokens == ["OK"])
    }

    // MARK: - Error Responses

    @Test func serverError_404_modelNotFound() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let body = Data(#"{"error":"model not found"}"#.utf8)
        MockURLProtocol.stub(url: chatURL, response: .immediate(data: body, statusCode: 404))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hello", systemPrompt: nil, config: .init())
        do {
            for try await _ in stream.events {}
            Issue.record("Expected server error")
        } catch {
            guard let error = extractCloudError(error) else { Issue.record("Expected CloudBackendError, got \(error)"); return }
            switch error {
            case .serverError(let code, _): #expect(code == 404)
            default: Issue.record("Expected serverError, got \(error)")
            }
        }
    }

    @Test func serverError_500_throws() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        MockURLProtocol.stub(url: chatURL, response: .immediate(data: Data(), statusCode: 500))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hello", systemPrompt: nil, config: .init())
        do {
            for try await _ in stream.events {}
            Issue.record("Expected server error")
        } catch {
            guard let error = extractCloudError(error) else { Issue.record("Expected CloudBackendError, got \(error)"); return }
            switch error {
            case .serverError(let code, _): #expect(code == 500)
            default: Issue.record("Expected serverError, got \(error)")
            }
        }
    }

    /// A non-ASCII (multi-byte UTF-8) upstream error message must survive the
    /// shared `SSECloudBackend.drainAndSanitizeErrorBody` read intact and reach
    /// the surfaced `serverError` message.
    ///
    /// Regression for the base class's per-byte `Character(UnicodeScalar(byte))`
    /// read, which decoded each UTF-8 byte as an independent Latin-1 scalar and
    /// turned any multi-byte sequence into mojibake before sanitization ever saw
    /// it. Ollama routes through the same shared helper, so this also guards the
    /// consolidation.
    ///
    /// Sabotage check: revert `drainAndSanitizeErrorBody` to per-byte
    /// `errorBody.append(Character(UnicodeScalar(byte)))`. The é/中文/🚫 glyphs
    /// come back as mojibake and the substring assertions fail.
    @Test func serverError_nonASCIIBody_roundTripsAsUTF8() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        // Mix 2-byte (é), 3-byte (中文), and 4-byte (🚫) UTF-8 sequences.
        let upstreamMessage = "Réseau indisponible 中文 🚫"
        let body = try JSONSerialization.data(withJSONObject: ["error": upstreamMessage])
        MockURLProtocol.stub(url: chatURL, response: .immediate(data: body, statusCode: 500))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hello", systemPrompt: nil, config: .init())
        do {
            for try await _ in stream.events {}
            Issue.record("Expected server error")
        } catch {
            guard let error = extractCloudError(error) else { Issue.record("Expected CloudBackendError, got \(error)"); return }
            guard case .serverError(let code, let message) = error else {
                Issue.record("Expected serverError, got \(error)"); return
            }
            #expect(code == 500)
            let surfaced = try #require(message, "serverError must carry the upstream message")
            #expect(surfaced.contains("Réseau"), "2-byte UTF-8 (é) must survive; got: \(surfaced)")
            #expect(surfaced.contains("中文"), "3-byte UTF-8 must survive; got: \(surfaced)")
            #expect(surfaced.contains("🚫"), "4-byte UTF-8 must survive; got: \(surfaced)")
        }
    }

    @Test func rateLimitError_429() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        MockURLProtocol.stub(url: chatURL, response: .immediate(
            data: Data(),
            statusCode: 429,
            headers: ["Retry-After": "0"]
        ))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hello", systemPrompt: nil, config: .init())
        do {
            for try await _ in stream.events {}
            Issue.record("Expected rateLimited error")
        } catch {
            guard let error = extractCloudError(error) else { Issue.record("Expected CloudBackendError, got \(error)"); return }
            switch error {
            case .rateLimited: break
            default: Issue.record("Expected rateLimited, got \(error)")
            }
        }
    }

    /// `OllamaBackend.checkStatusCode` parses `Retry-After` via
    /// `TimeInterval(init)`, which accepts integer seconds but silently fails
    /// on the RFC 7231 HTTP-date form (`Wed, 21 Oct 2026 07:28:00 GMT`). Pin
    /// both: integer parses to a retry hint, HTTP-date currently becomes `nil`
    /// so retry policy loses the hint. Once a date parser lands, flip the
    /// HTTP-date assertion.
    ///
    /// We set `maxRetries: 0` on both sub-cases so the integer-seconds variant
    /// doesn't actually sleep 30s waiting to retry.
    /// Closes #512.
    @Test func rateLimitError_429_retryAfterVariants() async throws {
        // Integer seconds — parses as expected.
        do {
            let (backend, chatURL) = makeConfiguredBackend()
            backend.retryStrategy = ExponentialBackoffStrategy(maxRetries: 0)
            try await loadBackend(backend)

            MockURLProtocol.stub(url: chatURL, response: .immediate(
                data: Data(),
                statusCode: 429,
                headers: ["Retry-After": "30"]
            ))
            defer { MockURLProtocol.unstub(url: chatURL) }

            let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
            do {
                for try await _ in stream.events {}
                Issue.record("Expected rateLimited error for integer Retry-After")
            } catch {
                guard let error = extractCloudError(error) else {
                    Issue.record("Expected CloudBackendError, got \(error)")
                    return
                }
                switch error {
                case .rateLimited(let retryAfter):
                    #expect(retryAfter == 30, "integer Retry-After must parse to 30s (got \(String(describing: retryAfter)))")
                default:
                    Issue.record("Expected rateLimited, got \(error)")
                }
            }
        }

        // HTTP-date form — currently unsupported by TimeInterval(init).
        // Documented behaviour: retryAfter is nil. Flip when a date parser exists.
        do {
            let (backend, chatURL) = makeConfiguredBackend()
            backend.retryStrategy = ExponentialBackoffStrategy(maxRetries: 0)
            try await loadBackend(backend)

            MockURLProtocol.stub(url: chatURL, response: .immediate(
                data: Data(),
                statusCode: 429,
                headers: ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"]
            ))
            defer { MockURLProtocol.unstub(url: chatURL) }

            let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
            do {
                for try await _ in stream.events {}
                Issue.record("Expected rateLimited error for HTTP-date Retry-After")
            } catch {
                guard let error = extractCloudError(error) else {
                    Issue.record("Expected CloudBackendError, got \(error)")
                    return
                }
                switch error {
                case .rateLimited(let retryAfter):
                    // Current behaviour: HTTP-date parse falls through to nil.
                    #expect(retryAfter == nil, "HTTP-date Retry-After is currently unparsed (hint lost)")
                default:
                    Issue.record("Expected rateLimited, got \(error)")
                }
            }
        }
    }

    // MARK: - Usage Stats

    /// Ollama's final chunk carries per-call usage — `prompt_eval_count`
    /// (prompt tokens) and `eval_count` (completion tokens). The
    /// ``CloudPayloadHandler/ollama`` `extractUsage` hook surfaces both so
    /// `TokenUsageProvider` consumers see exact counts. Closes #508.
    ///
    /// Sabotage check (verified locally): reverting `extractUsage` to return
    /// `nil` fails both assertions.
    @Test func payloadHandler_extractUsage_parsesDoneLineCounts() {
        let handler: CloudPayloadHandler = .ollama
        let json = #"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","prompt_eval_count":42,"eval_count":17,"eval_duration":1500000000,"total_duration":2200000000}"#
        let usage = try? #require(handler.extractUsage(from: json))
        #expect(usage?.promptTokens == 42)
        #expect(usage?.completionTokens == 17)
    }

    /// Lines without either usage field must return nil so the
    /// `SSECloudBackend.handleUsage` merge logic isn't called with an empty
    /// tuple (which would overwrite a prior prompt count with 0 on Claude's
    /// split-usage path). Pins the "missing fields → nil" contract.
    @Test func payloadHandler_extractUsage_nonUsageLine_returnsNil() {
        let handler: CloudPayloadHandler = .ollama
        let midLine = #"{"model":"llama3.2","message":{"role":"assistant","content":"hi"},"done":false}"#
        #expect(handler.extractUsage(from: midLine) == nil)

        // Malformed JSON also returns nil (parseLine returns nil).
        #expect(handler.extractUsage(from: "not json") == nil)
    }

    /// End-to-end: the done-line's `eval_count` / `prompt_eval_count` must
    /// surface both as a `.usage(TokenUsage)` event on the stream and
    /// as `lastUsage` on the backend — mirroring `SSECloudBackend`'s SSE path.
    /// This is what actually reaches the UI.
    ///
    /// Sabotage check (verified locally): removing the `handleUsage` /
    /// `.usage` yield block from `parseResponseStream` on the done branch
    /// makes both assertions fail (no `.usage` event, `lastUsage` stays nil).
    @Test func streaming_doneLine_emitsUsageEventAndSetsLastUsage() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"hi"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","prompt_eval_count":42,"eval_count":17}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
        var usageEvents: [(prompt: Int, completion: Int)] = []
        for try await event in stream.events {
            if case .usage(let u) = event {
                usageEvents.append((prompt: u.promptTokens, completion: u.completionTokens))
            }
        }

        #expect(usageEvents.count == 1)
        #expect(usageEvents.first?.prompt == 42)
        #expect(usageEvents.first?.completion == 17)
        #expect(backend.lastUsage?.promptTokens == 42)
        #expect(backend.lastUsage?.completionTokens == 17)
    }

    // MARK: - /api/generate Endpoint Shape

    /// `/api/generate` (non-chat) uses top-level `response` instead of
    /// `message.content`. Older Ollama clients and third-party proxies still
    /// speak it. Today's `parseLine` normalises both shapes, so `extractToken`
    /// DOES surface `response`. This differs from the original issue #510
    /// premise (which assumed `response` was dropped) — the backend gained
    /// `/api/generate` support alongside #487 thinking-field handling. Pin
    /// the current normalised behaviour so any regression that re-breaks
    /// /api/generate is caught.
    /// Closes #510.
    @Test func extractToken_generateEndpointShape_surfacesResponse() {
        // Streaming intermediate chunks — `response` surfaces as a token.
        let midLine = #"{"model":"llama3.2","response":"Hello","done":false}"#
        #expect(OllamaPayloadParser.extractToken(from: midLine) == "Hello")

        let midLine2 = #"{"model":"llama3.2","response":" world","done":false}"#
        #expect(OllamaPayloadParser.extractToken(from: midLine2) == " world")

        // Final chunk — `done:true` suppresses token emission regardless of shape.
        let doneLine = #"{"model":"llama3.2","response":"","done":true,"done_reason":"stop"}"#
        #expect(OllamaPayloadParser.extractToken(from: doneLine) == nil)
    }

    // MARK: - SSE Stream Limits (NDJSON path)

    /// `parseResponseStream` enforces the same `SSEStreamLimits` caps as the
    /// SSE path — `maxTotalBytes`, `maxEventBytes`, `maxEventsPerSecond`.
    /// Three drivers in one test, each with a dedicated backend so per-backend
    /// limit overrides don't leak. A future change to the counters or
    /// `noteEventYielded()` gating would otherwise silently stop enforcing
    /// caps against a malicious Ollama-compatible server.
    /// Closes #511.
    @Test func streaming_sseStreamLimits_enforced() async throws {
        // --- streamTooLarge: total bytes exceed maxTotalBytes ---
        do {
            let (backend, chatURL) = makeConfiguredBackend()
            backend.sseStreamLimits = SSEStreamLimits(
                maxEventBytes: 1_000_000,
                maxTotalBytes: 100,
                maxEventsPerSecond: 5_000
            )
            try await loadBackend(backend)

            // ~200 bytes of valid NDJSON — comfortably over maxTotalBytes=100.
            let line = #"{"model":"llama3.2","message":{"role":"assistant","content":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"},"done":false}"#
            let chunks: [Data] = [ndjsonLine(line)]
            MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
            defer { MockURLProtocol.unstub(url: chatURL) }

            let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
            do {
                for try await _ in stream.events {}
                Issue.record("Expected SSEStreamError.streamTooLarge")
            } catch let error as SSEStreamError {
                switch error {
                case .streamTooLarge: break
                default: Issue.record("Expected streamTooLarge, got \(error)")
                }
            } catch {
                // The error may be wrapped; accept any throw but prefer SSEStreamError.
                Issue.record("Expected SSEStreamError.streamTooLarge, got \(error)")
            }
        }

        // --- eventTooLarge: single line exceeds maxEventBytes before newline ---
        do {
            let (backend, chatURL) = makeConfiguredBackend()
            backend.sseStreamLimits = SSEStreamLimits(
                maxEventBytes: 50,
                maxTotalBytes: 10_000_000,
                maxEventsPerSecond: 5_000
            )
            try await loadBackend(backend)

            // A single JSON line longer than 50 bytes with no newline until the end.
            let oversizeLine = #"{"model":"llama3.2","message":{"role":"assistant","content":"overflow-content-goes-well-beyond-fifty-bytes"},"done":false}"#
            let chunks: [Data] = [Data(oversizeLine.utf8)] // no newline
            MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
            defer { MockURLProtocol.unstub(url: chatURL) }

            let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
            do {
                for try await _ in stream.events {}
                Issue.record("Expected SSEStreamError.eventTooLarge")
            } catch let error as SSEStreamError {
                switch error {
                case .eventTooLarge: break
                default: Issue.record("Expected eventTooLarge, got \(error)")
                }
            } catch {
                Issue.record("Expected SSEStreamError.eventTooLarge, got \(error)")
            }
        }

        // --- eventRateExceeded: more than maxEventsPerSecond within 1s window ---
        do {
            let (backend, chatURL) = makeConfiguredBackend()
            backend.sseStreamLimits = SSEStreamLimits(
                maxEventBytes: 1_000_000,
                maxTotalBytes: 10_000_000,
                maxEventsPerSecond: 3
            )
            try await loadBackend(backend)

            // Five rapid content events — well above the cap of 3/s — delivered
            // all at once so they land inside the same rate window.
            var chunks: [Data] = []
            for i in 0..<5 {
                chunks.append(ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"t\#(i)"},"done":false}"#))
            }
            chunks.append(ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#))
            MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
            defer { MockURLProtocol.unstub(url: chatURL) }

            let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
            do {
                for try await _ in stream.events {}
                Issue.record("Expected SSEStreamError.eventRateExceeded")
            } catch let error as SSEStreamError {
                switch error {
                case .eventRateExceeded: break
                default: Issue.record("Expected eventRateExceeded, got \(error)")
                }
            } catch {
                Issue.record("Expected SSEStreamError.eventRateExceeded, got \(error)")
            }
        }
    }

    // MARK: - Request Body

    @Test func requestBody_containsModelAndMessages() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"hi"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "Hello there", systemPrompt: nil, config: .init())
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: {
            $0.url?.absoluteString.contains("api/chat") == true
        })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["model"] as? String == "llama3.2")
        #expect(json["stream"] as? Bool == true)

        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.last?["role"] == "user")
        #expect(messages.last?["content"] == "Hello there")
    }

    // MARK: - Conversation History

    @Test func conversationHistory_usedInMessages() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        backend.setConversationHistory([
            (role: "user", content: "First message"),
            (role: "assistant", content: "First reply"),
        ])

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"ok"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "ignored when history set", systemPrompt: nil, config: .init())
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: {
            $0.url?.absoluteString.contains("api/chat") == true
        })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: String]])

        #expect(messages.count == 2)
        #expect(messages[0]["content"] == "First message")
        #expect(messages[1]["content"] == "First reply")
    }

    /// Network-mocked unit test: verifies that every turn passed to
    /// `setConversationHistory` appears in the outgoing `messages` array in
    /// order. The coverage gap this closes: prior tests only set 2-turn history
    /// and didn't assert positional correctness of each entry.
    ///
    /// Sabotage check: deleting the `setConversationHistory` call below causes
    /// the messages count assertion to fail (backend falls back to the bare
    /// prompt-only message), confirming the assertion is load-bearing.
    @Test func generate_forwardsFullConversationHistoryInRequestBody() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        backend.setConversationHistory([
            (role: "user",      content: "What is 2+2?"),
            (role: "assistant", content: "4."),
            (role: "user",      content: "And 3+3?"),
        ])

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"6"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "And 3+3?", systemPrompt: nil, config: .init())
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == chatURL })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: String]])

        // All three history turns must be forwarded in order.
        #expect(messages.count == 3)
        #expect(messages[0]["role"] == "user")
        #expect(messages[0]["content"] == "What is 2+2?")
        #expect(messages[1]["role"] == "assistant")
        #expect(messages[1]["content"] == "4.")
        // The final turn must be the last user message with exact content.
        #expect(messages[2]["role"] == "user")
        #expect(messages[2]["content"] == "And 3+3?")
    }

    // MARK: - stopGeneration

    @Test func stopGeneration_setsIsGeneratingFalse() async throws {
        let (backend, _) = makeConfiguredBackend()
        try await loadBackend(backend)
        backend.stopGeneration()
        #expect(!backend.isGenerating)
    }

    // MARK: - NDJSON Parsing

    @Test func extractToken_parsesContent() {
        let json = #"{"model":"llama3.2","message":{"role":"assistant","content":"Hello"},"done":false}"#
        #expect(OllamaPayloadParser.extractToken(from: json) == "Hello")
    }

    @Test func extractToken_skipsEmptyContent() {
        let json = #"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":false}"#
        #expect(OllamaPayloadParser.extractToken(from: json) == nil)
    }

    @Test func extractToken_skipsDoneChunk() {
        let json = #"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"#
        #expect(OllamaPayloadParser.extractToken(from: json) == nil)
    }

    @Test func extractToken_malformedJSON_returnsNil() {
        #expect(OllamaPayloadParser.extractToken(from: "not json") == nil)
    }

    // MARK: - Thinking field (issue #487)

    /// Reasoning models (qwen3, qwen3.5:4b, deepseek-r1) emit chain-of-thought in
    /// a separate `thinking` field on the `/api/chat` endpoint. The backend
    /// must surface these as `.thinkingToken` events and close with
    /// `.thinkingCompleted` when thinking transitions back to empty.
    @Test func streaming_chatEndpoint_thinkingFieldEmitsThinkingEvents() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"Reasoning step 1","content":""},"done":false}"#),
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"","content":"answer"},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
        var events: [GenerationEvent] = []
        for try await event in stream.events { events.append(event) }

        // Ordering: .thinkingToken → .thinkingCompleted → .token
        let thinkingTokens = events.compactMap { event -> String? in
            if case .thinkingToken(let t) = event { return t } else { return nil }
        }
        let tokens = events.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }
        let completeCount = events.filter {
            if case .thinkingCompleted = $0 { return true } else { return false }
        }.count

        #expect(thinkingTokens == ["Reasoning step 1"])
        #expect(tokens == ["answer"])
        #expect(completeCount == 1)

        // Verify event ordering: thinkingToken precedes thinkingCompleted precedes token.
        var sawThinking = false
        var sawComplete = false
        for event in events {
            switch event {
            case .thinkingToken:
                #expect(!sawComplete, "thinkingToken must precede thinkingCompleted")
                sawThinking = true
            case .thinkingCompleted:
                #expect(sawThinking, "thinkingCompleted must follow at least one thinkingToken")
                sawComplete = true
            case .token:
                #expect(sawComplete, "visible token must follow thinkingCompleted")
            default: break
            }
        }
    }

    /// `/api/generate` surfaces reasoning at top-level `thinking` rather than
    /// under `message.thinking`. The backend must handle both endpoint shapes.
    @Test func streaming_generateEndpoint_topLevelThinkingEmitsThinkingEvents() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"response":"","thinking":"Thinking...","done":false}"#),
            ndjsonLine(#"{"response":"answer","thinking":"","done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
        var events: [GenerationEvent] = []
        for try await event in stream.events { events.append(event) }

        let thinkingTokens = events.compactMap { event -> String? in
            if case .thinkingToken(let t) = event { return t } else { return nil }
        }
        let tokens = events.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }
        let completeCount = events.filter {
            if case .thinkingCompleted = $0 { return true } else { return false }
        }.count

        #expect(thinkingTokens == ["Thinking..."])
        #expect(tokens == ["answer"])
        #expect(completeCount == 1)
    }

    /// Actual #487 repro: reasoning model exhausts `num_predict` entirely in
    /// `<think>` and Ollama returns a single line with `done:true`,
    /// `done_reason:length`, non-empty `thinking`, and empty `response`.
    /// Previously dropped on the floor — users saw a blank message.
    @Test func streaming_thinkingOnly_thenDone_flushesThinkingComplete() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"response":"","thinking":"entire reasoning","done":true,"done_reason":"length"}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
        var events: [GenerationEvent] = []
        for try await event in stream.events { events.append(event) }

        let thinkingTokens = events.compactMap { event -> String? in
            if case .thinkingToken(let t) = event { return t } else { return nil }
        }
        let completeCount = events.filter {
            if case .thinkingCompleted = $0 { return true } else { return false }
        }.count

        #expect(thinkingTokens == ["entire reasoning"])
        #expect(completeCount == 1)
    }

    /// `config.maxThinkingTokens` caps reasoning emission so a runaway
    /// reasoning model doesn't flood the UI. Lines with thinking beyond the
    /// cap are dropped; visible content still flows through.
    @Test func streaming_maxThinkingTokens_capsEmission() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        // 5 thinking-bearing lines, then transition to visible answer.
        let chunks: [Data] = [
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"t1","content":""},"done":false}"#),
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"t2","content":""},"done":false}"#),
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"t3","content":""},"done":false}"#),
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"t4","content":""},"done":false}"#),
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"t5","content":""},"done":false}"#),
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"","content":"answer"},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        var config = GenerationConfig()
        config.maxThinkingTokens = 2
        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: config)
        var events: [GenerationEvent] = []
        for try await event in stream.events { events.append(event) }

        let thinkingTokens = events.compactMap { event -> String? in
            if case .thinkingToken(let t) = event { return t } else { return nil }
        }
        let tokens = events.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }

        // Only the first 2 thinking chunks emit; t3, t4, t5 are dropped.
        #expect(thinkingTokens == ["t1", "t2"])
        #expect(tokens == ["answer"])
    }

    // MARK: - NDJSON parseLine

    @Test func parseLine_chatThinking() {
        let json = #"{"message":{"role":"assistant","thinking":"reasoning","content":"hi"},"done":false}"#
        let parsed = try? #require(OllamaPayloadParser.parseLine(json))
        #expect(parsed?.thinking == "reasoning")
        #expect(parsed?.content == "hi")
        #expect(parsed?.done == false)
    }

    @Test func parseLine_generateTopLevelThinking() {
        let json = #"{"response":"answer","thinking":"reasoning","done":true}"#
        let parsed = try? #require(OllamaPayloadParser.parseLine(json))
        #expect(parsed?.thinking == "reasoning")
        #expect(parsed?.content == "answer")
        #expect(parsed?.done == true)
    }

    @Test func extractThinking_returnsThinkingField() {
        let json = #"{"response":"","thinking":"reasoning","done":false}"#
        #expect(OllamaPayloadParser.extractThinking(from: json) == "reasoning")
    }

    @Test func extractThinking_emptyThinking_returnsNil() {
        let json = #"{"response":"hi","thinking":"","done":false}"#
        #expect(OllamaPayloadParser.extractThinking(from: json) == nil)
    }

    @Test func extractThinking_noThinkingField_returnsNil() {
        let json = #"{"message":{"role":"assistant","content":"hi"},"done":false}"#
        #expect(OllamaPayloadParser.extractThinking(from: json) == nil)
    }

    // MARK: - num_predict Budget (thinking + visible)

    /// Regression for the gemma4:e4b empty-response bug: Ollama counts
    /// chain-of-thought tokens against `num_predict`, so a single budget of
    /// `maxOutputTokens` was being fully consumed inside `<think>` on thinking
    /// models, leaving zero budget for visible output. The fix splits the
    /// server-side budget into `visibleBudget + thinkingBudget` and re-caps
    /// visible output client-side in `parseResponseStream`.
    ///
    /// Sabotage check (verified locally): reverting the production change to
    /// `"num_predict": config.maxOutputTokens ?? 2048` makes this test fail
    /// with `num_predict == 100` instead of `150`.
    @Test func generate_numPredict_equalsVisiblePlusThinkingBudget() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"ok"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        var config = GenerationConfig()
        config.maxOutputTokens = 100
        config.maxThinkingTokens = 50
        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: config)
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == chatURL })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let options = try #require(json["options"] as? [String: Any])
        let numPredict = try #require(options["num_predict"] as? Int)
        #expect(numPredict == 150)
    }

    /// When both caps are `nil` (default `GenerationConfig()`) on a **thinking
    /// model**, each side defaults to 2048, so `num_predict` must land on
    /// `4096`. Pins the default-default arithmetic so a future refactor
    /// doesn't silently shift the server-side ceiling.
    ///
    /// Post-P4 semantics: the 2048 thinking reservation is gated on the
    /// `/api/show` probe detecting a thinking-capable model. Non-thinking
    /// models land on 2048 (visible only) — see
    /// `generate_numPredict_nonThinkingModel_skipsReservation` below.
    @Test func generate_numPredict_bothCapsNil_thinkingModel_defaultsTo4096() async throws {
        let (backend, chatURL, showURL) = makeConfiguredBackendWithShow()

        // Thinking-capable `/api/show` so loadModel flips isThinkingModel=true.
        MockURLProtocol.stub(
            url: showURL,
            response: .immediate(
                data: apiShowBody(capabilities: ["completion", "thinking"]),
                statusCode: 200
            )
        )
        defer { MockURLProtocol.unstub(url: showURL) }

        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"ok"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        // GenerationConfig() ships maxOutputTokens = 2048 by default. Null it
        // out so we exercise the `?? 2048` fallback on both sides.
        var config = GenerationConfig()
        config.maxOutputTokens = nil
        config.maxThinkingTokens = nil
        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: config)
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == chatURL })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let options = try #require(json["options"] as? [String: Any])
        let numPredict = try #require(options["num_predict"] as? Int)
        #expect(numPredict == 4096)
    }

    // MARK: - P4: /api/show thinking-model detection + maxThinkingTokens semantics

    /// `/api/show` returning `capabilities: ["thinking"]` must flip
    /// `isThinkingModel = true` and reserve the 2048-token thinking budget
    /// when `maxThinkingTokens == nil`.
    @Test func loadModel_detectsThinkingModel_fromCapabilities() async throws {
        let (backend, chatURL, showURL) = makeConfiguredBackendWithShow()

        MockURLProtocol.stub(
            url: showURL,
            response: .immediate(
                data: apiShowBody(capabilities: ["completion", "thinking"]),
                statusCode: 200
            )
        )
        defer { MockURLProtocol.unstub(url: showURL) }

        try await loadBackend(backend)
        #expect(backend.isThinkingModel)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"ok"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        var config = GenerationConfig()
        config.maxOutputTokens = 100
        config.maxThinkingTokens = nil
        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: config)
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == chatURL })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let options = try #require(json["options"] as? [String: Any])
        #expect((options["num_predict"] as? Int) == 100 + 2048)
        // maxThinkingTokens=nil must NOT send a `think` directive (Ollama picks).
        #expect(json["think"] == nil)
    }

    /// `/api/show` without `thinking` capability and without `<think>`
    /// template markers must leave `isThinkingModel = false`, and
    /// `maxThinkingTokens == nil` must then skip the 2048 reservation
    /// entirely.
    @Test func loadModel_detectsNonThinkingModel_skipsReservation() async throws {
        let (backend, chatURL, showURL) = makeConfiguredBackendWithShow()

        MockURLProtocol.stub(
            url: showURL,
            response: .immediate(
                data: apiShowBody(
                    capabilities: ["completion"],
                    template: "{{ .System }}\n{{ .Prompt }}"
                ),
                statusCode: 200
            )
        )
        defer { MockURLProtocol.unstub(url: showURL) }

        try await loadBackend(backend)
        #expect(!backend.isThinkingModel)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"ok"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        var config = GenerationConfig()
        config.maxOutputTokens = 100
        config.maxThinkingTokens = nil
        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: config)
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == chatURL })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let options = try #require(json["options"] as? [String: Any])
        // visibleBudget only — no 2048 thinking reserve on non-thinking models.
        #expect((options["num_predict"] as? Int) == 100)
        #expect(json["think"] == nil)
    }

    /// Template-scan fallback: older Ollama builds omit `capabilities` but
    /// ship a Jinja `template` containing `<think>` on reasoning models.
    @Test func loadModel_detectsThinkingModel_fromTemplateMarkers() async throws {
        let (backend, _, showURL) = makeConfiguredBackendWithShow()

        let body = try JSONSerialization.data(withJSONObject: [
            "template": "{{ .System }}\n{{ .Prompt }}\n<think>\n{{ .Response }}\n</think>"
        ])
        MockURLProtocol.stub(
            url: showURL,
            response: .immediate(data: body, statusCode: 200)
        )
        defer { MockURLProtocol.unstub(url: showURL) }

        try await loadBackend(backend)
        #expect(backend.isThinkingModel)
    }

    /// `maxThinkingTokens == 0` on a thinking model must send `"think": false`
    /// and collapse `num_predict` to just the visible budget.
    @Test func maxThinkingTokens_zero_sendsThinkFalse_onThinkingModel() async throws {
        let (backend, chatURL, showURL) = makeConfiguredBackendWithShow()

        MockURLProtocol.stub(
            url: showURL,
            response: .immediate(
                data: apiShowBody(capabilities: ["thinking"]),
                statusCode: 200
            )
        )
        defer { MockURLProtocol.unstub(url: showURL) }

        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"ok"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        var config = GenerationConfig()
        config.maxOutputTokens = 100
        config.maxThinkingTokens = 0
        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: config)
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == chatURL })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let options = try #require(json["options"] as? [String: Any])
        #expect((options["num_predict"] as? Int) == 100)
        #expect((json["think"] as? Bool) == false)
    }

    /// `maxThinkingTokens == 0` on a non-thinking model must NOT send a
    /// `think` key (Ollama's absent-default behaviour already matches intent,
    /// and we keep the request body clean). `num_predict` collapses to
    /// visible-only.
    @Test func maxThinkingTokens_zero_omitsThink_onNonThinkingModel() async throws {
        let (backend, chatURL, showURL) = makeConfiguredBackendWithShow()

        MockURLProtocol.stub(
            url: showURL,
            response: .immediate(
                data: apiShowBody(capabilities: ["completion"]),
                statusCode: 200
            )
        )
        defer { MockURLProtocol.unstub(url: showURL) }

        try await loadBackend(backend)
        #expect(!backend.isThinkingModel)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"ok"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        var config = GenerationConfig()
        config.maxOutputTokens = 100
        config.maxThinkingTokens = 0
        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: config)
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == chatURL })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let options = try #require(json["options"] as? [String: Any])
        #expect((options["num_predict"] as? Int) == 100)
        #expect(json["think"] == nil)
    }

    /// `maxThinkingTokens == N > 0` reserves exactly `N` thinking tokens on
    /// top of the visible budget, regardless of whether the loaded model is
    /// flagged as thinking-capable. No `think` directive is sent — we let
    /// Ollama decide per model.
    @Test func maxThinkingTokens_explicitN_reservesN_regardlessOfModel() async throws {
        for thinkingCaps in [["thinking"], ["completion"]] {
            let (backend, chatURL, showURL) = makeConfiguredBackendWithShow()

            MockURLProtocol.stub(
                url: showURL,
                response: .immediate(
                    data: apiShowBody(capabilities: thinkingCaps),
                    statusCode: 200
                )
            )
            defer { MockURLProtocol.unstub(url: showURL) }

            try await loadBackend(backend)

            let chunks: [Data] = [
                ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"ok"},"done":false}"#),
                ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
            ]
            MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
            defer { MockURLProtocol.unstub(url: chatURL) }

            var config = GenerationConfig()
            config.maxOutputTokens = 100
            config.maxThinkingTokens = 50
            let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: config)
            for try await _ in stream.events { }

            let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == chatURL })
            let body = try extractBody(from: captured)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            let options = try #require(json["options"] as? [String: Any])
            #expect((options["num_predict"] as? Int) == 150, "thinkingCaps=\(thinkingCaps)")
            #expect(json["think"] == nil, "thinkingCaps=\(thinkingCaps)")
        }
    }

    /// `/api/show` returning HTTP 404 (older Ollama without the endpoint)
    /// must not throw — loadModel succeeds with `isThinkingModel = false`.
    @Test func loadModel_apiShowFailure_defaultsToNonThinking_andDoesNotThrow() async throws {
        let (backend, chatURL, showURL) = makeConfiguredBackendWithShow()

        MockURLProtocol.stub(
            url: showURL,
            response: .immediate(data: Data("not found".utf8), statusCode: 404)
        )
        defer { MockURLProtocol.unstub(url: showURL) }

        try await loadBackend(backend)
        #expect(backend.isModelLoaded)
        #expect(!backend.isThinkingModel)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"ok"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        var config = GenerationConfig()
        config.maxOutputTokens = 100
        config.maxThinkingTokens = nil
        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: config)
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == chatURL })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let options = try #require(json["options"] as? [String: Any])
        #expect((options["num_predict"] as? Int) == 100)
    }

    /// Visible output must be re-capped client-side because the server-side
    /// budget is doubled to reserve thinking tokens. With no `eval_count` on
    /// intermediate lines (per Ollama's documented wire format), the cap
    /// falls back to the NDJSON line counter, so 5 single-line chunks + cap=3
    /// yields exactly 3 `.token` events before a clean stream termination.
    ///
    /// Sabotage check (verified locally): deleting the `continuation.finish();
    /// return` guard in `parseResponseStream` makes this test fail with
    /// tokens.count == 5.
    @Test func streaming_visibleCap_terminatesStreamCleanly() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"a"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"b"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"c"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"d"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"e"},"done":false}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        var config = GenerationConfig()
        config.maxOutputTokens = 3
        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: config)

        var tokens: [String] = []
        var sawThinkingComplete = false
        for try await event in stream.events {
            switch event {
            case .token(let t): tokens.append(t)
            case .thinkingCompleted: sawThinkingComplete = true
            default: break
            }
        }

        #expect(tokens == ["a", "b", "c"])
        #expect(!sawThinkingComplete, "no thinking was emitted so no .thinkingCompleted should fire")
    }

    /// When an Ollama-compatible server emits a running `eval_count` on
    /// intermediate lines, the cap must use it — not the NDJSON line count
    /// — so multi-word content chunks can't slip extra tokens past the
    /// `maxOutputTokens` ceiling. This is the PR #586 fixture's key
    /// limitation made concrete: under the old line-count cap, five
    /// multi-word lines at `maxOutputTokens=5` would yield 5 lines * multi
    /// words each. With exact accounting, generation stops the instant
    /// `eval_count` crosses the cap.
    ///
    /// Sabotage check (verified locally): reverting the cap check to
    /// `visibleLineCount >= limit` (ignoring `parsed.evalCount`) makes this
    /// test fail because all 5 multi-word lines pass through (the cap isn't
    /// reached until line 6).
    @Test func streaming_visibleCap_usesExactEvalCount_overLineCount() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        // Each intermediate line is multi-word content + running eval_count
        // advancing 2 → 4 → 6 → 8 → 10. With `maxOutputTokens = 5`, the first
        // line that observes `eval_count >= 5` is the `eval_count:6` line;
        // cap triggers on its arrival BEFORE emitting the token, so two tokens
        // (the `eval_count:2` and `eval_count:4` lines) are yielded.
        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"hello world"},"done":false,"eval_count":2}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"foo bar"},"done":false,"eval_count":4}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"baz qux"},"done":false,"eval_count":6}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"extra"},"done":false,"eval_count":8}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"more"},"done":false,"eval_count":10}"#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true,"eval_count":10,"prompt_eval_count":3}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        var config = GenerationConfig()
        config.maxOutputTokens = 5
        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: config)

        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let t) = event { tokens.append(t) }
        }

        // Two tokens emitted (eval_count 2 and 4 were below the cap of 5).
        // The eval_count=6 line is the first to cross the cap; its content
        // ("baz qux") must NOT appear. Under the old line-count cap this
        // assertion would fail because all 5 multi-word lines would pass.
        #expect(tokens == ["hello world", "foo bar"])
    }

    // MARK: - <think>-in-content fallback

    /// Some Ollama tags (notably certain Qwen3 deployments) don't populate
    /// the dedicated `message.thinking` field — reasoning leaks directly
    /// into `message.content` as a `<think>…</think>` block. When no
    /// dedicated thinking field is ever seen on the stream and content
    /// contains `<think>`, the backend must route content through
    /// `ThinkingTransform` so callers still receive the usual thinkingToken /
    /// thinkingCompleted / token event shape instead of raw tags baked into
    /// visible output.
    @Test func streaming_thinkingInContentFallback_emitsThinkingEvents() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        // `message.thinking` absent on every line. `<think>reasoning</think>answer`
        // is split across two chunks so the parser has to hold back the
        // partial closing tag and reassemble across NDJSON boundaries.
        let chunks: [Data] = [
            ndjsonLine(#"{"message":{"role":"assistant","content":"<think>reasoning"},"done":false}"#),
            ndjsonLine(#"{"message":{"role":"assistant","content":"</think>answer"},"done":false}"#),
            ndjsonLine(#"{"message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
        var events: [GenerationEvent] = []
        for try await event in stream.events { events.append(event) }

        let thinkingText = events.compactMap { event -> String? in
            if case .thinkingToken(let t) = event { return t } else { return nil }
        }.joined()
        let visibleText = events.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }.joined()
        let completeCount = events.filter {
            if case .thinkingCompleted = $0 { return true } else { return false }
        }.count

        #expect(thinkingText == "reasoning")
        #expect(visibleText == "answer")
        #expect(completeCount == 1, "expected exactly one .thinkingCompleted (got \(completeCount))")

        // No raw `<think>` tags may leak into either event type.
        for event in events {
            switch event {
            case .thinkingToken(let t):
                #expect(!t.contains("<think>") && !t.contains("</think>"),
                        "thinkingToken must not carry raw tags (got \(t))")
            case .token(let t):
                #expect(!t.contains("<think>") && !t.contains("</think>"),
                        "visible .token must not carry raw tags (got \(t))")
            default: break
            }
        }
    }

    /// When the dedicated `message.thinking` field IS populated, the
    /// fallback parser must stay dormant so reasoning isn't double-parsed
    /// and a literal `<think>` in visible content passes through unchanged.
    @Test func streaming_thinkingFieldPresent_fallbackParserDormant() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        // message.thinking populated on the first line; the second line's
        // content contains the literal string `<think>` which would
        // otherwise trip the fallback. Because the first line latched
        // sawThinkingField, the fallback stays disengaged and content
        // passes through verbatim.
        let chunks: [Data] = [
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"dedicated","content":""},"done":false}"#),
            ndjsonLine(#"{"message":{"role":"assistant","thinking":"","content":"pre <think> post"},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
        var events: [GenerationEvent] = []
        for try await event in stream.events { events.append(event) }

        let thinkingTokens = events.compactMap { event -> String? in
            if case .thinkingToken(let t) = event { return t } else { return nil }
        }
        let tokens = events.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }

        #expect(thinkingTokens == ["dedicated"],
                "only the dedicated thinking field should surface as .thinkingToken")
        #expect(tokens.joined() == "pre <think> post",
                "raw <think> in visible content must NOT be re-parsed once the dedicated field was seen")
    }

    // MARK: - num_ctx request option (Ollama OLLAMA_CONTEXT_LENGTH footgun)

    /// Ollama's server-side `OLLAMA_CONTEXT_LENGTH` defaults to 2048 tokens
    /// and silently truncates multi-turn conversations that exceed it with
    /// no error signal. Every request must set `options.num_ctx` explicitly
    /// so we stop relying on the server default. When `loadModel` was
    /// called with a `.cloud()` plan (requested=1), the backend must still
    /// fall back to the conservative floor so chat stays usable.
    @Test func requestBody_alwaysSetsNumCtx_atOrAboveFloor() async throws {
        let (backend, chatURL) = makeConfiguredBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"{"message":{"role":"assistant","content":"ok"},"done":false}"#),
            ndjsonLine(#"{"message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == chatURL })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let options = try #require(json["options"] as? [String: Any])
        let numCtx = try #require(options["num_ctx"] as? Int,
                                  "options.num_ctx must be present on every request to override Ollama's 2048 server default")
        #expect(numCtx >= OllamaBackend.defaultNumCtxFloor,
                "num_ctx must be at or above the floor (got \(numCtx))")
    }

    // MARK: - effectiveNumCtx lock (race-condition regression)

    /// `effectiveNumCtx` is written by `loadModel` and read by `buildRequest`.
    /// Both must go through `withStateLock` so a concurrent model switch
    /// (loadModel + generate overlap) can't cause `buildRequest` to read a
    /// stale or partially-updated context size, which would make Ollama
    /// silently truncate at the wrong boundary with no error signal.
    ///
    /// This test verifies the happy-path contract: a plan carrying a context
    /// size above the default floor must land in `options.num_ctx` on the
    /// next `generate` call. The stateLock-based isolation is the only
    /// mechanism that makes this safe across concurrent calls.
    ///
    /// Sabotage check: removing the `withStateLock` wrapper from either the
    /// write in `loadModel` or the read in `buildRequest` does not break this
    /// sequential test, but TSan in a concurrent scenario would fire — the
    /// comment on `effectiveNumCtx` and this fixture together document the
    /// invariant for future readers.
    @Test func loadModel_customPlan_numCtxFlowsThroughToRequest() async throws {
        let (backend, chatURL) = makeConfiguredBackend()

        // Use a plan with a context size well above the floor so the assertion
        // can distinguish "used the plan value" from "fell back to the floor".
        let largePlan = ModelLoadPlan.cloud(requestedContextSize: 32768)
        try await backend.loadModel(from: URL(string: "unused:")!, plan: largePlan)

        let chunks: [Data] = [
            ndjsonLine(#"{"message":{"role":"assistant","content":"ok"},"done":false}"#),
            ndjsonLine(#"{"message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == chatURL })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let options = try #require(json["options"] as? [String: Any])
        let numCtx = try #require(options["num_ctx"] as? Int)
        #expect(numCtx == 32768,
                "num_ctx must reflect the plan-derived value written by loadModel (got \(numCtx))")
    }

    // MARK: - :cloud model tag guard

    /// Ollama v0.18.0+ routes `:cloud`-suffixed model IDs to remote
    /// inference (Ollama's hosted service) rather than the local server.
    /// ManifoldKit is local-first, so silently forwarding prompts off-device
    /// would leak conversation content the user didn't consciously opt into.
    /// `loadModel` must reject the tag with a descriptive error.
    @Test func loadModel_cloudSuffixedTag_throws() async throws {
        let backend = OllamaBackend(urlSession: makeMockSession())
        let baseURL = URL(string: "http://ollama-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, modelName: "qwen3:cloud")

        do {
            try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
            Issue.record("Expected throw for :cloud-suffixed model tag")
        } catch {
            guard let cloudError = extractCloudError(error) else {
                Issue.record("Expected CloudBackendError, got \(error)")
                return
            }
            switch cloudError {
            case .invalidURL(let message):
                #expect(message.contains(":cloud"),
                        "error message should mention :cloud so the user knows why the load failed (got: \(message))")
            default:
                Issue.record("Expected .invalidURL, got \(cloudError)")
            }
        }
        #expect(!backend.isModelLoaded,
                "backend must not mark itself loaded after :cloud rejection")
    }

    /// The :cloud guard is a `hasSuffix` check, so tag names that merely
    /// *contain* `:cloud` as a substring or end with a superstring (e.g.
    /// `:cloudlike`, `:cloud-beta`) must be allowed through — only Ollama's
    /// exact `:cloud` suffix routes to remote inference. This locks the
    /// boundary so a future refactor to `contains(":cloud")` would be
    /// caught immediately.
    @Test func loadModel_cloudSubstringButNotSuffix_doesNotThrow() async throws {
        for tag in ["qwen3:cloudlike", "qwen3:cloud-beta", "qwen3-cloud", "cloud-qwen3"] {
            let backend = OllamaBackend(urlSession: makeMockSession())
            let baseURL = URL(string: "http://ollama-\(UUID().uuidString).test")!
            backend.configure(baseURL: baseURL, modelName: tag)
            try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
            #expect(backend.isModelLoaded,
                    "tag '\(tag)' contains 'cloud' but does not end in ':cloud' — must load normally")
        }
    }

    // MARK: - requestIdleTimeout (slow cold-load protection)

    @Test func requestIdleTimeout_defaultMatchesConstant() {
        // Sabotage: removing the `requestIdleTimeout = defaultRequestIdleTimeout`
        // line in OllamaBackend.init causes this to return nil.
        let backend = OllamaBackend(urlSession: makeMockSession())
        #expect(backend.requestIdleTimeout == OllamaBackend.defaultRequestIdleTimeout,
                "OllamaBackend must default requestIdleTimeout to defaultRequestIdleTimeout so cold-loading servers aren't killed")
    }

    @Test func requestIdleTimeout_defaultIsGenerous() {
        // 1800s matches the 30-min keepAlive default; anything below 600s
        // would kill large models during a realistic VRAM load.
        #expect(OllamaBackend.defaultRequestIdleTimeout >= 600,
                "defaultRequestIdleTimeout must be at least 600s to survive slow model cold-loads")
    }

    @Test func requestIdleTimeout_stampsGenerationRequest() async throws {
        let (backend, chatURL, showURL) = makeConfiguredBackendWithShow()
        MockURLProtocol.stub(url: showURL, response: .immediate(data: apiShowBody(capabilities: []), statusCode: 200))
        defer { MockURLProtocol.unstub(url: showURL) }
        try await loadBackend(backend)

        let doneChunk = ndjsonLine("""
        {"model":"llama3.2","message":{"role":"assistant","content":"hi"},"done":true}
        """)
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: [doneChunk], statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
        for try await _ in stream.events {}

        let captured = MockURLProtocol.capturedRequests.last { $0.url?.absoluteString.contains("api/chat") == true }
        // Sabotage: removing the `request.timeoutInterval = timeout` line in
        // SSECloudBackend.makeGenerationTaskContext causes the captured request
        // to carry the URLRequest default (60s) rather than our 1800s.
        #expect(
            captured?.timeoutInterval == OllamaBackend.defaultRequestIdleTimeout,
            "Generation request must carry requestIdleTimeout as URLRequest.timeoutInterval"
        )
    }

    @Test func requestIdleTimeout_overridePropagates() async throws {
        let (backend, chatURL, showURL) = makeConfiguredBackendWithShow()
        backend.requestIdleTimeout = 42
        MockURLProtocol.stub(url: showURL, response: .immediate(data: apiShowBody(capabilities: []), statusCode: 200))
        defer { MockURLProtocol.unstub(url: showURL) }
        try await loadBackend(backend)

        let doneChunk = ndjsonLine("""
        {"model":"llama3.2","message":{"role":"assistant","content":"ok"},"done":true}
        """)
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: [doneChunk], statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: .init())
        for try await _ in stream.events {}

        let captured = MockURLProtocol.capturedRequests.last { $0.url?.absoluteString.contains("api/chat") == true }
        // Sabotage: changing backend.requestIdleTimeout = 42 to any other value
        // or removing the wiring in makeGenerationTaskContext causes this to fail.
        #expect(captured?.timeoutInterval == 42,
                "Overriding requestIdleTimeout must propagate to URLRequest.timeoutInterval")
    }
}

// MARK: - OllamaModelListService Tests

@Suite("OllamaModelListService", .serialized)
struct OllamaModelListServiceTests {

    init() {
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
    }

    private func makeService() -> (OllamaModelListService, URL) {
        let session = makeMockSession()
        let service = OllamaModelListService(urlSession: session)
        let baseURL = URL(string: "http://ollama-models-\(UUID().uuidString).test")!
        return (service, baseURL)
    }

    @Test func fetchModels_parsesResponse() async throws {
        let (service, baseURL) = makeService()
        let tagsURL = baseURL.appendingPathComponent("api/tags")

        let response = """
        {"models":[
            {"name":"llama3.2:8b","size":5368709120},
            {"name":"mistral:7b","size":4294967296},
            {"name":"phi3:mini","size":2147483648}
        ]}
        """
        MockURLProtocol.stub(url: tagsURL, response: .immediate(data: Data(response.utf8), statusCode: 200))
        defer { MockURLProtocol.unstub(url: tagsURL) }

        let models = try await service.fetchModels(from: baseURL)

        #expect(models.count == 3)
        // Should be sorted alphabetically.
        #expect(models[0].name == "llama3.2:8b")
        #expect(models[1].name == "mistral:7b")
        #expect(models[2].name == "phi3:mini")
    }

    @Test func fetchModels_extractsQuantization() async throws {
        let (service, baseURL) = makeService()
        let tagsURL = baseURL.appendingPathComponent("api/tags")

        let response = #"{"models":[{"name":"llama3.2:8b-q4_0","size":4294967296}]}"#
        MockURLProtocol.stub(url: tagsURL, response: .immediate(data: Data(response.utf8), statusCode: 200))
        defer { MockURLProtocol.unstub(url: tagsURL) }

        let models = try await service.fetchModels(from: baseURL)
        #expect(models.first?.quantization == "8b-q4_0")
    }

    @Test func fetchModels_extractsFamilyTag() async throws {
        let (service, baseURL) = makeService()
        let tagsURL = baseURL.appendingPathComponent("api/tags")

        let response = #"{"models":[{"name":"llama3.2:8b","size":4294967296,"details":{"family":"llama"}}]}"#
        MockURLProtocol.stub(url: tagsURL, response: .immediate(data: Data(response.utf8), statusCode: 200))
        defer { MockURLProtocol.unstub(url: tagsURL) }

        let models = try await service.fetchModels(from: baseURL)
        #expect(models.first?.familyTag == "llama")
    }

    @Test func fetchModels_missingDetails_familyTagIsNil() async throws {
        let (service, baseURL) = makeService()
        let tagsURL = baseURL.appendingPathComponent("api/tags")

        let response = #"{"models":[{"name":"llama3.2:8b","size":4294967296}]}"#
        MockURLProtocol.stub(url: tagsURL, response: .immediate(data: Data(response.utf8), statusCode: 200))
        defer { MockURLProtocol.unstub(url: tagsURL) }

        let models = try await service.fetchModels(from: baseURL)
        #expect(models.first?.familyTag == nil)
    }

    @Test func fetchModels_emptyList_returnsEmpty() async throws {
        let (service, baseURL) = makeService()
        let tagsURL = baseURL.appendingPathComponent("api/tags")

        MockURLProtocol.stub(url: tagsURL, response: .immediate(data: Data(#"{"models":[]}"#.utf8), statusCode: 200))
        defer { MockURLProtocol.unstub(url: tagsURL) }

        let models = try await service.fetchModels(from: baseURL)
        #expect(models.isEmpty)
    }

    @Test func fetchModels_serverError_throws() async throws {
        let (service, baseURL) = makeService()
        let tagsURL = baseURL.appendingPathComponent("api/tags")

        MockURLProtocol.stub(url: tagsURL, response: .immediate(data: Data(), statusCode: 503))
        defer { MockURLProtocol.unstub(url: tagsURL) }

        do {
            _ = try await service.fetchModels(from: baseURL)
            Issue.record("Expected error on 503 response")
        } catch {
            guard let error = extractCloudError(error) else { Issue.record("Expected CloudBackendError, got \(error)"); return }
            switch error {
            case .serverError(let code, _): #expect(code == 503)
            default: Issue.record("Expected serverError, got \(error)")
            }
        }
    }

    @Test func fetchModels_networkError_throws() async throws {
        let (service, baseURL) = makeService()
        let tagsURL = baseURL.appendingPathComponent("api/tags")

        MockURLProtocol.stub(url: tagsURL, response: .error(URLError(.notConnectedToInternet)))
        defer { MockURLProtocol.unstub(url: tagsURL) }

        do {
            _ = try await service.fetchModels(from: baseURL)
            Issue.record("Expected network error")
        } catch {
            // expected
        }
    }
}

// MARK: - Body Extraction Helper

private func extractBody(from request: URLRequest?) throws -> Data {
    guard let request else {
        Issue.record("No captured request")
        return Data()
    }
    if let body = request.httpBody { return body }
    if let stream = request.httpBodyStream {
        var data = Data()
        stream.open()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 4096)
            if read > 0 { data.append(buffer, count: read) }
        }
        stream.close()
        return data
    }
    Issue.record("Request has neither httpBody nor httpBodyStream")
    return Data()
}
