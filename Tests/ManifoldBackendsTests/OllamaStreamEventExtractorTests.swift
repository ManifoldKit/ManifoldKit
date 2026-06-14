import XCTest
import Foundation
@testable import ManifoldBackends
@testable import ManifoldCloud
// v0.48 product split: internal symbols moved into the family targets and
// ManifoldCloudCore; the ManifoldCloud shim only re-exports public surface.
@testable import ManifoldOllama
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore
@testable import ManifoldInference
import ManifoldTestSupport

/// Phase 3/Ollama — event-surface coverage and parity for
/// ``OllamaStreamEventExtractor``.
///
/// Mirrors `OpenAIStreamEventExtractorTests` (Phase 2/B/iii/γ). These tests
/// drive the new stateful extractor against the on-disk Ollama NDJSON
/// fixtures under `Tests/Fixtures/backends/ollama/` and assert it emits
/// the full event vocabulary that the legacy ``OllamaStreamProcessor``
/// emitted before it was deleted.
final class OllamaStreamEventExtractorTests: XCTestCase {

    // MARK: - Streaming / simple-prompt fixture

    func test_extractor_streamingSimplePrompt_emitsTokensAndUsage() throws {
        let events = try driveExtractor(scenario: "streaming/simple-prompt", config: GenerationConfig())
        let tokens: [String] = events.compactMap {
            if case .token(let t) = $0 { return t } else { return nil }
        }
        XCTAssertEqual(tokens, ["Hello", " world"],
                       "extractor must replay the same token sequence as the legacy OllamaStreamProcessor")
        let usage: (prompt: Int, completion: Int)? = events.lazy.compactMap {
            if case .usage(let u) = $0 { return (u.promptTokens, u.completionTokens) } else { return nil }
        }.first
        XCTAssertEqual(usage?.prompt, 7)
        XCTAssertEqual(usage?.completion, 2)
    }

    // MARK: - Tool-calls / simple fixture
    //
    // Whole-call shape: one NDJSON line carries the entire `tool_calls[]`
    // entry. The extractor synthesises a uniform start + arguments-delta +
    // finalised .toolCall triple, mirroring PR #783's invariant.
    func test_extractor_toolCallsSimple_emitsStartDeltaAndFinalisedCall() throws {
        let events = try driveExtractor(scenario: "tool-calls/simple", config: GenerationConfig())

        // Strip empty tokens that arrive on the same line as the tool call.
        let filtered = events.filter {
            if case .token(let t) = $0 { return !t.isEmpty }
            return true
        }

        // start + delta + finalised + usage = 4
        XCTAssertEqual(filtered.count, 4, "expected start + delta + finalised + usage (saw \(filtered))")
        guard filtered.count == 4 else { return }

        if case .toolCallStart(let id, let name) = filtered[0] {
            XCTAssertEqual(id, "call_fixture_001")
            XCTAssertEqual(name, "get_weather")
        } else { XCTFail("expected .toolCallStart, got \(filtered[0])") }

        if case .toolCallArgumentsDelta(let id, let delta) = filtered[1] {
            XCTAssertEqual(id, "call_fixture_001")
            XCTAssertTrue(delta.contains("Paris"))
        } else { XCTFail("expected .toolCallArgumentsDelta, got \(filtered[1])") }

        if case .toolCall(let call) = filtered[2] {
            XCTAssertEqual(call.id, "call_fixture_001")
            XCTAssertEqual(call.toolName, "get_weather")
            XCTAssertTrue(call.arguments.contains("Paris"))
        } else { XCTFail("expected .toolCall, got \(filtered[2])") }

        if case .usage(let u) = filtered[3] {
            XCTAssertEqual(u.promptTokens, 42)
            XCTAssertEqual(u.completionTokens, 18)
        } else { XCTFail("expected .usage, got \(filtered[3])") }
    }

    // MARK: - Usage / basic fixture

    func test_extractor_usageBasic_emitsUsageEvent() throws {
        let events = try driveExtractor(scenario: "usage/basic", config: GenerationConfig())
        let usage: (prompt: Int, completion: Int)? = events.lazy.compactMap {
            if case .usage(let u) = $0 { return (u.promptTokens, u.completionTokens) } else { return nil }
        }.first
        XCTAssertEqual(usage?.prompt, 12)
        XCTAssertEqual(usage?.completion, 48)
    }

    // MARK: - Thinking / qwen-style fixture
    //
    // Two thinking lines → thinkingToken × 2; the third line has no
    // `thinking` field and a non-empty `content` → thinkingCompleted (auto-
    // closed on transition) + token. The done line carries usage.
    func test_extractor_thinkingQwenStyle_yieldsThinkingHandoff() throws {
        let events = try driveExtractor(scenario: "thinking/qwen-style", config: GenerationConfig())

        XCTAssertEqual(events.count, 5, "expected thinkingToken × 2, thinkingCompleted, token, usage (saw \(events))")
        guard events.count == 5 else { return }

        if case .thinkingToken(let t1) = events[0] { XCTAssertEqual(t1, "Let me consider") }
        else { XCTFail("event[0] expected .thinkingToken, got \(events[0])") }

        if case .thinkingToken(let t2) = events[1] { XCTAssertEqual(t2, " the question.") }
        else { XCTFail("event[1] expected .thinkingToken, got \(events[1])") }

        if case .thinkingCompleted = events[2] { /* ok */ }
        else { XCTFail("event[2] expected .thinkingCompleted, got \(events[2])") }

        if case .token(let visible) = events[3] { XCTAssertEqual(visible, "Answer.") }
        else { XCTFail("event[3] expected .token, got \(events[3])") }

        if case .usage(let u) = events[4] {
            XCTAssertEqual(u.promptTokens, 5)
            XCTAssertEqual(u.completionTokens, 12)
        } else { XCTFail("event[4] expected .usage, got \(events[4])") }
    }

    // MARK: - Cross-stream isolation (sabotage)

    func test_extractor_isFreshPerInstance_stateDoesNotLeakAcrossStreams() throws {
        let events1 = try driveExtractor(scenario: "tool-calls/simple", config: GenerationConfig())
        let events2 = try driveExtractor(scenario: "tool-calls/simple", config: GenerationConfig())
        let calls1 = events1.filter { if case .toolCall = $0 { return true } else { return false } }
        let calls2 = events2.filter { if case .toolCall = $0 { return true } else { return false } }
        XCTAssertEqual(calls1.count, 1)
        XCTAssertEqual(calls2.count, 1)
    }

    // MARK: - Factory wiring

    func test_makeOllamaStreamConsumer_returnsExtractorForOllamaCase() {
        XCTAssertNotNil(CloudPayloadHandler.ollama.makeOllamaStreamConsumer(config: GenerationConfig()))
    }

    func test_makeOllamaStreamConsumer_returnsNilForOtherProviders() {
        XCTAssertNil(CloudPayloadHandler.openAI.makeOllamaStreamConsumer(config: GenerationConfig()))
        XCTAssertNil(CloudPayloadHandler.claude.makeOllamaStreamConsumer(config: GenerationConfig()))
        XCTAssertNil(CloudPayloadHandler.openAIResponses.makeOllamaStreamConsumer(config: GenerationConfig()))
    }

    // MARK: - Helpers

    private func driveExtractor(scenario: String, config: GenerationConfig) throws -> [GenerationEvent] {
        let payloads = try loadPayloads(scenario: scenario)
        let extractor = OllamaStreamEventExtractor(config: config)
        var events: [GenerationEvent] = []
        for payload in payloads {
            events.append(contentsOf: extractor.consume(payload: payload))
        }
        events.append(contentsOf: extractor.finish())
        return events
    }

    private func loadPayloads(scenario: String) throws -> [String] {
        let url = try fixtureURL(scenario: scenario, file: "response.ndjson")
        let raw = try String(contentsOf: url, encoding: .utf8)
        return raw.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private func fixtureURL(scenario: String, file: String, filePath: StaticString = #filePath) throws -> URL {
        let root = try Self.locateFixturesRoot(filePath: filePath)
        return root
            .appendingPathComponent("backends")
            .appendingPathComponent("ollama")
            .appendingPathComponent(scenario)
            .appendingPathComponent(file)
    }

    private static func locateFixturesRoot(filePath: StaticString) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Tests/Fixtures")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "OllamaStreamEventExtractorTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Tests/Fixtures/ from #filePath"
        ])
    }
}

// MARK: - Inline parity

/// Compares the extractor's event sequence against the live
/// ``OllamaBackend/parseResponseStream`` path (which itself now routes
/// through the extractor inside `CloudRoutedStreamParser`).
/// The parity test exists to guard against a regression where the routing
/// is silently bypassed — if both paths drift the assertion fails with a
/// per-event diff.
final class OllamaStreamEventExtractorParityTests: XCTestCase {

    @MainActor
    func test_parity_streamingSimplePrompt() async throws {
        try await assertParity(scenario: "streaming/simple-prompt")
    }

    @MainActor
    func test_parity_toolCallsSimple() async throws {
        try await assertParity(scenario: "tool-calls/simple")
    }

    @MainActor
    func test_parity_usageBasic() async throws {
        try await assertParity(scenario: "usage/basic")
    }

    @MainActor
    func test_parity_thinkingQwenStyle() async throws {
        try await assertParity(scenario: "thinking/qwen-style")
    }

    @MainActor
    private func assertParity(scenario: String, filePath: StaticString = #filePath) async throws {
        let ndjsonText = try loadResponse(scenario: scenario, filePath: filePath)
        let payloads = ndjsonText.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Drive the extractor directly.
        let extractor = OllamaStreamEventExtractor(config: GenerationConfig())
        var extractorEvents: [GenerationEvent] = []
        for payload in payloads {
            extractorEvents.append(contentsOf: extractor.consume(payload: payload))
        }
        extractorEvents.append(contentsOf: extractor.finish())

        // Drive the backend end-to-end via MockURLProtocol.
        let backendEvents = try await runBackend(ndjsonText: ndjsonText)

        XCTAssertEqual(
            extractorEvents.map(eventKey),
            backendEvents.map(eventKey),
            """
            [\(scenario)] event-sequence parity drift.
              extractor : \(extractorEvents)
              backend   : \(backendEvents)
            """
        )
    }

    private func eventKey(_ event: GenerationEvent) -> String {
        switch event {
        case .token(let s): return "token(\(s))"
        case .thinkingToken(let s): return "thinkingToken(\(s))"
        case .thinkingCompleted: return "thinkingCompleted"
        case .thinkingSignature(let s): return "thinkingSignature(\(s))"
        case .toolCallStart(let id, let name): return "toolCallStart(\(id),\(name))"
        case .toolCallArgumentsDelta(let id, let d): return "toolCallArgumentsDelta(\(id),\(d))"
        case .toolCall(let c): return "toolCall(\(c.id),\(c.toolName),\(c.arguments))"
        case .usage(let u): return "usage(\(u.promptTokens),\(u.completionTokens))"
        case .prefillProgress(let n, let t, _): return "prefillProgress(\(n)/\(t))"
        case .toolIterationLimitExceeded(let n): return "toolIterationLimitExceeded(\(n))"
        case .toolResult: return "toolResult"
        case .toolProgress: return "toolProgress"
        case .toolDispatchStarted: return "toolDispatchStarted"
        case .toolDispatchCompleted: return "toolDispatchCompleted"
        case .toolCallApproved: return "toolCallApproved"
        case .kvCacheReuse: return "kvCacheReuse"
        case .throttleDiagnostic: return "throttleDiagnostic"
        case .handoffRequested(let h): return "handoffRequested(\(h.targetAgentID))"
        }
    }

    @MainActor
    private func runBackend(ndjsonText: String) async throws -> [GenerationEvent] {
        // Use a public-shaped resolver result; 127.0.0.1 is filtered by
        // `DNSRebindingGuard` as loopback and would block the request.
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
        defer { DNSRebindingGuard._resolverForTesting = nil }

        let mockURL = URL(string: "http://ollama-fixture-\(UUID().uuidString).test")!
        let endpointURL = mockURL.appendingPathComponent("api/chat")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { MockURLProtocol.unstub(url: endpointURL) }

        // Ship the NDJSON body as one chunk; the NDJSONTransport in the
        // routed loop handles line framing.
        MockURLProtocol.stub(
            url: endpointURL,
            response: .immediate(data: Data(ndjsonText.utf8), statusCode: 200, headers: ["Content-Type": "application/x-ndjson"])
        )

        let backend = OllamaBackend(urlSession: session)
        backend.configure(baseURL: mockURL, modelName: "fixture-model")
        // Skip the /api/show probe — provide an empty stub so the load
        // path completes without hitting a separate network mock.
        let showURL = mockURL.appendingPathComponent("api/show")
        MockURLProtocol.stub(
            url: showURL,
            response: .immediate(data: Data("{}".utf8), statusCode: 200, headers: ["Content-Type": "application/json"])
        )
        defer { MockURLProtocol.unstub(url: showURL) }

        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        var events: [GenerationEvent] = []
        let stream = try backend.generate(prompt: "fixture", systemPrompt: nil, config: GenerationConfig())
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    private func loadResponse(scenario: String, filePath: StaticString) throws -> String {
        let root = try Self.locateFixturesRoot(filePath: filePath)
        let url = root
            .appendingPathComponent("backends")
            .appendingPathComponent("ollama")
            .appendingPathComponent(scenario)
            .appendingPathComponent("response.ndjson")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func locateFixturesRoot(filePath: StaticString) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Tests/Fixtures")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "OllamaStreamEventExtractorParityTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Tests/Fixtures/ from #filePath"
        ])
    }
}
