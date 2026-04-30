import XCTest
@testable import BaseChatInference
import BaseChatTestSupport

/// Streaming event-contract tests for tool calls (documented in PR #853).
///
/// These tests drive a ``MockInferenceBackend`` with scripted event sequences
/// and assert ordering, content, and edge-case behaviour — all without hitting
/// real network or hardware. They complement the existing ``ToolCallContractTests``
/// (Codable round-trips, non-streaming emission) and ``GenerationCoordinatorToolLoopTests``
/// (orchestrator dispatch loop). Coverage here focuses exclusively on the
/// streaming-event contract: ordering of start/delta/call, non-streaming
/// back-compat, cancellation, and interleaved multi-call sequencing.
@MainActor
final class ToolCallStreamingContractTests: XCTestCase {

    // MARK: - Fixtures

    private var provider: FakeGenerationContextProvider!

    override func setUp() async throws {
        try await super.setUp()
        provider = FakeGenerationContextProvider()
    }

    override func tearDown() async throws {
        provider = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Drain all events from a ``GenerationStream`` into an array.
    private func collectEvents(_ stream: GenerationStream) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    /// Build a streaming-capable ``MockInferenceBackend`` and load it.
    private func makeStreamingBackend() throws -> MockInferenceBackend {
        let backend = MockInferenceBackend(
            capabilities: BackendCapabilities(
                supportedParameters: [.temperature],
                maxContextTokens: 4096,
                supportsToolCalling: true,
                streamsToolCallArguments: true
            )
        )
        backend.isModelLoaded = true
        return backend
    }

    /// Build a non-streaming ``MockInferenceBackend`` and load it.
    private func makeNonStreamingBackend() throws -> MockInferenceBackend {
        let backend = MockInferenceBackend(
            capabilities: BackendCapabilities(
                supportedParameters: [.temperature],
                maxContextTokens: 4096,
                supportsToolCalling: true,
                streamsToolCallArguments: false
            )
        )
        backend.isModelLoaded = true
        return backend
    }

    // MARK: - 1. Streaming backend: start → deltas → call

    /// Contract: a streaming backend emits `.toolCallStart` first, then one or
    /// more `.toolCallArgumentsDelta` events, and finally `.toolCall` whose
    /// `arguments` equals the concatenation of all delta strings.
    func test_streamingBackend_emitsStartBeforeCall_andDeltasBetween() async throws {
        let backend = try makeStreamingBackend()
        let call = ToolCall(id: "c1", toolName: "get_weather", arguments: #"{"city":"Paris"}"#)

        backend.scriptedToolCallDeltasPerTurn = [[
            .start(callId: "c1", name: "get_weather"),
            .delta(callId: "c1", textDelta: #"{"city":"#),
            .delta(callId: "c1", textDelta: #""Paris"}"#),
            .call(call),
        ]]

        let stream = try backend.generate(prompt: "weather?", systemPrompt: nil, config: .init())
        let events = try await collectEvents(stream)

        // Filter to the tool-call family.
        let toolEvents = events.filter {
            switch $0 {
            case .toolCallStart, .toolCallArgumentsDelta, .toolCall: return true
            default: return false
            }
        }

        // Ordering: start must be first, call must be last.
        guard toolEvents.count == 4 else {
            XCTFail("Expected 4 tool events (start + 2 deltas + call), got \(toolEvents.count)")
            return
        }
        if case .toolCallStart(let id, let name) = toolEvents[0] {
            XCTAssertEqual(id, "c1")
            XCTAssertEqual(name, "get_weather")
        } else {
            XCTFail("First tool event must be .toolCallStart, got \(toolEvents[0])")
        }

        var deltaStrings: [String] = []
        for event in toolEvents.dropFirst().dropLast() {
            if case .toolCallArgumentsDelta(let id, let text) = event {
                XCTAssertEqual(id, "c1")
                deltaStrings.append(text)
            } else {
                XCTFail("Middle tool events must be .toolCallArgumentsDelta, got \(event)")
            }
        }

        if case .toolCall(let received) = toolEvents.last {
            // Authoritative arguments must equal the full concatenated deltas.
            let concatenated = deltaStrings.joined()
            XCTAssertEqual(received.arguments, concatenated,
                "toolCall.arguments must equal the concatenation of all delta strings")
            XCTAssertEqual(received.id, "c1")
        } else {
            XCTFail("Last tool event must be .toolCall")
        }

        // Sabotage: swapping the emission order in MockInferenceBackend.generate (emitting
        // .call before .start) would make toolEvents[0] a .toolCall — the guard above fails.
    }

    // MARK: - 2. Non-streaming backend: only .toolCall, no start or deltas

    /// Contract: a backend with `streamsToolCallArguments == false` emits only
    /// `.toolCall` — no `.toolCallStart` or `.toolCallArgumentsDelta` events.
    func test_nonStreamingBackend_emitsToolCallOnly_noStartOrDeltas() async throws {
        let backend = try makeNonStreamingBackend()
        let call = ToolCall(id: "c2", toolName: "search", arguments: #"{"q":"swift"}"#)
        // Non-streaming backends use the flat scriptedToolCalls path.
        backend.tokensToYield = []
        backend.scriptedToolCalls = [call]

        let stream = try backend.generate(prompt: "search swift", systemPrompt: nil, config: .init())
        let events = try await collectEvents(stream)

        let starts = events.filter { if case .toolCallStart = $0 { return true }; return false }
        let deltas = events.filter { if case .toolCallArgumentsDelta = $0 { return true }; return false }
        let calls = events.compactMap { event -> ToolCall? in
            if case .toolCall(let c) = event { return c }
            return nil
        }

        // Sabotage: scripting a .start delta in scriptedToolCallDeltasPerTurn would
        // produce a non-empty `starts` array, flipping the first assertion.
        XCTAssertTrue(starts.isEmpty, "non-streaming backend must not emit .toolCallStart")
        XCTAssertTrue(deltas.isEmpty, "non-streaming backend must not emit .toolCallArgumentsDelta")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.id, "c2")
    }

    // MARK: - 3. Exactly one .toolCall per callId

    /// Contract: the consumer sees exactly one `.toolCall` per unique callId.
    /// When a backend (hypothetically buggy) emits the same callId twice as
    /// `.toolCall`, the coordinator forwards both — no deduplication at the
    /// consumer level. This test asserts the documented pass-through behaviour
    /// and catches any accidental deduplication regression.
    func test_exactlyOneToolCallPerCallId() async throws {
        // The duplicate callId is intentional — tests what actually happens,
        // not an ideal-world contract. The coordinator has no callId-level
        // dedup; it dispatches each .toolCall independently.
        let call = ToolCall(id: "dup-1", toolName: "noop", arguments: "{}")
        provider.backend.scriptedToolCalls = [call, call]
        provider.backend.tokensToYield = []

        let stream = try provider.backend.generate(prompt: "go", systemPrompt: nil, config: .init())
        let events = try await collectEvents(stream)

        let callEvents = events.compactMap { event -> ToolCall? in
            if case .toolCall(let c) = event { return c }
            return nil
        }

        // The backend emits the same callId twice; both flow through without
        // deduplication. Callers are responsible for deduplicating by id when
        // building UI state. If the backend were fixed to emit unique ids,
        // count would stay 2 — the shape of the stream, not correctness of ids.
        //
        // Sabotage: changing scriptedToolCalls to only [call] yields count == 1,
        // flipping the assertion.
        XCTAssertEqual(callEvents.count, 2,
            "backend emits two .toolCall events; no dedup at stream level")
        XCTAssertEqual(callEvents[0].id, "dup-1")
        XCTAssertEqual(callEvents[1].id, "dup-1")
    }

    // MARK: - 4. Empty arguments: .toolCall with arguments == ""

    /// Contract: a model emitting a tool call with an empty arguments string
    /// must round-trip cleanly — no crash, no nil, arguments equals "".
    func test_emptyArguments_emitsToolCallWithEmptyString() async throws {
        let backend = try makeStreamingBackend()
        let call = ToolCall(id: "c3", toolName: "noop", arguments: "")
        backend.scriptedToolCalls = [call]
        backend.tokensToYield = []

        let stream = try backend.generate(prompt: "noop", systemPrompt: nil, config: .init())
        let events = try await collectEvents(stream)

        let received = events.compactMap { event -> ToolCall? in
            if case .toolCall(let c) = event { return c }
            return nil
        }

        // Sabotage: substituting a non-empty arguments string in the scripted call
        // makes `received.first?.arguments == ""` fail.
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.arguments, "")
        XCTAssertEqual(received.first?.toolName, "noop")
    }

    // MARK: - 5. Single-chunk arguments: start then immediately call, no deltas

    /// Contract: a streaming backend may legitimately emit `.toolCallStart` →
    /// `.toolCall` with no intervening deltas (arguments arrived in one chunk).
    /// The consumer must see exactly those two events with no deltas between them.
    func test_singleChunkArguments_noDeltas() async throws {
        let backend = try makeStreamingBackend()
        let call = ToolCall(id: "c4", toolName: "echo", arguments: #"{"text":"hi"}"#)

        backend.scriptedToolCallDeltasPerTurn = [[
            .start(callId: "c4", name: "echo"),
            // No deltas — arguments arrive complete on the .call event.
            .call(call),
        ]]

        let stream = try backend.generate(prompt: "echo hi", systemPrompt: nil, config: .init())
        let events = try await collectEvents(stream)

        let toolEvents = events.filter {
            switch $0 {
            case .toolCallStart, .toolCallArgumentsDelta, .toolCall: return true
            default: return false
            }
        }

        let deltas = toolEvents.filter {
            if case .toolCallArgumentsDelta = $0 { return true }
            return false
        }

        guard toolEvents.count == 2 else {
            XCTFail("Expected start + call (2 events), got \(toolEvents.count)")
            return
        }

        // Sabotage: adding a .delta to the scripted sequence makes deltas.count == 1,
        // flipping the isEmpty assertion.
        XCTAssertTrue(deltas.isEmpty, "no .toolCallArgumentsDelta must appear between start and call")
        if case .toolCallStart(let id, _) = toolEvents[0] {
            XCTAssertEqual(id, "c4")
        } else {
            XCTFail("First event must be .toolCallStart")
        }
        if case .toolCall(let c) = toolEvents[1] {
            XCTAssertEqual(c.arguments, #"{"text":"hi"}"#)
        } else {
            XCTFail("Second event must be .toolCall")
        }
    }

    // MARK: - 6. Interleaved deltas maintain per-id ordering

    /// Contract: when a streaming backend interleaves deltas for two different
    /// callIds, consumers must concatenate each id's deltas independently —
    /// the final `.toolCall` for each id carries arguments equal to only that
    /// id's deltas joined, not all deltas mixed together.
    func test_interleavedDeltas_maintainPerIdOrdering() async throws {
        let backend = try makeStreamingBackend()
        let callA = ToolCall(id: "a1", toolName: "fn_a", arguments: #"{"x":1}"#)
        let callB = ToolCall(id: "b1", toolName: "fn_b", arguments: #"{"y":2}"#)

        // Interleaved: A-delta, B-delta, A-delta, A-call, B-call.
        backend.scriptedToolCallDeltasPerTurn = [[
            .start(callId: "a1", name: "fn_a"),
            .start(callId: "b1", name: "fn_b"),
            .delta(callId: "a1", textDelta: #"{"x":"#),
            .delta(callId: "b1", textDelta: #"{"y":"#),
            .delta(callId: "a1", textDelta: #"1}"#),
            .delta(callId: "b1", textDelta: #"2}"#),
            .call(callA),
            .call(callB),
        ]]

        let stream = try backend.generate(prompt: "both", systemPrompt: nil, config: .init())
        let events = try await collectEvents(stream)

        // Reconstruct per-id delta concatenation from the stream.
        var deltasA: [String] = []
        var deltasB: [String] = []
        var toolCalls: [ToolCall] = []
        for event in events {
            switch event {
            case .toolCallArgumentsDelta(let id, let text):
                if id == "a1" { deltasA.append(text) }
                else if id == "b1" { deltasB.append(text) }
            case .toolCall(let c):
                toolCalls.append(c)
            default:
                break
            }
        }

        XCTAssertEqual(toolCalls.count, 2)

        let receivedA = toolCalls.first { $0.id == "a1" }
        let receivedB = toolCalls.first { $0.id == "b1" }

        XCTAssertNotNil(receivedA, "toolCall for a1 must be present")
        XCTAssertNotNil(receivedB, "toolCall for b1 must be present")

        // Sabotage: mixing all deltas into a single accumulator (ignoring callId)
        // would make concatenation equal one giant string rather than per-id slices.
        XCTAssertEqual(receivedA?.arguments, deltasA.joined(),
            "fn_a arguments must equal A-specific deltas concatenated")
        XCTAssertEqual(receivedB?.arguments, deltasB.joined(),
            "fn_b arguments must equal B-specific deltas concatenated")
        XCTAssertEqual(deltasA.joined(), #"{"x":1}"#)
        XCTAssertEqual(deltasB.joined(), #"{"y":2}"#)
    }

    // MARK: - 7. Cancellation after start: no partial .toolCall synthesised

    /// Contract: if the generation stream is cancelled after `.toolCallStart`
    /// but before the authoritative `.toolCall`, the consumer must not receive
    /// any `.toolCall` event for that callId.
    func test_cancellationAfterStart_doesNotSynthesizePartialCall() async throws {
        // Use a coordinator so we can call stopGeneration() mid-stream.
        // Turn 1: emit start then hang on a delayed call. Turn 2: never
        // reached if cancellation works correctly.
        let backend = MockInferenceBackend(
            capabilities: BackendCapabilities(
                supportedParameters: [.temperature],
                maxContextTokens: 4096,
                supportsToolCalling: true,
                streamsToolCallArguments: true
            )
        )
        backend.isModelLoaded = true

        // Script the backend to emit a start, two deltas, and then the
        // authoritative call. The mock pauses on `toolDeltaEmissionGate`
        // before each entry, which lets us cancel BEFORE `.call` is
        // yielded into the buffer. Without the gate, the mock would fire
        // all four entries synchronously into the unbounded AsyncStream
        // continuation; the collector's break-on-first-delta would race
        // the buffered `.call` into the residual drain.
        let call = ToolCall(id: "c5", toolName: "partial", arguments: #"{"k":"v"}"#)
        backend.scriptedToolCallDeltasPerTurn = [[
            .start(callId: "c5", name: "partial"),
            .delta(callId: "c5", textDelta: #"{"k":"#),
            .delta(callId: "c5", textDelta: #""v"}"#),
            .call(call),
        ]]
        backend.tokensToYield = []
        let gate = TokenEmissionGate()
        backend.toolDeltaEmissionGate = gate

        let provider = FakeGenerationContextProvider(backend: backend)
        let coordinator = GenerationCoordinator()
        coordinator.provider = provider

        let (_, stream) = try coordinator.enqueue(
            messages: [("user", "go")],
            maxOutputTokens: 32
        )

        // Collect events from a single consumer. Release one delta-gate
        // permit at a time:
        //   - Permit 1 → `.start` flows through.
        //   - Permit 2 → first `.delta` flows; collector breaks here.
        // After cancel, we release the gate so the mock's emission task
        // can wake from its wait, observe `Task.isCancelled` (set by
        // `stopGeneration()`), and exit without yielding `.call`.
        let collector = Task<[GenerationEvent], Never> {
            var events: [GenerationEvent] = []
            do {
                for try await event in stream.events {
                    events.append(event)
                    if case .toolCallArgumentsDelta = event { break }
                }
            } catch {
                // CancellationError is expected once we call stopGeneration().
            }
            return events
        }

        // Drive the script forward: `.start` then first `.delta`. Any
        // further entries stay behind the gate until we explicitly
        // advance again or release.
        await gate.advance() // .start
        await gate.advance() // first .delta — collector will break

        let collectedEvents = await collector.value
        coordinator.stopGeneration()
        // Wake the mock so it observes cancellation and exits. Anything
        // it yields after `stopGeneration()` is dropped because
        // `stopGeneration()` finished the continuation.
        await gate.release()

        // Gather any remaining events that leaked through after cancellation.
        let residual = Task<[GenerationEvent], Never> {
            var events: [GenerationEvent] = []
            do {
                for try await event in stream.events { events.append(event) }
            } catch {}
            return events
        }
        let residualEvents = await residual.value

        let allEvents = collectedEvents + residualEvents
        let toolCalls = allEvents.compactMap { event -> ToolCall? in
            if case .toolCall(let c) = event { return c }
            return nil
        }

        // Sabotage: removing the `guard !Task.isCancelled` check in
        // GenerationCoordinator's dispatch loop would let the stream continue
        // to the .call event — toolCalls would be non-empty.
        XCTAssertTrue(toolCalls.isEmpty,
            "no .toolCall must reach the consumer after stream cancellation pre-call; got \(toolCalls)")
    }

    // MARK: - 8. Orphan start (no matching call): silently dropped, no error

    /// Contract: when a streaming backend emits `.toolCallStart` but the stream
    /// ends without a matching `.toolCall`, the orchestrator silently drops the
    /// orphan. No error is surfaced; the start event is forwarded but the
    /// unmatched state is not flagged as a stream error.
    ///
    /// This documents the actual behaviour: `.toolCallStart` falls through to
    /// the coordinator's `default` forwarding path; when the stream ends, the
    /// coordinator does not inspect the in-flight start set and therefore does
    /// not synthesise an error. Consumers building progressive call-card UI must
    /// handle the case where a displayed start never resolves to a complete call.
    func test_orphanStart_withoutMatchingCall_isDroppedSilently() async throws {
        // Script: emit start + two deltas, then finish the stream without a .call.
        let backend = MockInferenceBackend(
            capabilities: BackendCapabilities(
                supportedParameters: [.temperature],
                maxContextTokens: 4096,
                supportsToolCalling: true,
                streamsToolCallArguments: true
            )
        )
        backend.isModelLoaded = true

        // Use an explicit AsyncThrowingStream to simulate an orphan start —
        // the mock's scripted paths always pair start with a matching .call,
        // so drive the inner stream directly.
        let inner = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            continuation.yield(.toolCallStart(callId: "orphan-1", name: "ghost"))
            continuation.yield(.toolCallArgumentsDelta(callId: "orphan-1", textDelta: #"{"a":"#))
            continuation.yield(.toolCallArgumentsDelta(callId: "orphan-1", textDelta: #"1}"#))
            // Stream ends without emitting .toolCall(orphan-1).
            continuation.finish()
        }
        let stream = GenerationStream(inner)

        let events = try await collectEvents(stream)

        let starts = events.filter { if case .toolCallStart = $0 { return true }; return false }
        let deltas = events.filter { if case .toolCallArgumentsDelta = $0 { return true }; return false }
        let toolCalls = events.filter { if case .toolCall = $0 { return true }; return false }

        // The start and deltas are forwarded verbatim (they pass through the
        // coordinator's default case). No error is synthesised; no .toolCall arrives.
        //
        // Sabotage: adding a `.toolCall` yield after the deltas in the inner stream
        // above would make toolCalls.count == 1, flipping the isEmpty assertion.
        XCTAssertEqual(starts.count, 1, "orphan .toolCallStart must be forwarded, not suppressed")
        XCTAssertEqual(deltas.count, 2, "orphan .toolCallArgumentsDelta events must be forwarded")
        XCTAssertTrue(toolCalls.isEmpty, "no .toolCall must appear for an orphan start")
    }
}
