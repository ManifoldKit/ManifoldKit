import XCTest
import Foundation
import ManifoldInference
import ManifoldTestSupport

/// Coverage for #2206 — a conversation-observability event tap that works
/// WITHOUT `ConversationRuntime`.
///
/// Every test in this file drives generation exclusively through the public
/// `InferenceService` surface — `enqueue(...)`, `cancel(_:)`,
/// `addGenerationEventTap(...)` — with **no** `ConversationRuntime` in the
/// picture and **no** `@testable import`. This is the direct-drive shape
/// Fireside (roryford/fireside#912) needs: proof that
/// ``GenerationEventRecorder`` observes a live event feed from a generation
/// that never touched the runtime layer, not just that the registration API
/// compiles.
@MainActor
final class GenerationEventTapDirectDriveTests: XCTestCase {

    // MARK: - Fixtures

    private final class RecordingExecutor: ToolExecutor, @unchecked Sendable {
        let definition: ToolDefinition
        private(set) var callCount = 0
        var result = ToolResult(callId: "", content: #"{"summary":"sunny"}"#, errorKind: nil)

        init(name: String) {
            self.definition = ToolDefinition(name: name, description: "test", parameters: .object([:]))
        }

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            callCount += 1
            return result
        }
    }

    private func makeCall(id: String, name: String, arguments: String) -> ToolCall {
        ToolCall(id: id, toolName: name, arguments: arguments)
    }

    /// Asserts `kinds` appears as an in-order (not necessarily consecutive)
    /// subsequence of `trace`. Self-contained so this test file does not need
    /// to reach for `ManifoldAppEval`'s `EventSubsequenceChecker` (a
    /// higher-layer module `ManifoldInference` cannot depend on either).
    private func assertSubsequence(
        _ trace: [GenerationEventKind],
        contains kinds: [GenerationEventKind],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var traceIdx = 0
        for kind in kinds {
            guard let found = trace[traceIdx...].firstIndex(of: kind) else {
                XCTFail(
                    "Expected \(kind) to appear after index \(traceIdx) in trace \(trace)",
                    file: file,
                    line: line
                )
                return
            }
            traceIdx = found + 1
        }
    }

    // MARK: - Happy path: promptRendered → token → tool call → generationCompleted

    /// The generation-scoped subsequence the issue asks for — prompt
    /// rendered, first token, tool calls, and the terminal completion —
    /// captured by a ``GenerationEventRecorder`` attached directly to an
    /// `InferenceService` that was never wrapped in a `ConversationRuntime`.
    func test_directDrive_capturesPromptRenderedTokensToolCallsAndCompletion() async throws {
        let executor = RecordingExecutor(name: "get_weather")
        let registry = ToolRegistry()
        registry.register(executor)

        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.scriptedToolCallsPerTurn = [
            [makeCall(id: "c-1", name: "get_weather", arguments: #"{"city":"Rome"}"#)],
            [],
        ]
        backend.tokensToYieldPerTurn = [
            [],
            ["The weather", " is sunny."],
        ]

        // Direct-InferenceService construction — no ConversationRuntime, no
        // MessageStore/SessionStore, no @testable import.
        let service = InferenceService(backend: backend, name: "Mock", toolRegistry: registry)

        let recorder = GenerationEventRecorder()
        let drainTask = await recorder.start(on: service)

        let (_, stream) = try service.enqueue(
            structuredMessages: [StructuredMessage(role: "user", content: "What's the weather in Rome?")],
            config: GenerationConfig(maxOutputTokens: 128),
            hints: GenerationRuntimeHints(captureRenderedPrompt: true)
        )

        // Drive the turn to completion via the request's own stream — proves
        // the tap is a SEPARATE fan-out, not a substitute for the caller's
        // stream.
        var visible = ""
        for try await event in stream.events {
            if case let .token(text) = event { visible += text }
        }
        XCTAssertEqual(visible, "The weather is sunny.")
        XCTAssertEqual(executor.callCount, 1, "tool executor must have actually run")

        drainTask.cancel()
        _ = await drainTask.value

        let trace = await recorder.trace
        XCTAssertFalse(trace.isEmpty, "tap must have delivered events for a direct-InferenceService generation")

        // Live-wiring proof: the exact generation-scoped subsequence the
        // issue asks for, captured with NO ConversationRuntime involved.
        assertSubsequence(trace.map(\.kind), contains: [
            .promptRendered,
            .toolCall,
            .toolResult,
            .token,
            .generationCompleted,
        ])

        guard case let .generationCompleted(completion)? = trace.last(where: { $0.kind == .generationCompleted }) else {
            XCTFail("expected a terminal .generationCompleted event")
            return
        }
        XCTAssertEqual(completion.reason, .stop)

        // Same-schema JSONL round trip — the "enough for ConversationEventRecorder
        // to attach and produce its JSONL trace for non-runtime consumers"
        // acceptance criterion, at the generation layer.
        let jsonlURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("generation-trace-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: jsonlURL) }
        let generationTrace = GenerationEventTrace(events: trace)
        try generationTrace.save(to: jsonlURL)
        let jsonlContents = try String(contentsOf: jsonlURL, encoding: .utf8)
        let lines = jsonlContents.split(separator: "\n")
        XCTAssertEqual(lines.count, trace.count, "one JSONL line per recorded event")
    }

    // MARK: - Cancellation surfaces through the tap

    /// A cancelled tool call — the orchestrator's authoritative "the user
    /// stopped this turn" signal (`ToolResult.errorKind == .cancelled`, per
    /// `GenerationQueueApprovalTests` / `ToolDispatchHardeningTests`) — must
    /// surface as `.generationCompleted(reason: .cancelled)` on the tap. This
    /// is the tap's answer to "cancellation" from the issue's acceptance
    /// criteria: `GenerationEvent` has no bare `.errorRaised` case, so
    /// cancellation classifies through `GenerationCompletion.Reason` instead.
    func test_directDrive_cancellation_surfacesGenerationCompletedCancelled() async throws {
        let executor = RecordingExecutor(name: "stoppable")
        executor.result = ToolResult(callId: "", content: "cancelled by user", errorKind: .cancelled)
        let registry = ToolRegistry()
        registry.register(executor)

        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.scriptedToolCallsPerTurn = [
            [makeCall(id: "c-1", name: "stoppable", arguments: "{}")],
            [],
        ]

        let service = InferenceService(backend: backend, name: "Mock", toolRegistry: registry)

        let recorder = GenerationEventRecorder()
        let drainTask = await recorder.start(on: service)

        let (_, stream) = try service.enqueue(
            structuredMessages: [StructuredMessage(role: "user", content: "go")],
            config: GenerationConfig(maxOutputTokens: 8)
        )
        for try await _ in stream.events {}

        drainTask.cancel()
        _ = await drainTask.value

        let trace = await recorder.trace
        XCTAssertEqual(executor.callCount, 1, "the cancelled tool must have actually run")

        let cancelledCompletion = trace.contains {
            if case let .generationCompleted(completion) = $0 { return completion.reason == .cancelled }
            return false
        }
        XCTAssertTrue(cancelledCompletion, "tap must observe generationCompleted(reason: .cancelled) for a direct-drive cancel")
    }

    // MARK: - Errors surface through the tap

    /// A stream failure mid-generation must surface
    /// `.generationCompleted(reason: .error)` on the tap before the caller's
    /// own stream rethrows.
    func test_directDrive_streamFailure_surfacesGenerationCompletedError() async throws {
        struct BoomError: Error {}

        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["partial"]
        backend.shouldThrowInsideStream = BoomError()

        let service = InferenceService(backend: backend, name: "Mock")

        let recorder = GenerationEventRecorder()
        let drainTask = await recorder.start(on: service)

        let (_, stream) = try service.enqueue(
            messages: [.user("go")],
            config: GenerationConfig()
        )

        do {
            for try await _ in stream.events {}
            XCTFail("expected the stream to throw")
        } catch {
            // Expected — shouldThrowInsideStream propagates.
        }

        drainTask.cancel()
        _ = await drainTask.value

        let trace = await recorder.trace
        let errorCompletion = trace.contains {
            if case let .generationCompleted(completion) = $0 { return completion.reason == .error }
            return false
        }
        XCTAssertTrue(errorCompletion, "tap must observe generationCompleted(reason: .error) for a direct-drive stream failure")
    }

    // MARK: - Independent fan-out: a tap never competes with the caller's own stream

    /// Installing a tap must not steal events from the request's own
    /// `GenerationStream` — both must see the full sequence independently
    /// (mirrors `ConversationRuntime.addEventTap()`'s fan-out contract).
    func test_directDrive_tapDoesNotStealEventsFromCallersStream() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["Hi", " there"]

        let service = InferenceService(backend: backend, name: "Mock")

        let recorder = GenerationEventRecorder()
        let drainTask = await recorder.start(on: service)

        let (_, stream) = try service.enqueue(
            messages: [.user("hi")],
            config: GenerationConfig()
        )

        var callerVisible = ""
        for try await event in stream.events {
            if case let .token(text) = event { callerVisible += text }
        }
        XCTAssertEqual(callerVisible, "Hi there", "the caller's own stream must be unaffected by the tap")

        drainTask.cancel()
        _ = await drainTask.value

        let tapVisible = await recorder.trace.reduce(into: "") { acc, event in
            if case let .token(text) = event { acc += text }
        }
        XCTAssertEqual(tapVisible, "Hi there", "the tap must independently observe the same tokens")
    }
}
