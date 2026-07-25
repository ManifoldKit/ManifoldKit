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

/// Event-shape contract tests for ``OllamaBackend`` tool calling (PR #783 +
/// #435 + #436 cross-cutting bundle).
///
/// Sister file: ``OllamaToolCallingTests`` covers wire-format basics
/// (`tools[]` array, `tool_choice` mapping, multi-call parsing,
/// arguments-object normalisation, tool-aware history shape). This file
/// adds the cross-backend event triple, capability flags, callId stability,
/// and the cancellation contract that landed alongside OpenAI / Claude
/// rollouts.
///
/// Coverage:
/// - Capability flags: `streamsToolCallArguments == false`,
///   `supportsParallelToolCalls == true`.
/// - Whole-call streaming emits start + single arguments-delta + toolCall
///   triple per entry, in array order.
/// - Synthesized callId is non-empty and stable across a single call's
///   start/delta/toolCall triple when Ollama omits `id`.
/// - Cancelling the consumer mid-stream suppresses post-cancel `.toolCall`
///   emissions.
@MainActor
final class OllamaBackendToolCallingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
    }

    override func tearDown() {
        DNSRebindingGuard._resolverForTesting = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeBackend() -> (OllamaBackend, chatURL: URL) {
        let session = makeMockSession()
        let backend = OllamaBackend(urlSession: session)
        let baseURL = URL(string: "http://ollama-tools-events-\(UUID().uuidString).test")!
        backend.configure(baseURL: baseURL, modelName: "llama3.2")
        return (backend, baseURL.appendingPathComponent("api/chat"))
    }

    private func loadBackend(_ backend: OllamaBackend) async throws {
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
    }

    private func ndjsonLine(_ json: String) -> Data {
        Data("\(json)\n".utf8)
    }

    private func drain(_ stream: GenerationStream) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    // MARK: - Capability flags

    func test_capabilities_advertiseWholeCallStreamingAndParallelCalls() {
        let caps = OllamaBackend().capabilities
        XCTAssertTrue(caps.supportsToolCalling, "Ollama supports tool calling via /api/chat")
        XCTAssertFalse(
            caps.streamsToolCallArguments,
            "Ollama emits whole tool calls per NDJSON line — not incremental fragments"
        )
        XCTAssertTrue(
            caps.supportsParallelToolCalls,
            "Ollama can return multiple tool_calls[] entries in a single assistant message"
        )
    }

    // MARK: - Event-triple shape

    /// Whole-call streaming: every tool_calls[] entry on a single NDJSON line
    /// surfaces as `.toolCallStart` → single `.toolCallArgumentsDelta` →
    /// `.toolCall`, in array order. Keeps consumers on a single code path
    /// regardless of whether the underlying transport streams arguments.
    func test_streaming_wholeCall_emitsStartDeltaToolCallTriple_perEntry() async throws {
        let (backend, chatURL) = makeBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"""
            {"model":"llama3.2","message":{"role":"assistant","content":"","tool_calls":[{"id":"call-a","type":"function","function":{"name":"fetch_a","arguments":"{\"q\":\"x\"}"}},{"id":"call-b","type":"function","function":{"name":"fetch_b","arguments":"{}"}}]},"done":false}
            """#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "go", systemPrompt: nil, config: GenerationConfig())
        let events = try await drain(stream)

        // Sabotage check: replace `call.id` with `""` in
        // OllamaBackend.parseResponseStream — the start-event id assertion
        // below fails because callId becomes empty.
        let starts = events.compactMap { event -> (id: String, name: String)? in
            if case .toolCallStart(let id, let name) = event { return (id, name) }
            return nil
        }
        XCTAssertEqual(starts.count, 2, "two start events, one per tool call, in array order")
        XCTAssertEqual(starts[0].id, "call-a")
        XCTAssertEqual(starts[0].name, "fetch_a")
        XCTAssertEqual(starts[1].id, "call-b")
        XCTAssertEqual(starts[1].name, "fetch_b")
        XCTAssertFalse(starts[0].id.isEmpty, "callId contract: non-empty")
        XCTAssertFalse(starts[1].id.isEmpty, "callId contract: non-empty")

        // One delta per call carrying the full arguments string. Empty
        // arguments may produce a single delta carrying `"{}"` — the wire
        // shape preserves whatever the model emitted.
        var deltasById: [String: [String]] = [:]
        for event in events {
            if case .toolCallArgumentsDelta(let id, let frag) = event {
                deltasById[id, default: []].append(frag)
            }
        }
        XCTAssertEqual(deltasById["call-a"]?.count, 1, "one delta per whole call")
        XCTAssertEqual(deltasById["call-a"]?.first, #"{"q":"x"}"#)
        XCTAssertEqual(deltasById["call-b"]?.count, 1, "one delta per whole call")
        XCTAssertEqual(deltasById["call-b"]?.first, "{}")

        let toolCalls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let c) = event { return c } else { return nil }
        }
        XCTAssertEqual(toolCalls.count, 2)
        XCTAssertEqual(toolCalls[0].id, "call-a")
        XCTAssertEqual(toolCalls[0].toolName, "fetch_a")
        XCTAssertEqual(toolCalls[0].arguments, #"{"q":"x"}"#)
        XCTAssertEqual(toolCalls[1].id, "call-b")
        XCTAssertEqual(toolCalls[1].toolName, "fetch_b")
        XCTAssertEqual(toolCalls[1].arguments, "{}")
    }

    /// Per-entry triple ordering: the events for each call must arrive
    /// adjacent and in start → delta → toolCall order. The orchestrator
    /// relies on this to match deltas to the in-flight call.
    func test_streaming_eventTripleOrdering_perCall() async throws {
        let (backend, chatURL) = makeBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"""
            {"model":"llama3.2","message":{"role":"assistant","content":"","tool_calls":[{"id":"only","type":"function","function":{"name":"thing","arguments":"{\"k\":1}"}}]},"done":false}
            """#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "go", systemPrompt: nil, config: GenerationConfig())
        let events = try await drain(stream)

        // Find the indices of the three events for callId "only".
        var startIdx: Int?
        var deltaIdx: Int?
        var callIdx: Int?
        for (idx, event) in events.enumerated() {
            switch event {
            case .toolCallStart(let id, _) where id == "only":
                if startIdx == nil { startIdx = idx }
            case .toolCallArgumentsDelta(let id, _) where id == "only":
                if deltaIdx == nil { deltaIdx = idx }
            case .toolCall(let call) where call.id == "only":
                if callIdx == nil { callIdx = idx }
            default:
                break
            }
        }
        let s = try XCTUnwrap(startIdx)
        let d = try XCTUnwrap(deltaIdx)
        let c = try XCTUnwrap(callIdx)
        XCTAssertLessThan(s, d, "start must precede delta")
        XCTAssertLessThan(d, c, "delta must precede toolCall")
    }

    // MARK: - Synthesized callId stability

    /// When Ollama omits `id` (some 0.3.x builds), the backend synthesises a
    /// non-empty placeholder. Within a single call's start/delta/toolCall
    /// triple, the synthesised id MUST be the same value — otherwise the
    /// orchestrator can't pair the result with the call.
    func test_streaming_synthesizedCallId_isStableAcrossTriple() async throws {
        let (backend, chatURL) = makeBackend()
        try await loadBackend(backend)

        // Note: no `id` field on the tool_call entry.
        let chunks: [Data] = [
            ndjsonLine(#"""
            {"model":"llama3.2","message":{"role":"assistant","content":"","tool_calls":[{"type":"function","function":{"name":"no_id_call","arguments":"{\"x\":1}"}}]},"done":false}
            """#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "go", systemPrompt: nil, config: GenerationConfig())
        let events = try await drain(stream)

        let startId: String? = events.lazy.compactMap { event -> String? in
            if case .toolCallStart(let id, _) = event { return id } else { return nil }
        }.first
        let deltaId: String? = events.lazy.compactMap { event -> String? in
            if case .toolCallArgumentsDelta(let id, _) = event { return id } else { return nil }
        }.first
        let toolCallId: String? = events.lazy.compactMap { event -> String? in
            if case .toolCall(let c) = event { return c.id } else { return nil }
        }.first

        let s = try XCTUnwrap(startId)
        let d = try XCTUnwrap(deltaId)
        let t = try XCTUnwrap(toolCallId)

        XCTAssertFalse(s.isEmpty, "synthesised callId must be non-empty (sabotage: replace synth with \"\")")
        XCTAssertEqual(s, d, "start.callId must match delta.callId for the same entry")
        XCTAssertEqual(d, t, "delta.callId must match toolCall.id for the same entry")
        // The convention used by the backend is the `ollama-<name>-` prefix
        // (matches the MLX tool markers). Stricter than required by contract,
        // but pinning prevents accidental id-scheme drift.
        XCTAssertTrue(s.hasPrefix("ollama-no_id_call-"), "synth id should follow ollama-<name>-<token> convention; got \(s)")
    }

    /// Two distinct entries with omitted ids must each get their own non-empty
    /// id, and the ids must differ — otherwise the orchestrator would pair
    /// both results to one call.
    func test_streaming_synthesizedCallIds_areDistinctBetweenEntries() async throws {
        let (backend, chatURL) = makeBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(#"""
            {"model":"llama3.2","message":{"role":"assistant","content":"","tool_calls":[{"type":"function","function":{"name":"alpha","arguments":"{}"}},{"type":"function","function":{"name":"beta","arguments":"{}"}}]},"done":false}
            """#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(url: chatURL, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "go", systemPrompt: nil, config: GenerationConfig())
        let events = try await drain(stream)

        let starts = events.compactMap { event -> (id: String, name: String)? in
            if case .toolCallStart(let id, let name) = event { return (id, name) }
            return nil
        }
        XCTAssertEqual(starts.count, 2)
        XCTAssertNotEqual(
            starts[0].id, starts[1].id,
            "distinct entries must get distinct synthesised ids"
        )
        XCTAssertFalse(starts[0].id.isEmpty)
        XCTAssertFalse(starts[1].id.isEmpty)
    }

    // MARK: - Cancellation contract

    /// Drop the consumer mid-stream before the tool_calls NDJSON line lands.
    /// No `.toolCall` event must fire after cancellation — otherwise the
    /// orchestrator double-dispatches a tool the user already abandoned.
    func test_cancellation_midStream_doesNotEmitToolCallAfterStop() async throws {
        let (backend, chatURL) = makeBackend()
        try await loadBackend(backend)

        // First chunk is plain content so we can observe one event before
        // cancelling. Second chunk would carry the tool_calls payload — it
        // arrives after the consumer has stopped, so the .toolCall must
        // never surface.
        let chunks: [Data] = [
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"thinking..."},"done":false}"#),
            ndjsonLine(#"""
            {"model":"llama3.2","message":{"role":"assistant","content":"","tool_calls":[{"id":"late","type":"function","function":{"name":"wont_run","arguments":"{}"}}]},"done":false}
            """#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(
            url: chatURL,
            response: .asyncSSE(chunks: chunks, chunkDelay: 0.030, statusCode: 200)
        )
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "go", systemPrompt: nil, config: GenerationConfig())

        var observed: [GenerationEvent] = []
        let task = Task<Void, Error> {
            for try await event in stream.events {
                observed.append(event)
                if observed.count >= 1 {
                    backend.stopGeneration()
                    break
                }
            }
        }
        do {
            try await task.value
        } catch is CancellationError {
            // Expected on cancellation
        } catch {
            // Cancellation may also surface as a clean stream end
        }

        let toolCalls = observed.compactMap { event -> ToolCall? in
            if case .toolCall(let c) = event { return c } else { return nil }
        }
        XCTAssertTrue(
            toolCalls.isEmpty,
            "no .toolCall event must fire after the consumer cancels the stream"
        )
    }

    /// Mid-line cancellation contract (regression for #972).
    ///
    /// PR #970 decomposed `handleLine` into `processToolCalls` →
    /// `processThinking` → `processContent`. The original single-method form
    /// caught `Task.isCancelled` mid-loop with `return`, which exited
    /// `handleLine` entirely. After the split, that bare `return` exited
    /// only the helper, so any thinking/content fields on the SAME NDJSON
    /// line still fired post-cancel.
    ///
    /// This test drives a single line carrying many tool_calls plus
    /// thinking and content fields, cancels the producer task while it is
    /// iterating tool_calls, and asserts that no `.thinkingToken` /
    /// `.token` events surface after the cancellation point.
    func test_cancellation_midLine_doesNotEmitThinkingOrContentAfterStop() async throws {
        // Build a single NDJSON line carrying many tool_calls plus thinking
        // and content fields. The high call count widens the in-loop
        // cancellation window so the producer reliably observes
        // `Task.isCancelled` partway through `processToolCalls`.
        let callCount = 64
        let toolCallsJSON = (0..<callCount).map { i in
            #"{"id":"call-\#(i)","type":"function","function":{"name":"f_\#(i)","arguments":"{}"}}"#
        }.joined(separator: ",")
        let bigLine = #"""
        {"model":"llama3.2","message":{"role":"assistant","thinking":"LEAKED_THINKING","content":"LEAKED_CONTENT","tool_calls":[\#(toolCallsJSON)]},"done":false}
        """#

        let (backend, chatURL) = makeBackend()
        try await loadBackend(backend)

        let chunks: [Data] = [
            ndjsonLine(bigLine),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true}"#),
        ]
        MockURLProtocol.stub(
            url: chatURL,
            response: .asyncSSE(chunks: chunks, chunkDelay: 0.030, statusCode: 200)
        )
        defer { MockURLProtocol.unstub(url: chatURL) }

        let stream = try backend.generate(prompt: "go", systemPrompt: nil, config: GenerationConfig())

        var observed: [GenerationEvent] = []
        let task = Task<Void, Error> {
            for try await event in stream.events {
                observed.append(event)
                // Cancel the producer the moment the first tool_call event
                // surfaces. The producer is mid-`processToolCalls` for the
                // big line; with #972's fix it bails out of `handleLine`,
                // so subsequent thinking/content fields on the same line
                // never reach the consumer.
                if case .toolCallStart = event {
                    backend.stopGeneration()
                }
            }
        }
        do {
            try await task.value
        } catch is CancellationError {
            // Expected on cancellation
        } catch {
            // Cancellation may also surface as a clean stream end
        }

        let leakedThinking = observed.contains { event in
            if case .thinkingToken(let text) = event { return text.contains("LEAKED_THINKING") }
            return false
        }
        let leakedContent = observed.contains { event in
            if case .token(let text) = event { return text.contains("LEAKED_CONTENT") }
            return false
        }
        XCTAssertFalse(
            leakedThinking,
            "no .thinkingToken event must fire from the same line after cancellation interrupts processToolCalls"
        )
        XCTAssertFalse(
            leakedContent,
            "no .token event must fire from the same line after cancellation interrupts processToolCalls"
        )
    }

    // MARK: - #2376: tool-continuation stall must terminate, not hang forever

    /// `OllamaBackend` must ship a non-nil default `streamIdleTimeout` so a
    /// stalled generation — the tool-continuation request that never
    /// produces a byte, observed in #2376 — has SOME application-level
    /// bound short of `defaultRequestIdleTimeout`'s 30 minutes. Before the
    /// fix this property was left `nil` (the `SSECloudBackend` default),
    /// disabling `GenerationStream`'s idle-timeout gate entirely.
    ///
    /// Sabotage check: comment out the `streamIdleTimeout = ...` assignment
    /// in `OllamaBackend.init` — this assertion fails because the property
    /// reads `nil` again.
    func test_defaultStreamIdleTimeout_isNonNilAndBounded() {
        let backend = OllamaBackend()
        let timeout = backend.streamIdleTimeout
        XCTAssertNotNil(timeout, "#2376: a stalled Ollama generation must have a bounded application-level timeout, not rely solely on the 30-minute requestIdleTimeout")
        if let timeout {
            XCTAssertLessThan(
                timeout,
                .seconds(OllamaBackend.defaultRequestIdleTimeout),
                "streamIdleTimeout must be strictly tighter than the 30-minute HTTP-layer requestIdleTimeout to give a meaningfully earlier, visible failure"
            )
        }
    }

    /// End-to-end tool round trip: turn 1 gets a tool call, the (synthesised)
    /// tool result is threaded into turn 2's history exactly as
    /// `GenerationToolDispatchLoop` would, and turn 2's connection stalls
    /// (never delivers a single byte) — modelling the exact silent hang from
    /// #2376's observed log trace. With a bounded `streamIdleTimeout` the
    /// second `generate()` call must throw `InferenceError.idleTimeout`
    /// well before the stub's artificial delay elapses, rather than hang.
    ///
    /// Sabotage check performed manually: setting
    /// `backend.streamIdleTimeout = nil` right after construction (reverting
    /// to the pre-fix default) makes this test hang until the harness's own
    /// timeout kills it — confirmed by running with a 2s stub delay and a
    /// `nil` override, which never completes within the 10s per-test guard
    /// below and has to be killed. Restoring the override makes it pass in
    /// well under 1s.
    func test_toolContinuation_stalledSecondTurn_terminatesWithVisibleError() async throws {
        let (backend, chatURL) = makeBackend()
        try await loadBackend(backend)

        // Tight enough that the test runs fast; long enough to be
        // meaningfully distinguishable from immediate delivery.
        backend.streamIdleTimeout = .milliseconds(300)

        // Turn 1: the model calls `fakeRateLimited`.
        let turn1Chunks: [Data] = [
            ndjsonLine(#"""
            {"model":"llama3.2","message":{"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"fakeRateLimited","arguments":"{}"}}]},"done":false}
            """#),
            ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":""},"done":true,"prompt_eval_count":10,"eval_count":5}"#),
        ]
        MockURLProtocol.stubSequence(url: chatURL, responses: [
            .sse(chunks: turn1Chunks, statusCode: 200),
            // Turn 2: connection "opens" (no error) but never delivers a
            // byte within the test's lifetime — the exact shape of #2376's
            // silent stall. `firstByteDelay` is deliberately far longer than
            // `streamIdleTimeout` above so a pass proves the *timeout* fired,
            // not that the stub happened to resolve fast.
            .delayedFirstByte(
                data: ndjsonLine(#"{"model":"llama3.2","message":{"role":"assistant","content":"ok"},"done":true}"#),
                firstByteDelay: 5.0,
                statusCode: 200
            ),
        ])
        defer { MockURLProtocol.unstub(url: chatURL) }

        let toolConfig = GenerationConfig(tools: [
            ToolDefinition(name: "fakeRateLimited", description: "test", parameters: .object([:])),
        ])

        // Turn 1.
        let stream1 = try backend.generate(prompt: "go", systemPrompt: nil, config: toolConfig)
        let events1 = try await drain(stream1)
        let call = try XCTUnwrap(events1.compactMap { event -> ToolCall? in
            if case .toolCall(let c) = event { return c }
            return nil
        }.first)

        // Thread the call + a synthesised result into history exactly as
        // `GenerationToolDispatchLoop.runLoop` does (#2312/#1909).
        let history: [StructuredMessage] = [
            StructuredMessage(role: "user", content: "go"),
            StructuredMessage(role: "assistant", parts: [.toolCall(call)]),
            StructuredMessage(role: "tool", parts: [
                .toolResult(ToolResult(callId: call.id, content: "{\"ok\":true}", errorKind: nil)),
            ]),
        ]

        // Turn 2 — this is the request that stalls.
        let start = ContinuousClock.now
        let stream2 = try backend.generate(
            prompt: "",
            systemPrompt: nil,
            config: toolConfig,
            hints: GenerationRuntimeHints(history: history)
        )

        do {
            _ = try await drain(stream2)
            XCTFail("expected InferenceError.idleTimeout — the stalled turn must not complete silently")
        } catch let error as InferenceError {
            guard case .idleTimeout = error else {
                XCTFail("expected .idleTimeout, got \(error)")
                return
            }
        } catch {
            XCTFail("expected InferenceError.idleTimeout, got \(type(of: error)): \(error)")
        }

        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(
            elapsed,
            .seconds(2),
            "the timeout must fire on its own bound, well before the stub's 5s artificial stall — a value close to 5s would mean the stub resolved instead of the timeout firing"
        )
    }
}
