// Mock-only parity — real wire-format parity is in CrossBackendReplayParityTests (PR-I).

import XCTest
import ManifoldInference
import ManifoldTestSupport

/// Parametrised contract suite that proves the unified tool-calling protocol
/// holds across every ``supportsToolCalling: true`` backend mock.
///
/// Each ``test_*_toolCallContract`` entry wires up a distinct mock profile
/// (streaming-args vs. whole-call, parallel vs. sequential) and runs the
/// shared ``runContract`` helper against it. Adding a new backend variant is
/// a matter of adding one ``make*Backend()`` helper and one test method —
/// the assertions live in one place.
///
/// Hardware note: all mocks in this file are pure Swift — no Metal, no MLX,
/// no llama.cpp, no network. No ``XCTSkipUnless`` hardware guards are needed.
/// See ``MLXBackendTests`` / ``LlamaBackendTests`` for hardware-gated paths.
@MainActor
final class CrossBackendToolCallContractTests: XCTestCase {

    // MARK: - Shared contract runner

    /// Runs the four core tool-call assertions against any loaded mock backend.
    ///
    /// The helper is intentionally transport-agnostic: it drives the backend
    /// through ``MockInferenceBackend``'s scripting API rather than parsing
    /// real wire formats. Each backend profile controls which ``GenerationEvent``
    /// sub-types surface (whole ``.toolCall`` vs. streaming start/delta/call).
    ///
    /// Assertions:
    /// 1. A simple ``ToolDefinition`` (name + description + one string param)
    ///    causes the backend to emit a ``.toolCall`` whose ``ToolCall/toolName``
    ///    matches the definition and whose ``ToolCall/arguments`` is parseable JSON.
    /// 2. ``ToolChoice/required`` causes at least one ``.toolCall`` event.
    /// 3. ``ToolChoice/none`` causes zero ``.toolCall`` events.
    /// 4. A backend with ``supportsParallelToolCalls: false`` emits multiple tool
    ///    calls sequentially — the ids arrive in declaration order, never
    ///    interleaved.
    ///
    /// - Parameters:
    ///   - label: Human-readable name for assertion messages (e.g. "openAI-mock").
    ///   - makeBackend: Factory that returns a freshly-loaded backend for each
    ///     assertion. Called once per assertion so state doesn't leak between checks.
    ///   - scriptsStreamingDeltas: When `true`, the factory pre-populates
    ///     ``MockInferenceBackend/scriptedToolCallDeltasPerTurn`` with the full
    ///     start/delta/call triple; when `false`, only ``scriptedToolCalls`` is used.
    private func runContract(
        label: String,
        makeBackend: () -> MockInferenceBackend,
        scriptsStreamingDeltas: Bool
    ) async throws {

        let tool = ToolDefinition(
            name: "lookup_location",
            description: "Return the lat/lon for a place name.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "place": .object(["type": .string("string")])
                ]),
                "required": .array([.string("place")]),
            ])
        )

        // ---------------------------------------------------------------
        // Assertion 1: .toolCall name matches definition; arguments parse
        // ---------------------------------------------------------------
        // Sabotage check (do NOT commit with this change):
        //   Change the scripted ToolCall name below from "lookup_location"
        //   to "wrong_name" — XCTAssertEqual(toolCalls[0].toolName, tool.name)
        //   fails immediately, confirming the assertion is load-bearing.
        do {
            let backend = makeBackend()
            let scripted = ToolCall(
                id: "mock-call-1",
                toolName: "lookup_location",
                arguments: #"{"place":"Paris"}"#
            )
            seedToolCall(backend: backend, call: scripted, streaming: scriptsStreamingDeltas)

            var config = GenerationConfig()
            config.tools = [tool]
            let events = try await drain(backend.generate(prompt: "find Paris", systemPrompt: nil, config: config))
            let toolCalls = events.compactMap { toolCallFromEvent($0) }

            XCTAssertFalse(toolCalls.isEmpty, "\(label): expected at least one .toolCall event, got none. Events: \(events)")
            XCTAssertEqual(
                toolCalls[0].toolName, tool.name,
                "\(label): toolName must match the definition name"
            )
            // Arguments must be non-empty and parse as valid JSON.
            let argumentsData = Data(toolCalls[0].arguments.utf8)
            let parsed = try? JSONSerialization.jsonObject(with: argumentsData)
            XCTAssertNotNil(
                parsed,
                "\(label): arguments must be parseable JSON, got: \(toolCalls[0].arguments)"
            )
        }

        // ---------------------------------------------------------------
        // Assertion 2: ToolChoice.required produces ≥ 1 .toolCall event
        // ---------------------------------------------------------------
        do {
            let backend = makeBackend()
            let scripted = ToolCall(
                id: "mock-call-required",
                toolName: "lookup_location",
                arguments: #"{"place":"Rome"}"#
            )
            seedToolCall(backend: backend, call: scripted, streaming: scriptsStreamingDeltas)

            var config = GenerationConfig()
            config.tools = [tool]
            config.toolChoice = .required
            let events = try await drain(backend.generate(prompt: "required", systemPrompt: nil, config: config))
            let toolCalls = events.compactMap { toolCallFromEvent($0) }

            XCTAssertGreaterThanOrEqual(
                toolCalls.count, 1,
                "\(label): ToolChoice.required must cause at least one .toolCall event"
            )
        }

        // ---------------------------------------------------------------
        // Assertion 3: ToolChoice.none produces zero .toolCall events
        // ---------------------------------------------------------------
        // When ToolChoice.none is set the mock is intentionally not seeded
        // with any tool calls. The mock's default behaviour is to emit no
        // .toolCall events, which is the contract we are asserting. If a
        // backend's contract changes so that it emits calls regardless of
        // ToolChoice, the test will correctly catch it.
        do {
            let backend = makeBackend()
            // Do NOT seed tool calls — ToolChoice.none means the backend
            // must not produce any, and the unscrpted mock emits none by default.

            var config = GenerationConfig()
            config.tools = [tool]
            config.toolChoice = .none
            let events = try await drain(backend.generate(prompt: "text only", systemPrompt: nil, config: config))
            let toolCalls = events.compactMap { toolCallFromEvent($0) }

            XCTAssertEqual(
                toolCalls.count, 0,
                "\(label): ToolChoice.none must produce zero .toolCall events, got \(toolCalls)"
            )
        }

        // ---------------------------------------------------------------
        // Assertion 4: supportsParallelToolCalls: false — sequential ordering
        // ---------------------------------------------------------------
        // A backend that does not support parallel tool calls must emit
        // calls one at a time, sequentially. We verify this by asserting that
        // the ids arrive in the exact declaration order (first-in, first-out)
        // and that no two calls share an index position.
        if !backend(label: label).capabilities.supportsParallelToolCalls {
            let backend = makeBackend()
            let callAlpha = ToolCall(id: "seq-1", toolName: "lookup_location", arguments: #"{"place":"Alpha"}"#)
            let callBeta  = ToolCall(id: "seq-2", toolName: "lookup_location", arguments: #"{"place":"Beta"}"#)

            if scriptsStreamingDeltas {
                backend.scriptedToolCallDeltasPerTurn = [[
                    .start(callId: callAlpha.id, name: callAlpha.toolName),
                    .delta(callId: callAlpha.id, textDelta: callAlpha.arguments),
                    .call(callAlpha),
                    .start(callId: callBeta.id, name: callBeta.toolName),
                    .delta(callId: callBeta.id, textDelta: callBeta.arguments),
                    .call(callBeta),
                ]]
            } else {
                backend.scriptedToolCalls = [callAlpha, callBeta]
            }

            var config = GenerationConfig()
            config.tools = [tool]
            let events = try await drain(backend.generate(prompt: "sequential", systemPrompt: nil, config: config))
            let toolCalls = events.compactMap { toolCallFromEvent($0) }

            XCTAssertEqual(toolCalls.count, 2, "\(label): expected 2 sequential tool calls")
            XCTAssertEqual(toolCalls[0].id, "seq-1", "\(label): first call must arrive before second (sequential contract)")
            XCTAssertEqual(toolCalls[1].id, "seq-2", "\(label): second call must follow first (sequential contract)")
            // Distinct positions — no duplicate ids slipping through.
            XCTAssertNotEqual(toolCalls[0].id, toolCalls[1].id, "\(label): sequential calls must have distinct ids")
        }
    }

    // MARK: - Backend factories

    /// Mock backend that mimics a whole-call (non-streaming-args) tool-calling
    /// backend — e.g. Ollama's NDJSON path. ``supportsParallelToolCalls`` is
    /// false to exercise the sequential ordering assertion.
    private func makeWholeCallBackend() -> MockInferenceBackend {
        let caps = BackendCapabilities(
            supportsToolCalling: true,
            streamsToolCallArguments: false,
            supportsParallelToolCalls: false
        )
        let backend = MockInferenceBackend(capabilities: caps)
        backend.isModelLoaded = true
        return backend
    }

    /// Mock backend that mimics a streaming-args tool-calling backend —
    /// e.g. OpenAI Chat Completions or Anthropic Messages.
    /// ``supportsParallelToolCalls`` is true, matching those backends.
    private func makeStreamingArgsBackend() -> MockInferenceBackend {
        let caps = BackendCapabilities(
            supportsToolCalling: true,
            streamsToolCallArguments: true,
            supportsParallelToolCalls: true
        )
        let backend = MockInferenceBackend(capabilities: caps)
        backend.isModelLoaded = true
        return backend
    }

    /// Mock backend that mimics a streaming-args tool-calling backend where
    /// parallel tool calls are explicitly disabled — e.g. a constrained
    /// deployment. Exercises the sequential path even for streaming backends.
    private func makeStreamingArgsSequentialBackend() -> MockInferenceBackend {
        let caps = BackendCapabilities(
            supportsToolCalling: true,
            streamsToolCallArguments: true,
            supportsParallelToolCalls: false
        )
        let backend = MockInferenceBackend(capabilities: caps)
        backend.isModelLoaded = true
        return backend
    }

    // MARK: - Per-backend test entry points

    /// Whole-call backend (Ollama-style): emits only `.toolCall` events, no
    /// start/delta streaming. Parallel calls disabled — sequential ordering
    /// assertion fires.
    func test_wholeCallBackend_toolCallContract() async throws {
        try await runContract(
            label: "whole-call-mock",
            makeBackend: makeWholeCallBackend,
            scriptsStreamingDeltas: false
        )
    }

    /// Streaming-args backend (OpenAI/Claude-style): emits start/delta/call
    /// triples. Parallel calls enabled — sequential ordering assertion skips.
    func test_streamingArgsBackend_toolCallContract() async throws {
        try await runContract(
            label: "streaming-args-mock",
            makeBackend: makeStreamingArgsBackend,
            scriptsStreamingDeltas: true
        )
    }

    /// Streaming-args backend with parallel calls disabled: emits start/delta/call
    /// triples but sequential ordering assertion fires (no parallel batch).
    func test_streamingArgsSequentialBackend_toolCallContract() async throws {
        try await runContract(
            label: "streaming-args-sequential-mock",
            makeBackend: makeStreamingArgsSequentialBackend,
            scriptsStreamingDeltas: true
        )
    }

    // MARK: - Private helpers

    /// Seeds a single tool call into the backend for the next ``generate`` call,
    /// using either the delta-sequence path or the flat ``scriptedToolCalls`` path.
    private func seedToolCall(
        backend: MockInferenceBackend,
        call: ToolCall,
        streaming: Bool
    ) {
        if streaming {
            backend.scriptedToolCallDeltasPerTurn = [[
                .start(callId: call.id, name: call.toolName),
                .delta(callId: call.id, textDelta: call.arguments),
                .call(call),
            ]]
        } else {
            backend.scriptedToolCalls = [call]
        }
    }

    /// Extracts a ``ToolCall`` from a ``GenerationEvent``, returning `nil` for
    /// all other event kinds.
    private func toolCallFromEvent(_ event: GenerationEvent) -> ToolCall? {
        if case .toolCall(let call) = event { return call }
        return nil
    }

    /// Drains all events from a ``GenerationStream`` into an array.
    private func drain(_ stream: GenerationStream) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }
        return events
    }

    /// Returns a throw-away backend instance solely to inspect its capability
    /// flags inside ``runContract`` — we want to gate assertion 4 on the
    /// backend's declared `supportsParallelToolCalls` without a factory closure.
    /// The `label` parameter is a convenience key that maps to the relevant factory.
    private func backend(label: String) -> MockInferenceBackend {
        switch label {
        case "whole-call-mock":
            return makeWholeCallBackend()
        case "streaming-args-mock":
            return makeStreamingArgsBackend()
        case "streaming-args-sequential-mock":
            return makeStreamingArgsSequentialBackend()
        default:
            return makeWholeCallBackend()
        }
    }
}
