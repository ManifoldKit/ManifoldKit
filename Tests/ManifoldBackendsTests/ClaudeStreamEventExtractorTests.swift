import XCTest
import Foundation
@testable import ManifoldFoundation
// v0.48 product split: internal symbols moved into the family targets and
// ManifoldCloudCore; the ManifoldCloud shim only re-exports public surface.
@testable import ManifoldOllama
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore
@testable import ManifoldInference
import ManifoldTestSupport

/// Phase 3/Claude — event-surface coverage and inline parity for
/// ``ClaudeStreamEventExtractor``.
///
/// These tests drive the new stateful extractor against the on-disk Claude
/// fixtures and assert it emits the full event vocabulary that
/// ``ClaudeBackend.parseResponseStream`` emits inline today. Mirrors
/// ``OpenAIStreamEventExtractorTests`` from #1272.
final class ClaudeStreamEventExtractorTests: XCTestCase {

    // MARK: - Streaming / simple-prompt

    func test_extractor_streamingSimplePrompt_emitsTokenEvents() throws {
        let events = try driveExtractor(scenario: "streaming/simple-prompt")
        let tokens: [String] = events.compactMap {
            if case .token(let t) = $0 { return t } else { return nil }
        }
        XCTAssertEqual(tokens, ["Hello", " world"],
                       "extractor must replay the same token sequence as inline ClaudeBackend")
    }

    // MARK: - Tool calls / simple
    //
    // content_block_start (tool_use) → two input_json_delta frames →
    // content_block_stop → message_stop. The extractor must emit:
    //   start → delta(fragment 1) → delta(fragment 2) → toolCall(finalized)
    func test_extractor_toolCallsSimple_emitsStartDeltaAndFinalisedCall() throws {
        let events = try driveExtractor(scenario: "tool-calls/simple")

        let toolEvents = events.filter {
            switch $0 {
            case .toolCallStart, .toolCallArgumentsDelta, .toolCall: return true
            default: return false
            }
        }

        XCTAssertEqual(toolEvents.count, 4,
                       "expected start + 2 deltas + finalized call (saw \(toolEvents))")
        guard toolEvents.count == 4 else { return }

        if case .toolCallStart(let callId, let name) = toolEvents[0] {
            XCTAssertEqual(callId, "toolu_fixture_001")
            XCTAssertEqual(name, "get_weather")
        } else {
            XCTFail("expected .toolCallStart first, got \(toolEvents[0])")
        }

        if case .toolCallArgumentsDelta(let callId, let textDelta) = toolEvents[1] {
            XCTAssertEqual(callId, "toolu_fixture_001")
            XCTAssertTrue(textDelta.contains("city"))
        } else {
            XCTFail("expected first .toolCallArgumentsDelta, got \(toolEvents[1])")
        }

        if case .toolCallArgumentsDelta(let callId, let textDelta) = toolEvents[2] {
            XCTAssertEqual(callId, "toolu_fixture_001")
            XCTAssertTrue(textDelta.contains("Paris"))
        } else {
            XCTFail("expected second .toolCallArgumentsDelta, got \(toolEvents[2])")
        }

        if case .toolCall(let call) = toolEvents[3] {
            XCTAssertEqual(call.id, "toolu_fixture_001")
            XCTAssertEqual(call.toolName, "get_weather")
            XCTAssertTrue(call.arguments.contains("Paris"))
        } else {
            XCTFail("expected .toolCall third, got \(toolEvents[3])")
        }
    }

    // MARK: - Thinking / with-signature
    //
    // thinking block: two thinking_delta + signature_delta + content_block_stop,
    // then a text block with one text_delta. Required events:
    //   thinkingToken × 2, thinkingSignature, thinkingCompleted (handoff),
    //   token("Answer.")
    //
    // The exact ordering of thinkingSignature relative to thinkingCompleted
    // depends on whether the signature_delta arrives before or after the
    // first text frame. In this fixture signature_delta arrives inside the
    // thinking block (before content_block_stop), so the order is:
    //   thinkingToken × 2 → thinkingSignature → thinkingCompleted → token
    func test_extractor_thinkingWithSignature_yieldsHandoffAndSignature() throws {
        let events = try driveExtractor(scenario: "thinking/with-signature")

        let thinkingTokens = events.compactMap { event -> String? in
            if case .thinkingToken(let t) = event { return t } else { return nil }
        }
        XCTAssertEqual(thinkingTokens, ["Let me", " think..."])

        let signatures = events.compactMap { event -> String? in
            if case .thinkingSignature(let s) = event { return s } else { return nil }
        }
        XCTAssertEqual(signatures, ["sig_opaque_abc123"],
                       "Anthropic signatures must round-trip verbatim — multi-turn replay is rejected if dropped")

        let sawHandoff = events.contains { if case .thinkingCompleted = $0 { return true } else { return false } }
        XCTAssertTrue(sawHandoff, "extractor must emit .thinkingCompleted on the thinking→text boundary")

        let tokens = events.compactMap { event -> String? in
            if case .token(let t) = event { return t } else { return nil }
        }
        XCTAssertEqual(tokens, ["Answer."])
    }

    // MARK: - Usage / basic
    //
    // Claude splits usage across `message_start` (input_tokens) and
    // `message_delta` (output_tokens). The extractor merges them and emits
    // `.usage` only when both halves are positive — the OpenAI extractor's
    // contract.
    //
    // The extractor merges split usage internally: it stashes the prompt
    // half from `message_start` and emits a single `.usage(TokenUsage)` event when the completion half lands on
    // `message_delta`. This matches what the inline parser used to do via
    // `SSECloudBackend.handleUsage`'s bookkeeping — the merged value now
    // reaches consumers as an event, not just as `lastUsage` state.
    func test_extractor_usageBasic_emitsMergedUsageOnce() throws {
        let events = try driveExtractor(scenario: "usage/basic")
        let usages: [(Int, Int)] = events.compactMap { event in
            if case .usage(let u) = event { return (u.promptTokens, u.completionTokens) } else { return nil }
        }
        XCTAssertEqual(usages.count, 1, "expected exactly one merged .usage event, saw \(usages)")
        XCTAssertEqual(usages.first?.0, 12, "prompt tokens from message_start")
        XCTAssertEqual(usages.first?.1, 48, "completion tokens from message_delta")
    }

    // MARK: - Cross-stream isolation

    func test_extractor_isFreshPerInstance_finalisationGuardDoesNotLeakAcrossStreams() throws {
        let events1 = try driveExtractor(scenario: "tool-calls/simple")
        let events2 = try driveExtractor(scenario: "tool-calls/simple")
        let calls1 = events1.filter { if case .toolCall = $0 { return true } else { return false } }
        let calls2 = events2.filter { if case .toolCall = $0 { return true } else { return false } }
        XCTAssertEqual(calls1.count, 1)
        XCTAssertEqual(calls2.count, 1)
    }

    // MARK: - Factory wiring

    func test_makeClaudeStreamConsumer_returnsExtractorForClaudeCase() {
        XCTAssertNotNil(CloudPayloadHandler.claude.makeClaudeStreamConsumer())
    }

    func test_makeClaudeStreamConsumer_returnsNilForOtherProviders() {
        XCTAssertNil(CloudPayloadHandler.openAI.makeClaudeStreamConsumer())
        XCTAssertNil(CloudPayloadHandler.openAIResponses.makeClaudeStreamConsumer())
        // `.ollama` is published by ManifoldOllama; only reachable when both families build.
        XCTAssertNil(CloudPayloadHandler.ollama.makeClaudeStreamConsumer())
    }

    // MARK: - Sabotage: cancellation suppresses tool finalisation

    func test_extractor_cancelledFinish_suppressesPendingToolCalls() throws {
        let payloads = try loadPayloads(scenario: "tool-calls/simple")
        let extractor = ClaudeStreamEventExtractor()
        var events: [GenerationEvent] = []
        // Drive only the first 3 payloads: message_start + content_block_start
        // + first input_json_delta. The call is buffered but not yet
        // finalised by `content_block_stop`.
        for payload in payloads.prefix(3) {
            events.append(contentsOf: extractor.consume(payload: payload))
        }
        events.append(contentsOf: extractor.finish(cancelled: true))
        let calls = events.filter { if case .toolCall = $0 { return true } else { return false } }
        XCTAssertTrue(calls.isEmpty,
                      "cancelled finish must suppress phantom tool-call emission for partially-streamed calls")
    }

    // MARK: - Helpers

    private func driveExtractor(scenario: String) throws -> [GenerationEvent] {
        let payloads = try loadPayloads(scenario: scenario)
        let extractor = ClaudeStreamEventExtractor()
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
            .appendingPathComponent("claude")
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
        throw NSError(domain: "ClaudeStreamEventExtractorTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Tests/Fixtures/ from #filePath"
        ])
    }
}

// MARK: - Inline parity

/// Compares the extractor's event sequence against the inline
/// ``ClaudeBackend/parseResponseStream`` path for the same SSE fixture.
///
/// Mirrors ``OpenAIStreamEventExtractorParityTests``: drives the live
/// backend through ``MockURLProtocol``, captures the event stream, and
/// asserts the extractor's projection matches one-for-one.
///
/// ### Parity scope
///
/// After the Phase 3/Claude flip, `ClaudeBackend` drives its stream
/// through `CloudRoutedStreamParser` with the
/// extractor as the `streamConsumerFactory`. The "inline" side of this
/// parity test therefore exercises the same extractor under the
/// envelope (lifecycle, `finish(cancelled:)` flush from the envelope
/// epilogue, finalizer-driven termination), while the "widened" side
/// drives the extractor directly. Equality across the full event
/// sequence — including `.usage` — confirms the envelope's adaptation
/// matches the extractor's surface 1:1.
final class ClaudeStreamEventExtractorParityTests: XCTestCase {

    @MainActor
    func test_parity_streamingSimplePrompt() async throws {
        try await assertParity(scenario: "streaming/simple-prompt")
    }

    @MainActor
    func test_parity_toolCallsSimple() async throws {
        try await assertParity(scenario: "tool-calls/simple")
    }

    @MainActor
    func test_parity_thinkingWithSignature() async throws {
        try await assertParity(scenario: "thinking/with-signature")
    }

    @MainActor
    func test_parity_usageBasic() async throws {
        try await assertParity(scenario: "usage/basic")
    }

    @MainActor
    func test_parity_freshExtractorPerStream() async throws {
        // Sabotage check: drive the parity twice on the same extractor type
        // factory and confirm tool-call counts stay 1-per-stream.
        try await assertParity(scenario: "tool-calls/simple")
        try await assertParity(scenario: "tool-calls/simple")
    }

    // MARK: - Parity driver

    @MainActor
    private func assertParity(scenario: String, filePath: StaticString = #filePath) async throws {
        let sseText = try loadResponseSSE(scenario: scenario, filePath: filePath)
        let payloads = try parsePayloads(from: sseText)

        let extractor = ClaudeStreamEventExtractor()
        var widenedEvents: [GenerationEvent] = []
        for payload in payloads {
            widenedEvents.append(contentsOf: extractor.consume(payload: payload))
        }
        widenedEvents.append(contentsOf: extractor.finish())

        let inlineEvents = try await runInlineBackend(sseText: sseText)

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
        case .promptRendered: return "promptRendered"
        case .toolIterationLimitExceeded(let n): return "toolIterationLimitExceeded(\(n))"
        case .runTokenBudgetExceeded(let used, let limit): return "runTokenBudgetExceeded(\(used)/\(limit))"
        case .toolResult: return "toolResult"
        case .toolProgress: return "toolProgress"
        case .toolDispatchStarted: return "toolDispatchStarted"
        case .toolDispatchCompleted: return "toolDispatchCompleted"
        case .toolCallApproved: return "toolCallApproved"
        case .kvCacheReuse: return "kvCacheReuse"
        case .throttleDiagnostic: return "throttleDiagnostic"
        case .toolCallParseFailed(let body): return "toolCallParseFailed(\(body))"
        case .toolCallTruncated(let body): return "toolCallTruncated(\(body))"
        case .handoffRequested(let h): return "handoffRequested(\(h.targetAgentID))"
        case .generationCompleted(let c): return "generationCompleted(\(c.reason))"
        }
    }

    @MainActor
    private func runInlineBackend(sseText: String) async throws -> [GenerationEvent] {
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
        defer { DNSRebindingGuard._resolverForTesting = nil }

        let mockURL = URL(string: "https://claude-fixture-\(UUID().uuidString).test")!
        let endpointURL = mockURL.appendingPathComponent("v1/messages")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { MockURLProtocol.unstub(url: endpointURL) }

        let chunks: [Data] = sseText
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { Data("\($0)\n\n".utf8) }
        MockURLProtocol.stub(url: endpointURL, response: .sse(chunks: chunks, statusCode: 200))

        let backend = ClaudeBackend(urlSession: session)
        backend.configure(baseURL: mockURL, apiKey: "test-key", modelName: "claude-sonnet-fixture")
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
            .appendingPathComponent("claude")
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
        throw NSError(domain: "ClaudeStreamEventExtractorParityTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Tests/Fixtures/ from #filePath"
        ])
    }
}
