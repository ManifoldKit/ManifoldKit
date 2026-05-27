import XCTest
@testable import ManifoldInference

@MainActor
final class ToolRegistryStreamingTests: XCTestCase {
    private struct StreamingExecutor: ToolExecutor {
        struct Boom: Error, CustomStringConvertible {
            var description: String { "stream exploded" }
        }

        let definition: ToolDefinition
        let makeStream: @Sendable (JSONSchemaValue) -> AsyncThrowingStream<ToolExecutionEvent, Error>

        init(
            name: String,
            makeStream: @escaping @Sendable (JSONSchemaValue) -> AsyncThrowingStream<ToolExecutionEvent, Error>
        ) {
            self.definition = ToolDefinition(name: name, description: "streaming", parameters: .object([:]))
            self.makeStream = makeStream
        }

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            ToolResult(callId: "", content: "single-shot path should not run")
        }

        func executeStreaming(arguments: JSONSchemaValue) -> AsyncThrowingStream<ToolExecutionEvent, Error> {
            makeStream(arguments)
        }
    }

    func test_dispatchStreaming_forwardsProgressBeforeStampedTerminalResult() async {
        let registry = ToolRegistry()
        registry.register(
            StreamingExecutor(name: "long_op") { _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.progress(message: "step 1", fraction: 0.25))
                    continuation.yield(.progress(message: "step 2", fraction: 0.75))
                    continuation.yield(.completed(ToolResult(callId: "executor-stale-id", content: "done")))
                    continuation.finish()
                }
            }
        )

        let events = await collect(
            registry.dispatchStreaming(ToolCall(id: "call-1", toolName: "long_op", arguments: "{}"))
        )

        XCTAssertEqual(events.count, 3)
        guard case .progress(let firstMessage, let firstFraction) = events[0],
              case .progress(let secondMessage, let secondFraction) = events[1],
              case .completed(let result) = events[2] else {
            return XCTFail("Expected progress, progress, completed; got \(events)")
        }
        XCTAssertEqual(firstMessage, "step 1")
        XCTAssertEqual(firstFraction, 0.25)
        XCTAssertEqual(secondMessage, "step 2")
        XCTAssertEqual(secondFraction, 0.75)
        XCTAssertEqual(result.callId, "call-1")
        XCTAssertEqual(result.content, "done")
        XCTAssertNil(result.errorKind)
    }

    func test_dispatchStreaming_classifiesThrownStreamErrorAfterProgress() async {
        let registry = ToolRegistry()
        registry.register(
            StreamingExecutor(name: "throws") { _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.progress(message: "started", fraction: nil))
                    continuation.finish(throwing: StreamingExecutor.Boom())
                }
            }
        )

        let events = await collect(
            registry.dispatchStreaming(ToolCall(id: "call-err", toolName: "throws", arguments: "{}"))
        )

        XCTAssertEqual(events.count, 2)
        guard case .progress(let message, let fraction) = events[0],
              case .completed(let result) = events[1] else {
            return XCTFail("Expected progress then completed error; got \(events)")
        }
        XCTAssertEqual(message, "started")
        XCTAssertNil(fraction)
        XCTAssertEqual(result.callId, "call-err")
        XCTAssertEqual(result.errorKind, .permanent)
        XCTAssertTrue(result.content.contains("stream exploded"))
    }

    func test_dispatch_underCancellationClassifiesStreamingExecutorAsCancelled() async {
        let executor = CancellableStreamingExecutor(name: "slow_stream")
        let registry = ToolRegistry()
        registry.register(executor)

        let dispatchTask = Task { @MainActor in
            await registry.dispatch(ToolCall(id: "call-cancel", toolName: "slow_stream", arguments: "{}"))
        }
        for await _ in executor.didEnter { break }

        dispatchTask.cancel()
        let result = await dispatchTask.value

        XCTAssertEqual(result.callId, "call-cancel")
        XCTAssertEqual(result.errorKind, .cancelled)
        XCTAssertEqual(result.content, "cancelled by user")
    }

    private func collect(_ stream: AsyncStream<ToolExecutionEvent>) async -> [ToolExecutionEvent] {
        var events: [ToolExecutionEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }

    private final class CancellableStreamingExecutor: ToolExecutor, @unchecked Sendable {
        let definition: ToolDefinition
        let didEnter: AsyncStream<Void>
        private let enterContinuation: AsyncStream<Void>.Continuation

        init(name: String) {
            self.definition = ToolDefinition(name: name, description: "slow", parameters: .object([:]))
            var continuation: AsyncStream<Void>.Continuation!
            self.didEnter = AsyncStream { continuation = $0 }
            self.enterContinuation = continuation
        }

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            ToolResult(callId: "", content: "single-shot path should not run")
        }

        func executeStreaming(arguments: JSONSchemaValue) -> AsyncThrowingStream<ToolExecutionEvent, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    continuation.yield(.progress(message: "entered", fraction: nil))
                    enterContinuation.yield(())
                    do {
                        try await Task.sleep(for: .seconds(60))
                        continuation.yield(.completed(ToolResult(callId: "", content: "late")))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}
