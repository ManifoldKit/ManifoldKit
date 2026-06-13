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

/// Phase 2/B/iii/γ — event-surface coverage and parity for
/// ``OpenAIStreamEventExtractor``.
///
/// These tests drive the new stateful extractor against the on-disk OpenAI
/// fixtures and assert it emits the full event vocabulary that
/// ``OpenAIBackend.parseResponseStream`` emits inline today. PR #1266 (β)
/// was blocked because ``CloudPayloadHandler/openAI/extractEvents(from:)``
/// only emitted ``GenerationEvent/token(_:)``. The extractor closes that gap.
final class OpenAIStreamEventExtractorTests: XCTestCase {

    // MARK: - Streaming / simple-prompt fixture
    //
    // Existing fixture: three content deltas (the first is empty) and a
    // `finish_reason: "stop"`. We assert exactly the same token sequence
    // the inline path produces today.
    func test_extractor_streamingSimplePrompt_emitsTokenEvents() throws {
        let events = try driveExtractor(scenario: "streaming/simple-prompt")
        let tokens: [String] = events.compactMap {
            if case .token(let t) = $0 { return t } else { return nil }
        }
        XCTAssertEqual(tokens, ["", "Hello", " world"],
                       "extractor must replay the same token sequence as inline OpenAIBackend.processVisibleContent")
    }

    // MARK: - Tool-calls / simple fixture
    //
    // Single tool call, streamed in two deltas (name+id, then arguments),
    // terminated by `finish_reason: "tool_calls"`. The widened surface must
    // emit start → delta → finalized .toolCall in that order.
    func test_extractor_toolCallsSimple_emitsStartDeltaAndFinalisedCall() throws {
        let events = try driveExtractor(scenario: "tool-calls/simple")

        // Strip the `.token("")` empty-content fragment from the role-only
        // first frame so the assertion is on the tool-call shape only.
        let filtered = events.filter {
            if case .token(let t) = $0 { return !t.isEmpty }
            return true
        }

        XCTAssertEqual(filtered.count, 3, "expected start + delta + finalized call (saw \(filtered))")
        guard filtered.count == 3 else { return }

        if case .toolCallStart(let callId, let name) = filtered[0] {
            XCTAssertEqual(callId, "call_fixture_001")
            XCTAssertEqual(name, "get_weather")
        } else {
            XCTFail("expected .toolCallStart first, got \(filtered[0])")
        }

        if case .toolCallArgumentsDelta(let callId, let textDelta) = filtered[1] {
            XCTAssertEqual(callId, "call_fixture_001")
            XCTAssertTrue(textDelta.contains("Paris"))
        } else {
            XCTFail("expected .toolCallArgumentsDelta second, got \(filtered[1])")
        }

        if case .toolCall(let call) = filtered[2] {
            XCTAssertEqual(call.id, "call_fixture_001")
            XCTAssertEqual(call.toolName, "get_weather")
            XCTAssertTrue(call.arguments.contains("Paris"))
        } else {
            XCTFail("expected .toolCall third, got \(filtered[2])")
        }
    }

    // MARK: - Usage / basic fixture
    //
    // Validates that the extractor emits a `.usage` event when the
    // trailing chunk carries `usage{prompt_tokens, completion_tokens}` —
    // mirroring ``OpenAIBackend.processUsage``.
    func test_extractor_usageBasic_emitsUsageEvent() throws {
        let events = try driveExtractor(scenario: "usage/basic")
        let usage: (prompt: Int, completion: Int)? = events.lazy.compactMap {
            if case .usage(let u) = $0 { return (u.promptTokens, u.completionTokens) } else { return nil }
        }.first
        XCTAssertEqual(usage?.prompt, 12)
        XCTAssertEqual(usage?.completion, 48)
    }

    // MARK: - Reasoning / with-summary fixture (new in this PR)
    //
    // Two reasoning deltas (DeepSeek-shape `reasoning_content`), then a
    // visible content delta. Expected sequence: thinkingToken × 2,
    // thinkingCompleted (auto-closed on transition), token.
    func test_extractor_reasoningWithSummary_yieldsThinkingHandoff() throws {
        let events = try driveExtractor(scenario: "reasoning/with-summary")

        XCTAssertEqual(events.count, 4, "expected thinkingToken × 2, thinkingCompleted, token (saw \(events))")
        guard events.count == 4 else { return }

        if case .thinkingToken(let t1) = events[0] { XCTAssertEqual(t1, "Let me") }
        else { XCTFail("event[0] expected .thinkingToken, got \(events[0])") }

        if case .thinkingToken(let t2) = events[1] { XCTAssertEqual(t2, " think...") }
        else { XCTFail("event[1] expected .thinkingToken, got \(events[1])") }

        if case .thinkingCompleted = events[2] { /* ok */ }
        else { XCTFail("event[2] expected .thinkingCompleted, got \(events[2])") }

        if case .token(let visible) = events[3] { XCTAssertEqual(visible, "Answer.") }
        else { XCTFail("event[3] expected .token, got \(events[3])") }
    }

    // MARK: - Finish-reason / length-stop fixture (new in this PR)
    //
    // Two content tokens then a terminal frame carrying both `finish_reason:
    // "length"` and `usage`. The extractor should emit both tokens and the
    // usage event; no tool calls are produced because none were buffered.
    func test_extractor_finishReasonLengthStop_emitsTokensAndUsageWithoutToolCalls() throws {
        let events = try driveExtractor(scenario: "finish-reason/length-stop")

        let tokens: [String] = events.compactMap {
            if case .token(let t) = $0 { return t } else { return nil }
        }
        XCTAssertEqual(tokens, ["Once", " upon"])

        let usage: (prompt: Int, completion: Int)? = events.lazy.compactMap {
            if case .usage(let u) = $0 { return (u.promptTokens, u.completionTokens) } else { return nil }
        }.first
        XCTAssertEqual(usage?.prompt, 7)
        XCTAssertEqual(usage?.completion, 2)

        // A `finish_reason` with no buffered tool calls must not synthesise
        // phantom `.toolCall` events. This is the sabotage check: a regression
        // that fires `finaliseToolCalls()` unconditionally would fail here.
        for e in events {
            if case .toolCall = e {
                XCTFail("finish_reason 'length' must not produce a .toolCall event (\(e))")
            }
        }
    }

    // MARK: - Cross-stream isolation (sabotage)
    //
    // The one-shot `finalisedToolCalls` guard is per-extractor. Two
    // sequential extractors fed the same tool-calls fixture must each
    // produce one `.toolCall` event — not zero.
    func test_extractor_isFreshPerInstance_finalisationGuardDoesNotLeakAcrossStreams() throws {
        let events1 = try driveExtractor(scenario: "tool-calls/simple")
        let events2 = try driveExtractor(scenario: "tool-calls/simple")
        let calls1 = events1.filter { if case .toolCall = $0 { return true } else { return false } }
        let calls2 = events2.filter { if case .toolCall = $0 { return true } else { return false } }
        XCTAssertEqual(calls1.count, 1)
        XCTAssertEqual(calls2.count, 1)
    }

    // MARK: - Factory wiring

    func test_makeOpenAIStreamConsumer_returnsExtractorForOpenAICase() {
        XCTAssertNotNil(CloudPayloadHandler.openAI.makeOpenAIStreamConsumer())
    }

    func test_makeOpenAIStreamConsumer_returnsNilForOtherProviders() {
        XCTAssertNil(CloudPayloadHandler.claude.makeOpenAIStreamConsumer())
        XCTAssertNil(CloudPayloadHandler.openAIResponses.makeOpenAIStreamConsumer())
        // `.ollama` is published by ManifoldOllama; only reachable when both families build.
        XCTAssertNil(CloudPayloadHandler.ollama.makeOpenAIStreamConsumer())
    }

    // MARK: - Helpers

    /// Drives the extractor over every `data:` payload in the scenario's
    /// `response.sse` fixture and returns the flattened event sequence
    /// (including the trailing `finish()` flush).
    private func driveExtractor(scenario: String) throws -> [GenerationEvent] {
        let payloads = try loadPayloads(scenario: scenario)
        let extractor = OpenAIStreamEventExtractor()
        var events: [GenerationEvent] = []
        for payload in payloads {
            events.append(contentsOf: extractor.consume(payload: payload))
        }
        events.append(contentsOf: extractor.finish())
        return events
    }

    private func loadPayloads(scenario: String) throws -> [String] {
        let url = try fixtureURL(scenario: scenario, file: "response.sse")
        let raw = try String(contentsOf: url, encoding: .utf8)
        var payloads: [String] = []
        for line in raw.components(separatedBy: "\n") {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst("data: ".count))
            if payload == "[DONE]" { continue }
            payloads.append(payload)
        }
        return payloads
    }

    private func fixtureURL(scenario: String, file: String, filePath: StaticString = #filePath) throws -> URL {
        let root = try Self.locateFixturesRoot(filePath: filePath)
        return root
            .appendingPathComponent("backends")
            .appendingPathComponent("openai")
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
        throw NSError(domain: "OpenAIStreamEventExtractorTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Tests/Fixtures/ from #filePath"
        ])
    }
}

// MARK: - Inline parity

/// Compares the extractor's event sequence against the inline
/// ``OpenAIBackend/parseResponseStream`` path for the same SSE fixture.
///
/// Drives `OpenAIBackend` through ``MockURLProtocol`` so the inline
/// `process*` cluster executes end-to-end, captures the resulting
/// `[GenerationEvent]`, and asserts it equals the extractor's projection.
final class OpenAIStreamEventExtractorParityTests: XCTestCase {

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
    func test_parity_reasoningWithSummary() async throws {
        try await assertParity(scenario: "reasoning/with-summary")
    }

    @MainActor
    func test_parity_finishReasonLengthStop() async throws {
        try await assertParity(scenario: "finish-reason/length-stop")
    }

    // MARK: - Parity driver

    @MainActor
    private func assertParity(scenario: String, filePath: StaticString = #filePath) async throws {
        let sseText = try loadResponseSSE(scenario: scenario, filePath: filePath)
        let payloads = try parsePayloads(from: sseText)

        // Drive the new extractor.
        let extractor = OpenAIStreamEventExtractor()
        var widenedEvents: [GenerationEvent] = []
        for payload in payloads {
            widenedEvents.append(contentsOf: extractor.consume(payload: payload))
        }
        widenedEvents.append(contentsOf: extractor.finish())

        // Drive the inline backend path against the same SSE bytes.
        let inlineEvents = try await runInlineBackend(sseText: sseText)

        // Strip events the inline path emits at the SSE-framing layer but
        // that the extractor cannot see (it only consumes JSON payload
        // strings, not framing). In practice the inline OpenAI path does
        // not emit any framing-layer events for these fixtures — the two
        // sequences should be identical.
        XCTAssertEqual(
            widenedEvents.map(eventKey),
            inlineEvents.map(eventKey),
            """
            [\(scenario)] event-sequence parity drift.
              widened : \(widenedEvents)
              inline  : \(inlineEvents)
            """
        )
    }

    /// Stable key for event-sequence comparison. Captures the event kind
    /// and its primary payload so a regression that changes either is
    /// caught with a useful diff.
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
    private func runInlineBackend(sseText: String) async throws -> [GenerationEvent] {
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
        defer { DNSRebindingGuard._resolverForTesting = nil }

        let mockURL = URL(string: "https://openai-fixture-\(UUID().uuidString).test")!
        let endpointURL = mockURL.appendingPathComponent("v1/chat/completions")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { MockURLProtocol.unstub(url: endpointURL) }

        let chunks: [Data] = sseText
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { Data("\($0)\n\n".utf8) }
        MockURLProtocol.stub(url: endpointURL, response: .sse(chunks: chunks, statusCode: 200))

        let backend = OpenAIBackend(urlSession: session)
        backend.configure(baseURL: mockURL, apiKey: "test-key", modelName: "gpt-4o-mini-fixture")
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        var events: [GenerationEvent] = []
        let stream = try backend.generate(prompt: "fixture", systemPrompt: nil, config: GenerationConfig())
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    // MARK: - Fixture loading

    private func loadResponseSSE(scenario: String, filePath: StaticString) throws -> String {
        let root = try Self.locateFixturesRoot(filePath: filePath)
        let url = root
            .appendingPathComponent("backends")
            .appendingPathComponent("openai")
            .appendingPathComponent(scenario)
            .appendingPathComponent("response.sse")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func parsePayloads(from sseText: String) throws -> [String] {
        var payloads: [String] = []
        for line in sseText.components(separatedBy: "\n") {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst("data: ".count))
            if payload == "[DONE]" { continue }
            payloads.append(payload)
        }
        return payloads
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
        throw NSError(domain: "OpenAIStreamEventExtractorParityTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Tests/Fixtures/ from #filePath"
        ])
    }
}
