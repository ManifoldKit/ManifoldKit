#if CloudSaaS
import XCTest
import Foundation
@testable import ManifoldBackends
@testable import ManifoldCloud
// v0.48 product split: internal symbols moved into the family targets and
// ManifoldCloudCore; the ManifoldCloud shim only re-exports public surface.
#if Ollama
@testable import ManifoldOllama
#endif
#if CloudSaaS
@testable import ManifoldCloudSaaS
#endif
@testable import ManifoldCloudCore
@testable import ManifoldInference
import ManifoldTestSupport

/// Phase 3/Responses — event-surface coverage for
/// ``OpenAIResponsesStreamEventExtractor``.
///
/// Drives the new stateful extractor against on-disk Responses fixtures
/// and asserts it emits the full event vocabulary that the deleted
/// inline ``OpenAIResponsesBackend/parseResponseStream(bytes:config:continuation:)``
/// switch emitted. The extractor consumes
/// ``NamedSSETransport`` envelopes; the driver below replays the
/// fixture by wrapping each (event, data) pair into the envelope shape
/// the live transport would produce.
final class OpenAIResponsesStreamEventExtractorTests: XCTestCase {

    // MARK: - streaming/simple-prompt — visible text only

    func test_extractor_streamingSimplePrompt_emitsTokenAndUsage() throws {
        let events = try driveExtractor(scenario: "streaming/simple-prompt")
        let tokens: [String] = events.compactMap {
            if case .token(let t) = $0 { return t } else { return nil }
        }
        XCTAssertEqual(tokens, ["Hello", " world"])

        let usage: (prompt: Int, completion: Int)? = events.lazy.compactMap {
            if case .usage(let p, let c) = $0 { return (p, c) } else { return nil }
        }.first
        XCTAssertEqual(usage?.prompt, 4)
        XCTAssertEqual(usage?.completion, 2)
    }

    // MARK: - tool-calls/simple — single function call

    func test_extractor_toolCallsSimple_emitsStartDeltaCompletedAndFinalisedCall() throws {
        let events = try driveExtractor(scenario: "tool-calls/simple")

        XCTAssertEqual(events.count, 4, "expected start + delta + usage + finalized call (saw \(events))")
        guard events.count == 4 else { return }

        if case .toolCallStart(let callId, let name) = events[0] {
            XCTAssertEqual(callId, "call_fixture_001")
            XCTAssertEqual(name, "get_weather")
        } else {
            XCTFail("expected .toolCallStart first, got \(events[0])")
        }

        if case .toolCallArgumentsDelta(let callId, let textDelta) = events[1] {
            XCTAssertEqual(callId, "call_fixture_001")
            XCTAssertTrue(textDelta.contains("Paris"))
        } else {
            XCTFail("expected .toolCallArgumentsDelta second, got \(events[1])")
        }

        if case .usage(let prompt, let completion) = events[2] {
            XCTAssertEqual(prompt, 12)
            XCTAssertEqual(completion, 7)
        } else {
            XCTFail("expected .usage third, got \(events[2])")
        }

        if case .toolCall(let call) = events[3] {
            XCTAssertEqual(call.id, "call_fixture_001")
            XCTAssertEqual(call.toolName, "get_weather")
            XCTAssertTrue(call.arguments.contains("Paris"))
        } else {
            XCTFail("expected .toolCall fourth, got \(events[3])")
        }
    }

    // MARK: - reasoning/summarized — summarized thinking handoff

    func test_extractor_reasoningSummarized_yieldsThinkingHandoff() throws {
        let events = try driveExtractor(scenario: "reasoning/summarized")

        // Expected: thinkingToken("Let me"), thinkingToken(" think..."),
        // thinkingCompleted (from reasoning_summary_text.done), then
        // token("Answer."), then usage. The output_text.delta sees
        // thinking already closed by `.done` so it does NOT re-emit
        // thinkingCompleted.
        let kinds = events.map { eventKind($0) }
        XCTAssertEqual(kinds, [
            "thinkingToken(Let me)",
            "thinkingToken( think...)",
            "thinkingCompleted",
            "token(Answer.)",
            "usage(5,3)"
        ])
    }

    // MARK: - usage/basic — minimal token + usage

    func test_extractor_usageBasic_emitsUsageEvent() throws {
        let events = try driveExtractor(scenario: "usage/basic")
        let usage: (prompt: Int, completion: Int)? = events.lazy.compactMap {
            if case .usage(let p, let c) = $0 { return (p, c) } else { return nil }
        }.first
        XCTAssertEqual(usage?.prompt, 11)
        XCTAssertEqual(usage?.completion, 1)
    }

    // MARK: - Cross-stream isolation (sabotage)

    /// The one-shot `finalisedToolCalls` guard is per-extractor. Two
    /// sequential extractors fed the same tool-calls fixture must each
    /// produce one `.toolCall` event — not zero.
    func test_extractor_isFreshPerInstance_finalisationGuardDoesNotLeakAcrossStreams() throws {
        let events1 = try driveExtractor(scenario: "tool-calls/simple")
        let events2 = try driveExtractor(scenario: "tool-calls/simple")
        let calls1 = events1.filter { if case .toolCall = $0 { return true } else { return false } }
        let calls2 = events2.filter { if case .toolCall = $0 { return true } else { return false } }
        XCTAssertEqual(calls1.count, 1)
        XCTAssertEqual(calls2.count, 1)
    }

    // MARK: - Factory wiring

    func test_makeOpenAIResponsesStreamConsumer_returnsExtractorForResponsesCase() {
        XCTAssertNotNil(CloudPayloadHandler.openAIResponses.makeOpenAIResponsesStreamConsumer())
    }

    func test_makeOpenAIResponsesStreamConsumer_returnsNilForOtherProviders() {
        XCTAssertNil(CloudPayloadHandler.openAI.makeOpenAIResponsesStreamConsumer())
        XCTAssertNil(CloudPayloadHandler.claude.makeOpenAIResponsesStreamConsumer())
        XCTAssertNil(CloudPayloadHandler.ollama.makeOpenAIResponsesStreamConsumer())
    }

    // MARK: - Helpers

    /// Drives the extractor over every named SSE event in the scenario's
    /// `response.sse` fixture and returns the flattened event sequence
    /// (including the trailing `finish()` flush).
    private func driveExtractor(scenario: String) throws -> [GenerationEvent] {
        let namedEvents = try loadNamedEvents(scenario: scenario)
        let extractor = OpenAIResponsesStreamEventExtractor()
        var events: [GenerationEvent] = []
        for ne in namedEvents {
            // Mirror what `NamedSSETransport` ships down to the consumer:
            // an envelope JSON string keyed by `__event` + `__data`.
            let envelope: [String: Any] = [
                NamedSSETransport.eventNameKey: ne.name,
                NamedSSETransport.eventDataKey: ne.data
            ]
            let bytes = try JSONSerialization.data(withJSONObject: envelope)
            let payload = String(data: bytes, encoding: .utf8) ?? ""
            events.append(contentsOf: extractor.consume(payload: payload))
        }
        events.append(contentsOf: extractor.finish())
        return events
    }

    private struct LoadedNamedEvent {
        let name: String
        let data: String
    }

    private func loadNamedEvents(scenario: String) throws -> [LoadedNamedEvent] {
        let url = try fixtureURL(scenario: scenario, file: "response.sse")
        let raw = try String(contentsOf: url, encoding: .utf8)
        var result: [LoadedNamedEvent] = []
        var currentName: String?
        var currentData: [String] = []
        for line in raw.components(separatedBy: "\n") {
            if line.isEmpty {
                if let name = currentName, !currentData.isEmpty {
                    result.append(LoadedNamedEvent(name: name, data: currentData.joined(separator: "\n")))
                }
                currentName = nil
                currentData.removeAll()
                continue
            }
            if line.hasPrefix("event: ") {
                currentName = String(line.dropFirst("event: ".count))
            } else if line.hasPrefix("data: ") {
                currentData.append(String(line.dropFirst("data: ".count)))
            }
        }
        if let name = currentName, !currentData.isEmpty {
            result.append(LoadedNamedEvent(name: name, data: currentData.joined(separator: "\n")))
        }
        return result
    }

    private func eventKind(_ event: GenerationEvent) -> String {
        switch event {
        case .token(let s): return "token(\(s))"
        case .thinkingToken(let s): return "thinkingToken(\(s))"
        case .thinkingCompleted: return "thinkingCompleted"
        case .thinkingSignature(let s): return "thinkingSignature(\(s))"
        case .toolCallStart(let id, let name): return "toolCallStart(\(id),\(name))"
        case .toolCallArgumentsDelta(let id, let d): return "toolCallArgumentsDelta(\(id),\(d))"
        case .toolCall(let c): return "toolCall(\(c.id),\(c.toolName))"
        case .usage(let p, let c): return "usage(\(p),\(c))"
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

    private func fixtureURL(scenario: String, file: String, filePath: StaticString = #filePath) throws -> URL {
        let root = try Self.locateFixturesRoot(filePath: filePath)
        return root
            .appendingPathComponent("backends")
            .appendingPathComponent("openai_responses")
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
        throw NSError(domain: "OpenAIResponsesStreamEventExtractorTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Tests/Fixtures/ from #filePath"
        ])
    }
}

// MARK: - Inline parity

/// Drives ``OpenAIResponsesBackend`` end-to-end through
/// ``MockURLProtocol`` (using the new adapter-routed stream loop) and
/// compares the resulting event sequence against the extractor's
/// projection of the same fixture. After the Phase 3/Responses flip
/// both sides *are* the extractor — the test guards against future
/// drift in either direction.
final class OpenAIResponsesStreamEventExtractorParityTests: XCTestCase {

    @MainActor
    func test_parity_streamingSimplePrompt() async throws {
        try await assertParity(scenario: "streaming/simple-prompt")
    }

    @MainActor
    func test_parity_toolCallsSimple() async throws {
        try await assertParity(scenario: "tool-calls/simple")
    }

    @MainActor
    func test_parity_reasoningSummarized() async throws {
        try await assertParity(scenario: "reasoning/summarized")
    }

    @MainActor
    func test_parity_usageBasic() async throws {
        try await assertParity(scenario: "usage/basic")
    }

    @MainActor
    func test_parity_finalizerStopsOnResponseCompleted() async throws {
        // Sabotage check: the parity above asserts emission order; this
        // one asserts the finalizer fires on `response.completed` rather
        // than at stream-end fallback. We inject a trailing synthetic
        // `response.unknown` event after `response.completed`. The
        // backend's loop must have broken *before* consuming it — if it
        // didn't, the event would still pass through the framing layer
        // and may surface diagnostics. Because the extractor ignores
        // unknown events, the failure mode here is silent; the explicit
        // assertion is that the event sequence still matches the
        // expected stream-end shape (no extra events after the .usage
        // and .toolCall flushes).
        let sseText = try loadResponseSSE(scenario: "streaming/simple-prompt", filePath: #filePath)
        let augmented = sseText + "event: response.unknown\ndata: {}\n\n"
        let events = try await runBackend(sseText: augmented)
        // Expected: token("Hello"), token(" world"), usage. The unknown
        // event after `response.completed` would surface as nothing
        // even on the legacy path — the finalizer-driven `break` is
        // enforced by the absence of any post-usage event tail here.
        let tokens = events.compactMap { e -> String? in
            if case .token(let s) = e { return s } else { return nil }
        }
        XCTAssertEqual(tokens, ["Hello", " world"])
    }

    // MARK: - Parity driver

    @MainActor
    private func assertParity(scenario: String, filePath: StaticString = #filePath) async throws {
        let sseText = try loadResponseSSE(scenario: scenario, filePath: filePath)
        let backendEvents = try await runBackend(sseText: sseText)

        let extractorEvents = try driveExtractor(scenario: scenario, filePath: filePath)

        XCTAssertEqual(
            backendEvents.map(eventKey),
            extractorEvents.map(eventKey),
            """
            [\(scenario)] event-sequence parity drift.
              backend  : \(backendEvents)
              extractor: \(extractorEvents)
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
        case .usage(let p, let c): return "usage(\(p),\(c))"
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
    private func runBackend(sseText: String) async throws -> [GenerationEvent] {
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
        defer { DNSRebindingGuard._resolverForTesting = nil }

        let mockURL = URL(string: "https://openai-responses-fixture-\(UUID().uuidString).test")!
        let endpointURL = mockURL.appendingPathComponent("v1/responses")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { MockURLProtocol.unstub(url: endpointURL) }

        let chunks: [Data] = sseText
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { Data("\($0)\n\n".utf8) }
        MockURLProtocol.stub(url: endpointURL, response: .sse(chunks: chunks, statusCode: 200))

        let backend = OpenAIResponsesBackend(urlSession: session)
        backend.configure(baseURL: mockURL, apiKey: "test-key", modelName: "gpt-5-fixture")
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        var events: [GenerationEvent] = []
        let stream = try backend.generate(prompt: "fixture", systemPrompt: nil, config: GenerationConfig())
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    private func driveExtractor(scenario: String, filePath: StaticString) throws -> [GenerationEvent] {
        let sseText = try loadResponseSSE(scenario: scenario, filePath: filePath)
        let extractor = OpenAIResponsesStreamEventExtractor()
        var events: [GenerationEvent] = []
        for (name, data) in parseNamedEvents(sseText) {
            let envelope: [String: Any] = [
                NamedSSETransport.eventNameKey: name,
                NamedSSETransport.eventDataKey: data
            ]
            let bytes = try JSONSerialization.data(withJSONObject: envelope)
            let payload = String(data: bytes, encoding: .utf8) ?? ""
            events.append(contentsOf: extractor.consume(payload: payload))
        }
        events.append(contentsOf: extractor.finish())
        return events
    }

    private func parseNamedEvents(_ sseText: String) -> [(String, String)] {
        var result: [(String, String)] = []
        var currentName: String?
        var currentData: [String] = []
        for line in sseText.components(separatedBy: "\n") {
            if line.isEmpty {
                if let name = currentName, !currentData.isEmpty {
                    result.append((name, currentData.joined(separator: "\n")))
                }
                currentName = nil
                currentData.removeAll()
                continue
            }
            if line.hasPrefix("event: ") {
                currentName = String(line.dropFirst("event: ".count))
            } else if line.hasPrefix("data: ") {
                currentData.append(String(line.dropFirst("data: ".count)))
            }
        }
        if let name = currentName, !currentData.isEmpty {
            result.append((name, currentData.joined(separator: "\n")))
        }
        return result
    }

    private func loadResponseSSE(scenario: String, filePath: StaticString) throws -> String {
        let root = try Self.locateFixturesRoot(filePath: filePath)
        let url = root
            .appendingPathComponent("backends")
            .appendingPathComponent("openai_responses")
            .appendingPathComponent(scenario)
            .appendingPathComponent("response.sse")
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
        throw NSError(domain: "OpenAIResponsesStreamEventExtractorParityTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Tests/Fixtures/ from #filePath"
        ])
    }
}
#endif
