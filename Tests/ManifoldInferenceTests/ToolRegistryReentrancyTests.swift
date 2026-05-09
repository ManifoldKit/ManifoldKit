import XCTest
@testable import ManifoldInference

/// Integration tests for ``ToolRegistry``'s reentrancy contract:
/// dispatches resolve their executor exactly once at entry, and registry
/// mutations during a suspended dispatch do not retarget the in-flight call.
@MainActor
final class ToolRegistryReentrancyTests: XCTestCase {

    // MARK: - Fixtures

    /// Executor that signals when it enters its sleep, then waits for an
    /// explicit "release" signal before returning. Synchronisation goes
    /// through `AsyncStream` continuations so the test never depends on
    /// wall-clock scheduling — `entered` fires as soon as the executor is
    /// suspended, and the executor only resumes after the test sends a
    /// value on `release`.
    private struct GatedMarkerExecutor: ToolExecutor {
        let definition: ToolDefinition
        let marker: String
        let entered: AsyncStream<Void>.Continuation
        let release: AsyncStream<Void>

        init(
            name: String,
            marker: String,
            entered: AsyncStream<Void>.Continuation,
            release: AsyncStream<Void>
        ) {
            self.definition = ToolDefinition(name: name, description: "marker", parameters: .object([:]))
            self.marker = marker
            self.entered = entered
            self.release = release
        }

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            entered.yield()
            // Wait until the test releases us. Using AsyncStream.first(where:)
            // gives us a deterministic suspension point we can resume on
            // demand, with no fixed sleep.
            for await _ in release { break }
            return ToolResult(callId: "", content: marker, errorKind: nil)
        }
    }

    /// Builds a paired (executor, releaser, enteredSignal) trio for use
    /// across the tests. The releaser closure is what unblocks the
    /// executor once mid-dispatch mutations are in place.
    private func makeGatedExecutor(
        name: String,
        marker: String
    ) -> (executor: GatedMarkerExecutor, release: () -> Void, entered: AsyncStream<Void>) {
        let (enteredStream, enteredCont) = AsyncStream.makeStream(of: Void.self)
        let (releaseStream, releaseCont) = AsyncStream.makeStream(of: Void.self)
        let executor = GatedMarkerExecutor(
            name: name,
            marker: marker,
            entered: enteredCont,
            release: releaseStream
        )
        let release = {
            releaseCont.yield()
            releaseCont.finish()
        }
        return (executor, release, enteredStream)
    }

    /// Awaits the executor's "I'm suspended" signal so the caller knows
    /// it's safe to mutate the registry without racing the dispatch.
    private func awaitEntered(_ entered: AsyncStream<Void>) async {
        for await _ in entered { return }
    }

    /// Fast executor used as the post-mutation replacement.
    private struct FastMarkerExecutor: ToolExecutor {
        let definition: ToolDefinition
        let marker: String

        init(name: String, marker: String) {
            self.definition = ToolDefinition(name: name, description: "marker", parameters: .object([:]))
            self.marker = marker
        }

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            ToolResult(callId: "", content: marker, errorKind: nil)
        }
    }

    private func makeCall(name: String, id: String = "call-1") -> ToolCall {
        ToolCall(id: id, toolName: name, arguments: "{}")
    }

    // MARK: - Mid-dispatch register replaces the executor for *future* dispatches

    func test_midDispatchRegister_doesNotRetargetInflightDispatch() async throws {
        let registry = ToolRegistry()
        let (gatedA, releaseA, enteredA) = makeGatedExecutor(name: "weather", marker: "A-result")
        registry.register(gatedA)

        // Kick off the gated dispatch in a child task. It signals when it
        // enters the suspension and waits for `releaseA()` to resume.
        let call = makeCall(name: "weather", id: "first")
        let firstTask = Task { @MainActor in
            await registry.dispatch(call)
        }

        // Wait for the executor's "entered" signal, then mutate the registry
        // mid-flight. No wall-clock sleep — `awaitEntered` returns the moment
        // the executor suspends.
        await awaitEntered(enteredA)
        registry.register(FastMarkerExecutor(name: "weather", marker: "B-result"))

        // Now release the in-flight executor so it can complete.
        releaseA()
        let firstAwaited = await firstTask.value
        XCTAssertEqual(firstAwaited.content, "A-result")
        XCTAssertNil(firstAwaited.errorKind)

        // The second dispatch sees the post-mutation table.
        let second = await registry.dispatch(makeCall(name: "weather", id: "second"))
        XCTAssertEqual(second.content, "B-result")
        XCTAssertNil(second.errorKind)
    }

    // MARK: - Mid-dispatch unregister still completes the in-flight call

    func test_midDispatchUnregister_inflightDispatchCompletes_secondDispatchIsUnknown() async throws {
        let registry = ToolRegistry()
        let (gated, release, entered) = makeGatedExecutor(name: "weather", marker: "A-result")
        registry.register(gated)

        let call = makeCall(name: "weather", id: "first")
        let firstTask = Task { @MainActor in
            await registry.dispatch(call)
        }

        await awaitEntered(entered)
        // The unregister-while-in-flight path emits a Log.inference.warning;
        // we verify behaviour, not the log line.
        registry.unregister(name: "weather")
        release()

        let firstAwaited = await firstTask.value
        XCTAssertEqual(firstAwaited.content, "A-result")
        XCTAssertNil(firstAwaited.errorKind)

        let second = await registry.dispatch(makeCall(name: "weather", id: "second"))
        XCTAssertEqual(second.errorKind, .unknownTool)
    }

    // MARK: - definitions snapshot reflects the post-mutation state mid-dispatch

    func test_definitionsSnapshot_takenMidDispatch_reflectsPostMutationState() async throws {
        let registry = ToolRegistry()
        let (gated, release, entered) = makeGatedExecutor(name: "weather", marker: "A-result")
        registry.register(gated)

        let call = makeCall(name: "weather", id: "first")
        let firstTask = Task { @MainActor in
            await registry.dispatch(call)
        }

        await awaitEntered(entered)

        // Snapshot reflects the *current* table, even though a dispatch is
        // suspended against an entry that's about to be replaced.
        let beforeReplacement = registry.definitions.map(\.name)
        XCTAssertEqual(beforeReplacement, ["weather"])

        registry.register(FastMarkerExecutor(name: "calculator", marker: "calc"))
        registry.unregister(name: "weather")

        let afterMutation = registry.definitions.map(\.name)
        XCTAssertEqual(afterMutation, ["calculator"])

        release()

        // The in-flight dispatch still completes against the original
        // executor — the mutation is visible to readers but doesn't
        // retarget the call.
        let firstAwaited = await firstTask.value
        XCTAssertEqual(firstAwaited.content, "A-result")
    }
}
