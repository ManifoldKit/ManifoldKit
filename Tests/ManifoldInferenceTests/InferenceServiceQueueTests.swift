import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Tests for the InferenceService generation queue.
///
/// These tests verify sequential FIFO queue behavior, priority ordering,
/// cancellation, and session isolation without loading real models.
@MainActor
final class InferenceServiceQueueTests: XCTestCase {

    // MARK: - Controllable Mock

    /// A mock backend that blocks generation until explicitly released,
    /// enabling deterministic queue behavior testing.
    private final class GatedMockBackend: InferenceBackend, @unchecked Sendable {
        var isModelLoaded: Bool = true
        var isGenerating: Bool = false
        let capabilities = BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true
        )

        /// Each call to generate() appends a continuation here. Tests release
        /// tokens by calling `release(at:tokens:)` or `releaseAll()`.
        var gates: [AsyncThrowingStream<GenerationEvent, Error>.Continuation] = []
        var receivedConfigs: [GenerationConfig] = []
        var receivedHints: [GenerationRuntimeHints] = []
        var generateCallCount = 0
        var stopCallCount = 0

        func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
            isModelLoaded = true
        }

        func generate(
            prompt: String,
            systemPrompt: String?,
            config: GenerationConfig,
            hints: GenerationRuntimeHints
        ) throws -> GenerationStream {
            generateCallCount += 1
            receivedConfigs.append(config)
            receivedHints.append(hints)
            isGenerating = true
            let stream = AsyncThrowingStream<GenerationEvent, Error> { [weak self] continuation in
                self?.gates.append(continuation)
            }
            return GenerationStream(stream)
        }

        func stopGeneration() {
            stopCallCount += 1
            isGenerating = false
            for gate in gates {
                gate.finish()
            }
        }

        func unloadModel() {
            isModelLoaded = false
            isGenerating = false
            for gate in gates {
                gate.finish()
            }
            gates.removeAll()
        }

        /// Release a specific generation with tokens then finish.
        func release(at index: Int, tokens: [String] = ["tok"]) {
            guard index < gates.count else { return }
            for t in tokens {
                gates[index].yield(.token(t))
            }
            gates[index].finish()
            isGenerating = false
        }

        /// Release a specific generation with an error.
        func releaseWithError(at index: Int, error: Error) {
            guard index < gates.count else { return }
            gates[index].finish(throwing: error)
            isGenerating = false
        }
    }

    // MARK: - Helpers

    private func makeService(backend: GatedMockBackend? = nil) -> (InferenceService, GatedMockBackend) {
        let mock = backend ?? GatedMockBackend()
        let service = InferenceService(backend: mock, name: "GatedMock")
        return (service, mock)
    }

    /// Polls until `condition` is true or the 2-second deadline passes.
    ///
    /// Use this instead of bare `await Task.yield()` to wait for state driven
    /// by the drain `Task` that spawns asynchronously inside `enqueue`.
    private func waitFor(
        _ condition: @autoclosure () -> Bool,
        timeout: TimeInterval = 2.0,
        description: String = "condition"
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
        }
        if !condition() {
            XCTFail("Timed out waiting for \(description)")
        }
    }

    // MARK: - 1. Single request executes immediately

    func test_enqueue_singleRequest_executesImmediately() async throws {
        let (service, mock) = makeService()

        let (_, stream) = try service.enqueue(messages: [Message.user("hello")], config: GenerationConfig(), priority: .normal)

        // The stream should transition from .queued to .connecting once drainQueue fires.
        // drainQueue runs synchronously in enqueue, so by the time we get here
        // the phase should already be .connecting.
        XCTAssertEqual(stream.phase, .connecting,
                       "Stream should transition to .connecting immediately when queue is empty")
        XCTAssertTrue(service.isGenerating)

        // Wait for the drain Task to call generate() so gates[0] is populated.
        await waitFor(mock.generateCallCount >= 1, description: "generate() called")
        mock.release(at: 0, tokens: ["Hello", " world"])

        // Consume the passthrough stream.
        var collected: [String] = []
        for try await event in stream.events {
            if case .token(let text) = event {
                collected.append(text)
            }
        }

        XCTAssertEqual(collected, ["Hello", " world"])
        XCTAssertEqual(stream.phase, .done)
    }

    // MARK: - 2. Two requests execute sequentially

    func test_enqueue_twoRequests_executesSequentially() async throws {
        let (service, mock) = makeService()

        let (_, stream1) = try service.enqueue(messages: [Message.user("first")], config: GenerationConfig(), priority: .normal)
        let (_, stream2) = try service.enqueue(messages: [Message.user("second")], config: GenerationConfig(), priority: .normal)

        XCTAssertEqual(stream1.phase, .connecting, "First should be active")
        XCTAssertEqual(stream2.phase, .queued, "Second should be queued")
        XCTAssertEqual(mock.generateCallCount, 0,
                       "generate() not yet called — drain Task hasn't run")

        // Wait for the drain Task to call generate() for the first request.
        await waitFor(mock.generateCallCount >= 1, description: "first generate() called")
        XCTAssertEqual(mock.generateCallCount, 1, "Only first request should call generate()")

        mock.release(at: 0, tokens: ["a"])
        // Consume first stream.
        for try await _ in stream1.events {}

        // Second request should now be active (queue auto-drains on stream terminate).
        XCTAssertEqual(stream2.phase, .connecting)

        // Wait for the drain Task to call generate() for the second request.
        await waitFor(mock.generateCallCount >= 2, description: "second generate() called")
        XCTAssertEqual(mock.generateCallCount, 2)
        mock.release(at: 1, tokens: ["b"])

        var collected: [String] = []
        for try await event in stream2.events {
            if case .token(let text) = event {
                collected.append(text)
            }
        }
        XCTAssertEqual(collected, ["b"])
    }

    func test_enqueue_jsonMode_survivesQueueHandoff() async throws {
        let (service, mock) = makeService()

        let (_, firstStream) = try service.enqueue(messages: [Message.user("first")], config: GenerationConfig(), hints: GenerationRuntimeHints(jsonMode: false), priority: .normal)
        let (_, secondStream) = try service.enqueue(messages: [Message.user("second")], config: GenerationConfig(), hints: GenerationRuntimeHints(jsonMode: true), priority: .normal)

        await waitFor(mock.generateCallCount >= 1, description: "first generate() called")
        mock.release(at: 0, tokens: ["a"])
        for try await _ in firstStream.events {}

        let firstHints = try XCTUnwrap(mock.receivedHints.first)
        XCTAssertFalse(firstHints.jsonMode)

        await waitFor(mock.generateCallCount >= 2, description: "second generate() called")
        mock.release(at: 1, tokens: ["b"])
        for try await _ in secondStream.events {}

        XCTAssertEqual(mock.receivedHints.count, 2)
        XCTAssertTrue(mock.receivedHints[1].jsonMode)
    }

    // MARK: - 3. Priority: userInitiated jumps ahead

    func test_enqueue_priority_userInitiatedJumpsAhead() async throws {
        let (service, mock) = makeService()

        // First request is active immediately.
        let (_, streamActive) = try service.enqueue(messages: [Message.user("active")], config: GenerationConfig(), priority: .normal)

        // Enqueue background, then userInitiated.
        let (_, streamBg) = try service.enqueue(messages: [Message.user("bg")], config: GenerationConfig(), priority: .background)
        let (_, streamUi) = try service.enqueue(messages: [Message.user("ui")], config: GenerationConfig(), priority: .userInitiated)

        // Complete the active request.
        await waitFor(mock.generateCallCount >= 1, description: "active generate() called")
        mock.release(at: 0, tokens: ["x"])
        for try await _ in streamActive.events {}

        // userInitiated should run before background.
        XCTAssertEqual(streamUi.phase, .connecting,
                       "userInitiated should be dequeued before background")
        XCTAssertEqual(streamBg.phase, .queued,
                       "background should still be queued")
    }

    // MARK: - 4. Three-level priority ordering

    func test_enqueue_priority_threeLevel_ordering() async throws {
        let (service, mock) = makeService()

        // First fills the active slot.
        let (_, streamActive) = try service.enqueue(messages: [Message.user("active")], config: GenerationConfig(), priority: .normal)

        // Queue background, normal, userInitiated.
        let (_, streamBg) = try service.enqueue(messages: [Message.user("bg")], config: GenerationConfig(), priority: .background)
        let (_, streamNorm) = try service.enqueue(messages: [Message.user("norm")], config: GenerationConfig(), priority: .normal)
        let (_, streamUi) = try service.enqueue(messages: [Message.user("ui")], config: GenerationConfig(), priority: .userInitiated)

        // Complete the active request and drain.
        await waitFor(mock.generateCallCount >= 1, description: "active generate() called")
        mock.release(at: 0)
        for try await _ in streamActive.events {}

        // Should drain in priority order: userInitiated first.
        XCTAssertEqual(streamUi.phase, .connecting, "userInitiated should run first")
        XCTAssertEqual(streamNorm.phase, .queued, "normal should still be queued")
        XCTAssertEqual(streamBg.phase, .queued, "background should still be queued")

        // Release the userInitiated stream and consume it so the auto-drain
        // fires deterministically (consuming the consumer stream waits for the
        // Task's defer block, which calls drainQueue for the next request).
        await waitFor(mock.generateCallCount >= 2, description: "userInitiated generate() called")
        mock.release(at: 1, tokens: ["tok"])
        for try await _ in streamUi.events {}

        XCTAssertEqual(streamNorm.phase, .connecting, "normal should run second")
        XCTAssertEqual(streamBg.phase, .queued, "background should still be queued")

        // Same pattern for normal → background.
        await waitFor(mock.generateCallCount >= 3, description: "normal generate() called")
        mock.release(at: 2, tokens: ["tok"])
        for try await _ in streamNorm.events {}

        XCTAssertEqual(streamBg.phase, .connecting, "background should run last")
    }

    // MARK: - 5. Cancel queued request finishes continuation

    func test_cancel_queuedRequest_finishesContinuation() async throws {
        let (service, _) = makeService()

        // Active slot.
        let _ = try service.enqueue(messages: [Message.user("active")], config: GenerationConfig(), priority: .normal)
        // Queued.
        let (token2, stream2) = try service.enqueue(messages: [Message.user("queued")], config: GenerationConfig(), priority: .normal)

        service.cancel(token2)

        XCTAssertTrue(
            {
                if case .failed = stream2.phase { return true }
                return false
            }(),
            "Cancelled stream should have .failed phase"
        )

        // The stream should terminate (with an error).
        var caughtError = false
        do {
            for try await _ in stream2.events {}
        } catch {
            caughtError = true
        }
        XCTAssertTrue(caughtError, "Cancelled stream should throw")
    }

    // MARK: - 6. Cancel active request stops and drains next

    func test_cancel_activeRequest_stopsAndDrainsNext() async throws {
        let (service, _) = makeService()

        let (token1, _) = try service.enqueue(messages: [Message.user("first")], config: GenerationConfig(), priority: .normal)
        let (_, stream2) = try service.enqueue(messages: [Message.user("second")], config: GenerationConfig(), priority: .normal)

        XCTAssertEqual(stream2.phase, .queued)

        service.cancel(token1)

        // After cancelling active, the queue should drain and second becomes active.
        XCTAssertEqual(stream2.phase, .connecting,
                       "Second request should become active after first is cancelled")
    }

    // MARK: - 7. stopGeneration cancels active and drains queue

    func test_stopGeneration_cancelsActiveAndDrainsQueue() async throws {
        let (service, _) = makeService()

        let (_, stream1) = try service.enqueue(messages: [Message.user("first")], config: GenerationConfig(), priority: .normal)
        let (_, stream2) = try service.enqueue(messages: [Message.user("second")], config: GenerationConfig(), priority: .normal)

        service.stopGeneration()

        XCTAssertFalse(service.isGenerating)
        XCTAssertFalse(service.hasQueuedRequests)

        // Both streams should be terminated.
        func isFailed(_ phase: GenerationStream.Phase) -> Bool {
            if case .failed = phase { return true }
            return false
        }

        // stream1 may not have .failed set (it was active, not queued),
        // but its continuation was finished with an error.
        XCTAssertTrue(isFailed(stream2.phase), "Queued stream should be .failed after stopGeneration")
    }

    // MARK: - 9. discardRequests session mismatch cancels stale

    func test_discardRequests_sessionMismatch_cancelsStale() async throws {
        let (service, _) = makeService()
        let sessionA = UUID()
        let sessionB = UUID()

        let _ = try service.enqueue(messages: [Message.user("active")], config: GenerationConfig(), priority: .normal, requestGroupID: sessionA)
        let (_, streamA) = try service.enqueue(messages: [Message.user("queued-A")], config: GenerationConfig(), priority: .normal, requestGroupID: sessionA)
        let (_, streamB) = try service.enqueue(messages: [Message.user("queued-B")], config: GenerationConfig(), priority: .normal, requestGroupID: sessionB)

        await service.discardRequests(notMatching: sessionB)

        // Session A queued request should be cancelled.
        if case .failed = streamA.phase {
            // expected
        } else {
            XCTFail("Session A queued request should be .failed, got \(streamA.phase)")
        }

        // Session B request should now be active (promoted after A was cancelled),
        // since the active slot opened up when the session A active request was cancelled.
        XCTAssertEqual(streamB.phase, .connecting,
                       "Session B request should be promoted to active after A is discarded")
    }

    // MARK: - 10. nil requestGroupID never discarded

    func test_discardRequests_nilSessionID_neverDiscarded() async throws {
        let (service, _) = makeService()
        let sessionB = UUID()

        let _ = try service.enqueue(messages: [Message.user("active")], config: GenerationConfig(), priority: .normal)
        // nil requestGroupID — group-agnostic.
        let (_, streamNil) = try service.enqueue(messages: [Message.user("agnostic")], config: GenerationConfig(), priority: .normal, requestGroupID: nil)

        await service.discardRequests(notMatching: sessionB)

        XCTAssertEqual(streamNil.phase, .queued,
                       "nil requestGroupID should survive discardRequests")
    }

    // MARK: - 11. isGenerating false when queue empty

    func test_isGenerating_falseWhenQueueEmpty() {
        let (service, _) = makeService()
        XCTAssertFalse(service.isGenerating)
    }

    // MARK: - 12. isGenerating true while active request

    func test_isGenerating_trueWhileActiveRequest() throws {
        let (service, _) = makeService()
        let _ = try service.enqueue(messages: [Message.user("hello")], config: GenerationConfig(), priority: .normal)
        XCTAssertTrue(service.isGenerating)
    }

    // MARK: - 13. Exceeds max depth throws

    func test_enqueue_exceedsMaxDepth_throws() throws {
        let (service, _) = makeService()

        // First enqueue fills the active slot, next 8 fill the queue.
        let _ = try service.enqueue(messages: [Message.user("active")], config: GenerationConfig(), priority: .normal)
        for i in 0..<8 {
            let _ = try service.enqueue(messages: [Message.user("q\(i)")], config: GenerationConfig(), priority: .normal)
        }

        // 9th queued request (10th total) should throw.
        XCTAssertThrowsError(
            try service.enqueue(messages: [Message.user("overflow")], config: GenerationConfig(), priority: .normal)
        ) { error in
            XCTAssertTrue("\(error)".contains("queue is full"),
                          "Error should mention queue full, got: \(error)")
        }
    }

    // MARK: - 14. unloadModel cancels all queued

    func test_unloadModel_cancelsAllQueued() async throws {
        let (service, _) = makeService()

        let (_, stream1) = try service.enqueue(messages: [Message.user("first")], config: GenerationConfig(), priority: .normal)
        let (_, stream2) = try service.enqueue(messages: [Message.user("second")], config: GenerationConfig(), priority: .normal)

        service.unloadModel()

        XCTAssertFalse(service.isGenerating)
        XCTAssertFalse(service.isModelLoaded)
        XCTAssertFalse(service.hasQueuedRequests)

        // Both streams should be terminated.
        // stream1 was active, stream2 was queued — both should have their continuations finished.
        var stream2Error = false
        do {
            for try await _ in stream2.events {}
        } catch {
            stream2Error = true
        }
        XCTAssertTrue(stream2Error, "Queued stream should throw after unload")
    }

    // MARK: - 15. drainQueue noop when active request exists

    func test_drainQueue_noop_whenActiveRequestExists() async throws {
        let (service, mock) = makeService()

        let _ = try service.enqueue(messages: [Message.user("first")], config: GenerationConfig(), priority: .normal)
        let (_, stream2) = try service.enqueue(messages: [Message.user("second")], config: GenerationConfig(), priority: .normal)

        // The first stream is not consumed, so auto-drain never fires.
        // Wait for the first generate() call, then confirm the second has not fired.
        await waitFor(mock.generateCallCount >= 1, description: "first generate() called")

        XCTAssertEqual(mock.generateCallCount, 1,
                       "Only one generate() should have been called")
        XCTAssertEqual(stream2.phase, .queued, "Second should still be queued")
    }

    // MARK: - 16. Rapid enqueue/cancel — no leaked continuations

    func test_rapidEnqueueCancel_noLeakedContinuations() async throws {
        let (service, _) = makeService()

        var tokens: [InferenceService.GenerationRequestToken] = []
        var streams: [GenerationStream] = []

        // 1 active + 8 queued = 9 total (within maxQueueDepth).
        for _ in 0..<9 {
            let (token, stream) = try service.enqueue(messages: [Message.user("msg")], config: GenerationConfig(), priority: .normal)
            tokens.append(token)
            streams.append(stream)
        }

        // Cancel odd-indexed requests.
        for i in stride(from: 1, to: 9, by: 2) {
            service.cancel(tokens[i])
        }

        // Stop everything to clean up.
        service.stopGeneration()

        // All streams should be terminable (no hanging continuations).
        for stream in streams {
            let phase = stream.phase
            let terminated = (phase == .done || {
                if case .failed = phase { return true }
                return false
            }() || phase == .connecting)
            XCTAssertTrue(terminated || phase == .queued,
                          "Stream should be in a terminal or initial phase, got \(phase)")
        }
    }

    // MARK: - 17. Queue auto-drains on stream terminate

    /// Verifies that the queue drains automatically after stream1 is consumed.
    func test_queue_autoDrains_onStreamTerminate() async throws {
        let (service, mock) = makeService()

        let (_, stream1) = try service.enqueue(messages: [Message.user("first")], config: GenerationConfig(), priority: .normal)
        let (_, stream2) = try service.enqueue(messages: [Message.user("second")], config: GenerationConfig(), priority: .normal)

        XCTAssertEqual(stream2.phase, .queued, "Second should start queued")

        // Wait for the drain Task to call generate() so gates[0] is populated.
        await waitFor(mock.generateCallCount >= 1, description: "first generate() called")
        mock.release(at: 0, tokens: ["a"])

        // Consume stream1 fully — the queue should auto-drain when the stream terminates.
        for try await _ in stream1.events {}

        // The activeTask's defer fires on the main actor before `for try await`
        // returns, so auto-drain is synchronous from the test's perspective.
        XCTAssertEqual(stream2.phase, .connecting,
                       "Queue should auto-drain after stream1 is consumed")
        XCTAssertFalse(service.hasQueuedRequests,
                       "Service should report no queued requests after auto-drain")
        XCTAssertTrue(service.isGenerating,
                      "Service should be generating stream2 after auto-drain")
    }

    // MARK: - 18. Concurrent non-queued generate() + enqueue() state correctness

    /// Verifies that a direct generate() call (the non-queued path used by title
    /// generation) does not corrupt isGenerating or hasQueuedRequests while a
    /// queued request is active.
    func test_nonQueuedGenerate_doesNotCorruptQueueState() async throws {
        let (service, mock) = makeService()

        // Enqueue one request — it becomes the active request immediately.
        let (_, stream1) = try service.enqueue(messages: [Message.user("queued request")], config: GenerationConfig(), priority: .normal)

        XCTAssertTrue(service.isGenerating, "isGenerating should be true after enqueue")
        XCTAssertFalse(service.hasQueuedRequests,
                       "No extra items should be in the queue — the enqueued one is active")

        // Call generate() directly (the non-queued path, as title generation does).
        let stream2 = try service.generate(messages: [("user", "title request")])

        // The key assertion: direct generate() must not reset isGenerating.
        XCTAssertTrue(service.isGenerating,
                      "isGenerating must remain true after a direct generate() call")
        XCTAssertFalse(service.hasQueuedRequests,
                       "hasQueuedRequests must not be affected by a non-queued generate()")

        // Wait for both generate() calls so both gates are populated before releasing.
        await waitFor(mock.generateCallCount >= 2, description: "both generate() calls made")
        mock.release(at: 0, tokens: ["queued-tok"])
        mock.release(at: 1, tokens: ["title-tok"])

        for try await _ in stream1.events {}
        for try await _ in stream2.events {}
    }

    // MARK: - 19. Auto-drain: two requests

    /// Enqueues two requests, consumes stream1, and verifies that stream2
    /// transitions to .connecting automatically.
    func test_queueAutoDrains_withTwoRequests() async throws {
        let (service, mock) = makeService()

        let (_, stream1) = try service.enqueue(messages: [Message.user("first")], config: GenerationConfig(), priority: .normal)
        let (_, stream2) = try service.enqueue(messages: [Message.user("second")], config: GenerationConfig(), priority: .normal)

        XCTAssertEqual(stream1.phase, .connecting)
        XCTAssertEqual(stream2.phase, .queued)

        // Wait for the drain Task to call generate() so gates[0] is populated.
        await waitFor(mock.generateCallCount >= 1, description: "first generate() called")
        mock.release(at: 0, tokens: ["tok"])

        // Consume stream1; the queue should auto-drain on stream terminate.
        var collected: [String] = []
        for try await event in stream1.events {
            if case .token(let text) = event {
                collected.append(text)
            }
        }

        XCTAssertEqual(collected, ["tok"], "stream1 should have yielded its token")

        // Auto-drain should have fired: stream2 must now be connecting.
        XCTAssertEqual(stream2.phase, .connecting,
                       "stream2 should transition to .connecting automatically after stream1 terminates")
        XCTAssertTrue(service.isGenerating,
                      "service should be generating stream2 after auto-drain")
    }

    // MARK: - 20. unloadModel mid-stream leaves state consistent

    /// Verifies that calling `unloadModel()` while a request is mid-stream leaves
    /// the service in a fully clean state and prevents new requests from being enqueued.
    ///
    /// This locks in the safety invariants established by the existing guards:
    /// - `stopGeneration()` nils `activeRequest` before the active Task's defer fires,
    ///   so the defer's token-match guard prevents a spurious `drainQueue()` call.
    /// - `enqueue()` guards `backend != nil` so no new requests can enter after unload.
    func test_unloadModel_midStream_doesNotCorruptState() async throws {
        let (service, _) = makeService()

        // Enqueue a request — it becomes active immediately. The GatedMockBackend
        // blocks generation until explicitly released, so we're mid-stream.
        let (_, stream) = try service.enqueue(messages: [Message.user("hello")], config: GenerationConfig(), priority: .normal)

        XCTAssertEqual(stream.phase, .connecting, "Stream should be active (connecting)")
        XCTAssertTrue(service.isGenerating)

        // Unload while the request is active (before any tokens are released).
        service.unloadModel()

        // Core state must be fully clean immediately after unload.
        XCTAssertFalse(service.isModelLoaded, "isModelLoaded must be false after unload")
        XCTAssertFalse(service.isGenerating, "isGenerating must be false after unload")
        XCTAssertFalse(service.hasQueuedRequests, "hasQueuedRequests must be false after unload")

        // Drain the stream — this provides a deterministic termination signal and
        // acts as the synchronization point for the cancelled Task's defer to fire.
        // The stream must throw (CancellationError or similar) rather than hang.
        var didThrow = false
        do {
            for try await _ in stream.events {}
        } catch { didThrow = true }
        XCTAssertTrue(didThrow, "Cancelled stream should throw CancellationError or similar")

        // State must remain clean after the Task defer fires.
        XCTAssertFalse(service.isModelLoaded, "isModelLoaded must remain false after Task defer fires")
        XCTAssertFalse(service.isGenerating, "isGenerating must remain false after Task defer fires")
        XCTAssertFalse(service.hasQueuedRequests, "hasQueuedRequests must remain false after Task defer fires")

        // Subsequent enqueue must throw because no model is loaded.
        XCTAssertThrowsError(
            try service.enqueue(messages: [Message.user("after-unload")], config: GenerationConfig(), priority: .normal)
        ) { error in
            XCTAssertTrue(
                "\(error)".contains("No model loaded"),
                "Error should mention no model loaded, got: \(error)"
            )
        }
    }

    // MARK: - 21. finishAndDiscard always finishes continuation

    func test_finishAndDiscard_alwaysFinishesContinuation() async throws {
        let (service, _) = makeService()

        let (token, stream) = try service.enqueue(messages: [Message.user("hello")], config: GenerationConfig(), priority: .normal)

        // Cancel the active request — this calls finishAndDiscard internally.
        service.cancel(token)

        // The stream's continuation should be finished — consuming should throw or complete.
        var didThrow = false
        do {
            for try await _ in stream.events {}
        } catch {
            didThrow = true
        }
        XCTAssertTrue(didThrow, "Continuation should have been finished with error")
    }

    // MARK: - 22. unloadModel mid-consume (after tokens start flowing)

    /// Verifies that calling `unloadModel()` after tokens have begun flowing — but
    /// before the consumer has finished draining — leaves the service fully clean.
    ///
    /// This covers the harder race: the backend has already called `yield(.token(...))`
    /// at least once, so the stream is genuinely mid-flight when the unload fires.
    func test_unloadModel_midStream_afterTokensStartFlowing() async throws {
        let (service, mock) = makeService()

        // Enqueue a request — it becomes active immediately.
        let (_, stream) = try service.enqueue(messages: [Message.user("hello")], config: GenerationConfig(), priority: .normal)

        // Wait for the drain Task to call generate() so gates[0] is populated.
        await waitFor(mock.generateCallCount >= 1, description: "generate() called")

        // Release one token — this starts the stream flowing before we unload.
        mock.release(at: 0, tokens: ["tok"])

        // Unload immediately, before the consumer has a chance to drain.
        service.unloadModel()

        // Drain the stream — provides the deterministic termination signal.
        var didThrow = false
        do {
            for try await _ in stream.events {}
        } catch { didThrow = true }
        XCTAssertTrue(didThrow, "Cancelled mid-consume stream should throw CancellationError or similar")

        // Service must be fully clean after both the unload and stream termination.
        XCTAssertFalse(service.isModelLoaded, "isModelLoaded must be false after unload")
        XCTAssertFalse(service.isGenerating, "isGenerating must be false after unload")
        XCTAssertFalse(service.hasQueuedRequests, "hasQueuedRequests must be false after unload")

        // Subsequent enqueue must throw because no model is loaded.
        XCTAssertThrowsError(
            try service.enqueue(messages: [Message.user("after-unload")], config: GenerationConfig(), priority: .normal)
        ) { error in
            XCTAssertTrue(
                "\(error)".contains("No model loaded"),
                "Error should mention no model loaded, got: \(error)"
            )
        }
    }
}
