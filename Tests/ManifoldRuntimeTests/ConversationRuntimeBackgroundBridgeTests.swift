#if canImport(BackgroundTasks)
import XCTest
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldTestSupport

@MainActor
final class ConversationRuntimeBackgroundBridgeTests: XCTestCase {

    // MARK: - Helpers

    private func makeRuntime() -> ConversationRuntime {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        let inference = InferenceService(backend: backend, name: "Mock")
        let store = InMemoryMessageStore()
        return ConversationRuntime(messageStore: store, inferenceService: inference)
    }

    // MARK: - Tests

    func testHandleExpirationDoesNotCrashOnIdleRuntime() async throws {
        // Expiration fired when no turns are in flight must complete cleanly.
        let runtime = makeRuntime()
        let bridge = ConversationRuntimeBackgroundBridge(runtime: runtime)

        bridge.handleExpiration()
        // Give the detached task a moment to complete; 200ms is generous for
        // a no-op cancel path on an idle runtime.
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func testCancelAllTurnsIsIdempotentOnIdleRuntime() async {
        // Multiple cancellations with no active turns must not crash or deadlock.
        let runtime = makeRuntime()

        await runtime.cancelAllTurns()
        await runtime.cancelAllTurns()
    }

    func testCancelAllTurnsIsIdempotentAfterSingleCancel() async {
        // A second call after a first-pass cancel must remain a no-op.
        let runtime = makeRuntime()

        await runtime.cancelAllTurns()
        // A second call on an already-drained registry is safe.
        await runtime.cancelAllTurns()
    }

    func testHandleExpirationFiresWithoutDeadlock() async throws {
        // Bridge must not deadlock when called from a non-async context, as the
        // real BGContinuedProcessingTask expiration handler is synchronous.
        let runtime = makeRuntime()
        let bridge = ConversationRuntimeBackgroundBridge(runtime: runtime)

        // Fire multiple times to surface any locking hazard in the detached-task path.
        bridge.handleExpiration()
        bridge.handleExpiration()

        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func testContinueGenerationIdentifierMatchesKnownValue() {
        XCTAssertEqual(
            ManifoldBackgroundTaskIdentifiers.continueGeneration,
            "com.manifoldkit.runtime.continueGeneration"
        )
    }
}
#endif
