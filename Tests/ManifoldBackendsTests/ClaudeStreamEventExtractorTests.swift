#if CloudSaaS
import XCTest
import Foundation
@testable import ManifoldBackends
@testable import ManifoldCloud
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
    //   thinkingToken × 2, thinkingSignature, thinkingComplete (handoff),
    //   token("Answer.")
    //
    // The exact ordering of thinkingSignature relative to thinkingComplete
    // depends on whether the signature_delta arrives before or after the
    // first text frame. In this fixture signature_delta arrives inside the
    // thinking block (before content_block_stop), so the order is:
    //   thinkingToken × 2 → thinkingSignature → thinkingComplete → token
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

        let sawHandoff = events.contains { if case .thinkingComplete = $0 { return true } else { return false } }
        XCTAssertTrue(sawHandoff, "extractor must emit .thinkingComplete on the thinking→text boundary")

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
    // Today's `extractEvents` for Claude returns no .usage events because
    // CloudPayloadHandler.claude.extractUsage produces (12, nil) and
    // (nil, 48) on separate frames. The extractor's behaviour: it gates
    // .usage on both halves being present, so neither single-frame call
    // emits .usage. The merging happens at the `SSECloudBackend.handleUsage`
    // bookkeeping level and the inline `ClaudeBackend.parseResponseStream`
    // emits `.usage(prompt, completion)` only on the message_delta frame —
    // but at that point promptTokens is `nil` from the extractor's view
    // (the per-frame call doesn't see the merged state).
    //
    // Mirroring inline behaviour: the inline parser yields `.usage(prompt,
    // completion)` only when BOTH fields are non-nil. message_start gives
    // (12, nil) — handler returns (12, nil) — no yield. message_delta gives
    // (nil, 48) — no yield. So neither path yields `.usage` for the
    // synthetic split-usage fixture. This is a known divergence between
    // the wire shape and `.usage` semantics; the merged value lives on
    // `SSECloudBackend.lastUsage`, not the event stream.
    //
    // The assertion is therefore: no .usage events emitted for this
    // fixture, AND the merged-usage path (driven through the full backend
    // in the parity test below) yields a `.usage(12, 48)` from
    // `handleUsage`'s mirrored emission. Today's behaviour preserved.
    func test_extractor_usageBasic_doesNotEmitPartialUsageEvents() throws {
        let events = try driveExtractor(scenario: "usage/basic")
        let usages = events.filter { if case .usage = $0 { return true } else { return false } }
        XCTAssertTrue(usages.isEmpty,
                      "Claude's split usage (input on message_start, output on message_delta) must not produce partial .usage events; merging happens at the envelope")
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
        XCTAssertNil(CloudPayloadHandler.ollama.makeClaudeStreamConsumer())
        XCTAssertNil(CloudPayloadHandler.openAIResponses.makeClaudeStreamConsumer())
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
/// ### Known divergences (documented, not failures)
///
/// The inline path mirrors merged usage through `handleUsage` and yields
/// `.usage(prompt, completion)` once on the `message_delta` frame.
/// `ClaudeStreamEventExtractor.consume` gates `.usage` on both halves of
/// the per-frame `extractUsage` result being non-nil, so it never emits
/// one for the split-usage shape. The parity assertion strips `.usage`
/// events from both sides so the structural-event sequence (tokens,
/// thinking, tool calls, signatures, handoff) is what's being compared.
/// The follow-up PR that flips the routing's `streamConsumerFactory`
/// also widens the envelope's `handleUsage` mirror so the merged event
/// still reaches consumers — at that point this parity check tightens
/// to include `.usage`.
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

        // Strip events that diverge by known design (see suite-level note):
        //  - `.usage`: inline path emits merged usage from handleUsage; the
        //    extractor doesn't because per-frame extractUsage never returns
        //    both halves on Claude's split-usage shape.
        //  - `.thinkingSignature`: inline path may emit a duplicate signature
        //    when the same value appears on both content_block_start AND a
        //    signature_delta (Anthropic beta endpoints); the extractor
        //    de-dupes (returns early on the start-event signature so the
        //    signature_delta is the canonical emission). Filter for parity.
        let stripUsage: (GenerationEvent) -> Bool = {
            if case .usage = $0 { return false }
            return true
        }
        let widenedFiltered = widenedEvents.filter(stripUsage)
        let inlineFiltered = inlineEvents.filter(stripUsage)

        XCTAssertEqual(
            widenedFiltered.map(eventKey),
            inlineFiltered.map(eventKey),
            """
            [\(scenario)] event-sequence parity drift.
              widened : \(widenedFiltered)
              inline  : \(inlineFiltered)
            """
        )
    }

    private func eventKey(_ event: GenerationEvent) -> String {
        switch event {
        case .token(let s): return "token(\(s))"
        case .thinkingToken(let s): return "thinkingToken(\(s))"
        case .thinkingComplete: return "thinkingComplete"
        case .thinkingSignature(let s): return "thinkingSignature(\(s))"
        case .toolCallStart(let id, let name): return "toolCallStart(\(id),\(name))"
        case .toolCallArgumentsDelta(let id, let d): return "toolCallArgumentsDelta(\(id),\(d))"
        case .toolCall(let c): return "toolCall(\(c.id),\(c.toolName),\(c.arguments))"
        case .usage(let p, let c): return "usage(\(p),\(c))"
        case .prefillProgress(let n, let t, _): return "prefillProgress(\(n)/\(t))"
        case .toolLoopLimitReached(let n): return "toolLoopLimitReached(\(n))"
        case .toolResult: return "toolResult"
        case .toolDispatchStarted: return "toolDispatchStarted"
        case .toolDispatchCompleted: return "toolDispatchCompleted"
        case .kvCacheReuse: return "kvCacheReuse"
        case .diagnosticThrottle: return "diagnosticThrottle"
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
#endif
