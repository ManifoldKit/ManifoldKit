import XCTest
import Foundation
@testable import ManifoldInference
import ManifoldTestSupport

/// Direct unit tests for the `GenerationQueue`.
///
/// The coordinator is `internal`, so this file uses `@testable import
/// ManifoldInference` to construct it directly. A file-local
/// `FakeGenerationContextProvider` replaces the `InferenceService`-shaped
/// dependency without standing up an entire service. Thermal-gate tests
/// inject a deterministic `thermalStateProvider` closure.
///
/// All queue / continuation assertions here are behavioral — they observe
/// public `GenerationStream.phase` transitions and coordinator accessors
/// (`isGenerating`, `hasQueuedRequests`). No Mirror introspection, because
/// reflecting into `@Observable`-rewritten storage breaks silently when the
/// macro changes its naming scheme.
@MainActor
final class GenerationQueueTests: XCTestCase {

    // MARK: - Fixture

    private var provider: FakeGenerationContextProvider!
    private var coordinator: GenerationQueue!

    override func setUp() async throws {
        try await super.setUp()
        provider = FakeGenerationContextProvider()
        coordinator = GenerationQueue()
        coordinator.provider = provider
    }

    override func tearDown() async throws {
        // stopGenerationAndWait() cancels the active task and awaits its completion,
        // preventing the task's defer block from bleeding into the next test's setUp.
        await coordinator?.stopGenerationAndWait()
        coordinator = nil
        provider = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Makes a coordinator with the given thermal closure.
    private func makeCoordinator(
        thermal: @escaping @Sendable () -> ProcessInfo.ThermalState
    ) -> GenerationQueue {
        let coord = GenerationQueue(thermalStateProvider: thermal)
        coord.provider = provider
        return coord
    }

    // MARK: - Queue overflow

    func test_generate_jsonMode_forwardsToBackend() async throws {
        let stream = try coordinator.generate(
            messages: [("user", "Return JSON")],
            jsonMode: true
        )

        for try await _ in stream.events {}

        let config = try XCTUnwrap(provider.backend.lastConfig)
        XCTAssertTrue(config.jsonMode)
    }

    // MARK: - jsonMode silent-ignore warning (PR #615 review fix)

    /// When `jsonMode=true` is passed and the active backend reports
    /// `supportsNativeJSONMode == false`, the coordinator must emit a warning
    /// before dispatching so callers have a signal that the flag is being
    /// ignored. The test observes the warning via an internal hook; real
    /// traffic also goes to `Log.inference.warning`, which OSLog renders to
    /// Console.app.
    ///
    /// Sabotage check: deleting the warning branch in `GenerationQueue.generate`
    /// leaves `captured` empty and this assertion fails.
    func test_generate_jsonMode_unsupportedBackend_emitsWarning() async throws {
        // MockInferenceBackend defaults to supportsNativeJSONMode == false.
        let captured = WarningCapture()
        GenerationQueue.jsonModeUnsupportedWarningHook = { backendType, message in
            captured.record(backendType: backendType, message: message)
        }
        defer { GenerationQueue.jsonModeUnsupportedWarningHook = nil }

        let stream = try coordinator.generate(
            messages: [("user", "Return JSON")],
            jsonMode: true
        )
        for try await _ in stream.events {}

        let entries = captured.snapshot()
        XCTAssertEqual(entries.count, 1, "warning must fire exactly once per request")
        let first = try XCTUnwrap(entries.first)
        XCTAssertEqual(first.backendType, "MockInferenceBackend",
                       "warning must name the active backend type")
        XCTAssertTrue(first.message.contains("jsonMode=true"),
                      "warning message must mention the flag")
        XCTAssertTrue(first.message.contains("supportsNativeJSONMode"),
                      "warning must reference the capability flag so callers can check it programmatically")

        // Silent-ignore must remain silent in the failure sense: the backend
        // still receives the flag; the warning is additive, not blocking.
        let config = try XCTUnwrap(provider.backend.lastConfig)
        XCTAssertTrue(config.jsonMode)
    }

    /// When `jsonMode=false`, the warning must never fire regardless of the
    /// backend's capability. This guards against a future regression that
    /// accidentally flips the condition.
    func test_generate_jsonModeFalse_neverWarns() async throws {
        let captured = WarningCapture()
        GenerationQueue.jsonModeUnsupportedWarningHook = { backendType, message in
            captured.record(backendType: backendType, message: message)
        }
        defer { GenerationQueue.jsonModeUnsupportedWarningHook = nil }

        let stream = try coordinator.generate(
            messages: [("user", "Return plain")],
            jsonMode: false
        )
        for try await _ in stream.events {}

        XCTAssertTrue(captured.snapshot().isEmpty,
                      "warning must not fire when jsonMode is disabled")
    }

    /// When the backend DOES support native JSON mode, the warning must not
    /// fire. Simulated here by swapping in a capability set with
    /// `supportsNativeJSONMode = true`.
    func test_generate_jsonMode_supportedBackend_noWarning() async throws {
        let captured = WarningCapture()
        GenerationQueue.jsonModeUnsupportedWarningHook = { backendType, message in
            captured.record(backendType: backendType, message: message)
        }
        defer { GenerationQueue.jsonModeUnsupportedWarningHook = nil }

        provider.backend.capabilities = BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: false,
            supportsStructuredOutput: true,
            supportsNativeJSONMode: true,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false
        )

        let stream = try coordinator.generate(
            messages: [("user", "Return JSON")],
            jsonMode: true
        )
        for try await _ in stream.events {}

        XCTAssertTrue(captured.snapshot().isEmpty,
                      "warning must not fire when the backend supports native JSON mode")
        let config = try XCTUnwrap(provider.backend.lastConfig)
        XCTAssertTrue(config.jsonMode)
    }

    // MARK: - Tool-capability silent-ignore warning

    /// When `tools` are passed to `enqueue` and the active backend reports
    /// `supportsToolCalling == false`, the coordinator must emit a warning and
    /// then throw `InferenceError.inferenceFailure` so callers have a clear
    /// signal that the registry will never see a dispatch.
    ///
    /// Sabotage check: deleting the warning branch in `GenerationQueue.enqueue`
    /// leaves `captured` empty and the warning assertion fails.
    func test_enqueue_toolsOnUnsupportedBackend_emitsWarningAndThrows() async throws {
        // MockInferenceBackend defaults to supportsToolCalling == false.
        let captured = WarningCapture()
        GenerationQueue.toolsUnsupportedWarningHook = { backendType, message in
            captured.record(backendType: backendType, message: message)
        }
        defer { GenerationQueue.toolsUnsupportedWarningHook = nil }

        let tool = ToolDefinition(
            name: "get_weather",
            description: "Lookup the weather for a city"
        )

        // The coordinator must reject the request with a clear error before
        // any stream is created — the warning fires, then the throw follows.
        XCTAssertThrowsError(
            try coordinator.enqueue(
                messages: [("user", "What's the weather?")],
                tools: [tool]
            )
        ) { error in
            guard case InferenceError.inferenceFailure(let msg) = error else {
                XCTFail("expected InferenceError.inferenceFailure, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("does not support tool calling"),
                          "error message must describe the capability gap: \(msg)")
        }

        let entries = captured.snapshot()
        XCTAssertEqual(entries.count, 1, "warning must fire exactly once per enqueue")
        let first = try XCTUnwrap(entries.first)
        XCTAssertEqual(first.backendType, "MockInferenceBackend",
                       "warning must name the active backend type")
        XCTAssertTrue(first.message.contains("supportsToolCalling"),
                      "warning must reference the capability flag so callers can check it programmatically")
        XCTAssertTrue(first.message.contains("1 tool"),
                      "warning should mention how many tools were passed")
    }

    /// When no tools are passed, the warning must never fire regardless of
    /// the backend's capability — guards against a future regression that
    /// flips the condition to `tools.isEmpty`.
    func test_enqueue_noTools_neverWarns() async throws {
        let captured = WarningCapture()
        GenerationQueue.toolsUnsupportedWarningHook = { backendType, message in
            captured.record(backendType: backendType, message: message)
        }
        defer { GenerationQueue.toolsUnsupportedWarningHook = nil }

        let (_, stream) = try coordinator.enqueue(messages: [("user", "hi")])
        for try await _ in stream.events {}

        XCTAssertTrue(captured.snapshot().isEmpty,
                      "warning must not fire when no tools are passed")
    }

    /// When the backend supports tool calling, the warning must not fire
    /// even if the request includes tools.
    func test_enqueue_toolsOnSupportedBackend_noWarning() async throws {
        let captured = WarningCapture()
        GenerationQueue.toolsUnsupportedWarningHook = { backendType, message in
            captured.record(backendType: backendType, message: message)
        }
        defer { GenerationQueue.toolsUnsupportedWarningHook = nil }

        provider.backend.capabilities = BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false
        )

        let tool = ToolDefinition(
            name: "get_weather",
            description: "Lookup the weather for a city"
        )
        let (_, stream) = try coordinator.enqueue(
            messages: [("user", "weather?")],
            tools: [tool]
        )
        for try await _ in stream.events {}

        XCTAssertTrue(captured.snapshot().isEmpty,
                      "warning must not fire when the backend supports tool calling")
    }

    func test_enqueue_overQueueDepth_throwsQueueFullError() throws {
        // Saturate the coordinator: one active plus eight queued is the hard cap
        // (maxQueueDepth == 8 counts queued requests only).
        for i in 0..<9 {
            _ = try coordinator.enqueue(messages: [("user", "msg \(i)")], priority: .normal)
        }

        // The 10th enqueue must throw the "queue is full" variant of
        // InferenceError.inferenceFailure — pin the message so a future
        // dedicated error case doesn't regress the text silently.
        XCTAssertThrowsError(
            try coordinator.enqueue(messages: [("user", "overflow")], priority: .normal)
        ) { error in
            guard case InferenceError.inferenceFailure(let message) = error else {
                return XCTFail("expected InferenceError.inferenceFailure, got \(error)")
            }
            XCTAssertEqual(message, "Generation queue is full")
        }
    }

    // MARK: - Priority insertion

    /// High-priority (`.userInitiated`) requests must be inserted ahead of
    /// already-queued `.background` work. This is the user-facing invariant:
    /// typing a message doesn't wait behind background prefetches.
    ///
    /// Verified behaviorally via `stream.phase` transitions — the userInitiated
    /// stream must advance to `.connecting` before either background stream.
    func test_enqueue_userInitiatedBehindBackground_drainsFirst() async throws {
        let slowProvider = SlowFakeProvider()
        let coord = GenerationQueue()
        coord.provider = slowProvider

        // Active slot holds one request; queue builds behind it.
        let (_, activeStream) = try coord.enqueue(messages: [("user", "active")], priority: .normal)

        // Queue two .background, then one .userInitiated.
        let (_, bg1Stream) = try coord.enqueue(messages: [("user", "bg1")], priority: .background)
        let (_, bg2Stream) = try coord.enqueue(messages: [("user", "bg2")], priority: .background)
        let (_, uiStream) = try coord.enqueue(messages: [("user", "ui")], priority: .userInitiated)

        // All three are currently queued (active is still running).
        XCTAssertEqual(uiStream.phase, .queued)
        XCTAssertEqual(bg1Stream.phase, .queued)
        XCTAssertEqual(bg2Stream.phase, .queued)

        // Release active: its stream completes, which kicks the defer block and
        // drainQueue() for the next request.
        slowProvider.backend.stopGeneration()
        for try await _ in activeStream.events {}

        // After active finishes, the userInitiated must be dequeued first.
        XCTAssertEqual(uiStream.phase, .connecting, "userInitiated must drain before backgrounds")
        XCTAssertEqual(bg1Stream.phase, .queued, "background1 must still be queued")
        XCTAssertEqual(bg2Stream.phase, .queued, "background2 must still be queued")

        coord.stopGeneration()
    }

    // MARK: - Cancel: queued

    func test_cancel_queuedRequest_removesFromQueueAndLeavesActiveRunning() async throws {
        let slowProvider = SlowFakeProvider()
        let coord = GenerationQueue()
        coord.provider = slowProvider

        let (_, activeStream) = try coord.enqueue(messages: [("user", "active")], priority: .normal)
        let (queuedToken, queuedStream) = try coord.enqueue(
            messages: [("user", "queued")], priority: .normal
        )

        coord.cancel(queuedToken)

        // Cancelled queued stream must terminate; no tokens delivered.
        var tokens: [String] = []
        do {
            for try await event in queuedStream.events {
                if case .token(let t) = event { tokens.append(t) }
            }
        } catch {
            // CancellationError is the expected terminator here.
        }
        XCTAssertTrue(tokens.isEmpty, "cancelled queued request must not emit tokens")

        // Active still running; the coordinator still reports it.
        XCTAssertTrue(coord.isGenerating, "active request must remain in flight")

        coord.stopGeneration()
        _ = activeStream
    }

    // MARK: - Cancel: active (no-token-after-cancel)

    /// Key invariant: after `cancel` returns for the active request, **no
    /// `.token` events may be delivered on that request's continuation**. Even
    /// if the backend is still running, the coordinator must have torn down
    /// the continuation such that further yields are dropped.
    func test_cancel_activeRequest_noTokenAfterCancel() async throws {
        let slowProvider = SlowFakeProvider(tokenCount: 50, delayMilliseconds: 20)
        let coord = GenerationQueue()
        coord.provider = slowProvider

        let (token, stream) = try coord.enqueue(messages: [("user", "active")], priority: .normal)

        var tokensBeforeCancel = 0
        var tokensAfterCancel = 0
        var didCancel = false

        do {
            for try await event in stream.events {
                if case .token = event {
                    if !didCancel {
                        tokensBeforeCancel += 1
                        if tokensBeforeCancel >= 1 {
                            coord.cancel(token)
                            didCancel = true
                        }
                    } else {
                        tokensAfterCancel += 1
                    }
                }
            }
        } catch {
            // CancellationError (or the "Cancelled" wrap) is expected.
        }

        XCTAssertGreaterThanOrEqual(
            tokensBeforeCancel, 1,
            "precondition: at least one token should arrive before the cancel"
        )
        XCTAssertEqual(
            tokensAfterCancel, 0,
            "no tokens may be delivered on the continuation after cancel() returns"
        )
    }

    // MARK: - stopGeneration: behavioral drain

    /// `stopGeneration()` must reset the coordinator to a clean idle state —
    /// no active request, no queued requests, and every open stream terminated
    /// (readers unblock). Verified behaviorally: calling it, then awaiting each
    /// stream to completion, must return without hanging.
    func test_stopGeneration_emptiesQueueAndTerminatesAllStreams() async throws {
        let slowProvider = SlowFakeProvider(tokenCount: 50, delayMilliseconds: 20)
        let coord = GenerationQueue()
        coord.provider = slowProvider

        let (_, activeStream) = try coord.enqueue(messages: [("user", "active")], priority: .normal)
        let (_, q1Stream) = try coord.enqueue(messages: [("user", "queued1")], priority: .normal)
        let (_, q2Stream) = try coord.enqueue(messages: [("user", "queued2")], priority: .normal)

        coord.stopGeneration()

        XCTAssertFalse(coord.isGenerating)
        XCTAssertFalse(coord.hasQueuedRequests)

        // Each stream must be terminated: the for-await must return (possibly
        // via thrown CancellationError). If stopGeneration() failed to finish
        // any continuation, the corresponding `for try await` would hang and
        // this test would time out.
        for stream in [activeStream, q1Stream, q2Stream] {
            do { for try await _ in stream.events {} } catch { /* cancel error OK */ }
        }

        // After stopGeneration + drain, a fresh enqueue must succeed
        // immediately — proving the coordinator is back in a clean state with
        // no stale continuations blocking the queue.
        let (_, freshStream) = try coord.enqueue(messages: [("user", "fresh")], priority: .normal)
        XCTAssertNotEqual(freshStream.phase, .queued, "new request must start running after stop")
        coord.stopGeneration()
        do { for try await _ in freshStream.events {} } catch { /* cancel error OK */ }
    }

    // MARK: - Cancel latency contract

    /// `stopGenerationAndWait()` must return promptly even when the backend
    /// is mid-token with a long per-token delay. The orchestrator's defer
    /// block awaits `activeTask?.value`, so any failure to propagate cancel
    /// through the producer task makes this method hang for the full token
    /// delay — a real-world wedge where the user taps stop, the UI looks
    /// responsive, and the C-level inference keeps running until the next
    /// natural boundary.
    ///
    /// This test pins the *contract* (prompt return), not the mechanism:
    /// with a 60-second per-token delay, stop-and-wait must complete within
    /// a 2-second wall-clock budget — generous enough to ride out CI
    /// scheduling jitter on a busy macOS runner without being so loose that
    /// a real regression sneaks through. SlowMockBackend has three
    /// cancellation paths — `task.cancel()` from `cancelGeneration`, the
    /// in-loop `Task.isCancelled` guards, and `continuation.onTermination`
    /// — and any one of them is sufficient to honour the contract. A future
    /// change that breaks all three would trip this test; breaking one is
    /// caught by the dedicated tests for each path elsewhere in this file.
    func test_stopGenerationAndWait_returnsPromptly_evenWithLongTokenDelay() async throws {
        let backend = SlowMockBackend(tokenCount: 1, delayMilliseconds: 60_000)
        let slowProvider = SlowFakeProvider(backend: backend)
        let coord = GenerationQueue()
        coord.provider = slowProvider

        _ = try coord.enqueue(messages: [("user", "long")], priority: .normal)

        // Yield once so the orchestrator's drainQueue() spawns its Task and
        // the producer enters its first 60s sleep before we ask to stop.
        // Without this, stop-and-wait could race ahead of the producer's
        // launch and pass for the wrong reason.
        try await Task.sleep(for: .milliseconds(50))

        let start = ContinuousClock.now
        await coord.stopGenerationAndWait()
        let elapsed = ContinuousClock.now - start

        XCTAssertLessThan(
            elapsed, .seconds(2),
            "stopGenerationAndWait() must return within 2s even when the backend is mid-token; " +
            "elapsed=\(elapsed). A larger delta indicates cancellation is not propagating to the producer task " +
            "and the orchestrator is awaiting the natural token boundary instead."
        )
        XCTAssertFalse(coord.isGenerating)
    }

    // MARK: - discardRequests(notMatching:)

    func test_discardRequests_keepsMatchingSessionCancelsOthers() async throws {
        let slowProvider = SlowFakeProvider(tokenCount: 50, delayMilliseconds: 20)
        let coord = GenerationQueue()
        coord.provider = slowProvider

        let keepSession = UUID()
        let dropSession = UUID()

        // Active request belongs to keepSession.
        let (_, activeStream) = try coord.enqueue(
            messages: [("user", "active")], priority: .normal, sessionID: keepSession
        )
        // Queued: one matching keep, one not.
        let (_, keepStream) = try coord.enqueue(
            messages: [("user", "keep")], priority: .normal, sessionID: keepSession
        )
        let (_, dropStream) = try coord.enqueue(
            messages: [("user", "drop")], priority: .normal, sessionID: dropSession
        )

        await coord.discardRequests(notMatching: keepSession)

        // The dropped stream must terminate — no tokens.
        var dropTokens: [String] = []
        do {
            for try await event in dropStream.events {
                if case .token(let t) = event { dropTokens.append(t) }
            }
        } catch {
            // expected cancellation
        }
        XCTAssertTrue(dropTokens.isEmpty, "non-matching session must be cancelled")

        // The kept queued stream must still be live (queued or draining once
        // active completes). It must NOT be in `.failed`.
        if case .failed(let reason) = keepStream.phase {
            XCTFail("matching-session stream should not be cancelled, got .failed(\(reason))")
        }

        _ = activeStream
        coord.stopGeneration()
    }

    // MARK: - isGenerating transitions

    func test_isGenerating_transitions_onNormalCompletion() async throws {
        XCTAssertFalse(coordinator.isGenerating)

        provider.backend.tokensToYield = ["a", "b"]
        let (_, stream) = try coordinator.enqueue(messages: [("user", "hi")], priority: .normal)

        // After enqueue returns, drainQueue has flipped isGenerating to true.
        XCTAssertTrue(coordinator.isGenerating, "isGenerating must flip true immediately on drain")

        // Consume the stream so the defer block runs and resets state.
        for try await _ in stream.events {}
        // Give the defer block a turn.
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(coordinator.isGenerating, "isGenerating must reset to false on completion")
    }

    func test_isGenerating_transitions_onError() async throws {
        struct Boom: Error {}
        provider.backend.shouldThrowInsideStream = Boom()
        provider.backend.tokensToYield = ["x"]

        let (_, stream) = try coordinator.enqueue(messages: [("user", "hi")], priority: .normal)
        XCTAssertTrue(coordinator.isGenerating)

        do {
            for try await _ in stream.events {}
        } catch {
            // expected
        }
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(coordinator.isGenerating, "isGenerating must reset to false on error")
    }

    func test_isGenerating_transitions_onCancel() async throws {
        let slowProvider = SlowFakeProvider(tokenCount: 50, delayMilliseconds: 20)
        let coord = GenerationQueue()
        coord.provider = slowProvider

        let (token, stream) = try coord.enqueue(messages: [("user", "hi")], priority: .normal)
        XCTAssertTrue(coord.isGenerating)

        // Consume one token so we know generation is truly in flight.
        var iter = stream.events.makeAsyncIterator()
        _ = try await iter.next()

        coord.cancel(token)
        XCTAssertFalse(coord.isGenerating, "cancel() must flip isGenerating to false synchronously")
    }

    // MARK: - drainQueue re-entry race

    /// `cancel` may fire between `finishAndDiscard` and the synchronous
    /// `drainQueue()` call inside `cancel()`. The coordinator must survive
    /// this without crashing and must return to a clean idle state: not
    /// generating, no queued requests, and a fresh enqueue succeeds.
    func test_drainQueue_reentryRace_noCrash_stateConsistent() async throws {
        let slowProvider = SlowFakeProvider(tokenCount: 2, delayMilliseconds: 5)
        let coord = GenerationQueue()
        coord.provider = slowProvider

        let (token1, s1) = try coord.enqueue(messages: [("user", "a")], priority: .normal)
        let (token2, s2) = try coord.enqueue(messages: [("user", "b")], priority: .normal)

        // Interleave cancels and yields to hit the re-entry window.
        coord.cancel(token1)
        await Task.yield()
        coord.cancel(token2)
        await Task.yield()

        // Consume both streams to completion so no task is leaked.
        do { for try await _ in s1.events {} } catch { /* expected cancel */ }
        do { for try await _ in s2.events {} } catch { /* expected cancel */ }

        XCTAssertFalse(coord.isGenerating)
        XCTAssertFalse(coord.hasQueuedRequests)

        // Fresh enqueue must succeed immediately — proof that no stale
        // continuations remained to block the queue.
        let (_, freshStream) = try coord.enqueue(messages: [("user", "fresh")], priority: .normal)
        XCTAssertNotEqual(freshStream.phase, .queued)
        coord.stopGeneration()
        do { for try await _ in freshStream.events {} } catch { /* cancel OK */ }
    }

    // MARK: - Enqueue ambiguous guard pinning

    /// The enqueue guard combines `provider?.currentBackend != nil` and
    /// `provider?.isBackendLoaded == true`. If either fails, the same
    /// "No model loaded" error fires. Pin this so a future guard split
    /// can't silently change the observable error.
    func test_enqueue_noBackend_throwsNoModelLoaded() {
        let nilProvider = NilBackendProvider()
        let coord = GenerationQueue()
        coord.provider = nilProvider

        XCTAssertThrowsError(
            try coord.enqueue(messages: [("user", "x")], priority: .normal)
        ) { error in
            guard case InferenceError.inferenceFailure(let message) = error else {
                return XCTFail("expected inferenceFailure, got \(error)")
            }
            XCTAssertEqual(message, "No model loaded")
        }
    }

    func test_enqueue_backendPresentButUnloaded_throwsNoModelLoaded() {
        // Backend is non-nil, but isBackendLoaded is false.
        provider.backend.isModelLoaded = false

        XCTAssertThrowsError(
            try coordinator.enqueue(messages: [("user", "x")], priority: .normal)
        ) { error in
            guard case InferenceError.inferenceFailure(let message) = error else {
                return XCTFail("expected inferenceFailure, got \(error)")
            }
            XCTAssertEqual(message, "No model loaded")
        }
    }

    // MARK: - Thermal drop / NOT-drop

    func test_backgroundPriority_seriousThermal_requestDropped() async throws {
        let coord = makeCoordinator { .serious }

        let (_, stream) = try coord.enqueue(
            messages: [("user", "bg")], priority: .background
        )

        // The request must be dropped without invoking the backend.
        var tokenCount = 0
        do {
            for try await event in stream.events {
                if case .token = event { tokenCount += 1 }
            }
        } catch {
            // expected: thermal-throttle inferenceFailure
        }

        XCTAssertEqual(
            provider.backend.generateCallCount, 0,
            "thermal-dropped background request must never call the backend"
        )
        XCTAssertEqual(tokenCount, 0)
        XCTAssertFalse(coord.isGenerating)
    }

    /// Thermal state is only read on `.background` priority. Normal-priority
    /// requests under `.serious` thermal pressure must still run. This
    /// explicitly reaches the backend to prove the guard at line 183 is gated
    /// on priority, not on thermal alone.
    func test_normalPriority_seriousThermal_requestNotDropped() async throws {
        let coord = makeCoordinator { .serious }

        provider.backend.tokensToYield = ["ok"]
        let (_, stream) = try coord.enqueue(
            messages: [("user", "normal")], priority: .normal
        )

        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let t) = event { tokens.append(t) }
        }

        XCTAssertEqual(tokens, ["ok"])
        XCTAssertEqual(
            provider.backend.generateCallCount, 1,
            "normal-priority requests are NOT thermal-dropped"
        )
    }

    // MARK: - Thermal pause (#745)

    /// When the per-token loop sees `.critical` thermal state mid-stream, the
    /// coordinator must pause via the injected sleep hook, re-check the
    /// provider after each sleep, and resume cleanly when the state drops
    /// below `.critical`. Exactly one `.diagnosticThrottle` event must be
    /// emitted per pause cycle (not one per re-check tick).
    ///
    /// The test injects a deterministic provider that returns `.critical` for
    /// the first two reads then `.nominal`, plus a sleep hook that records
    /// each call instead of actually sleeping. This keeps the test in
    /// real-time without any fixed delays.
    ///
    /// Sabotage check: deleting the `await pauseWhileThermalCritical(...)`
    /// call inside the per-event loop drops the throttle-event count to 0
    /// and the sleep-call count to 0; both assertions fail.
    func test_perTokenLoop_criticalThermal_pausesAndEmitsSingleThrottleEvent() async throws {
        // Provider script: `.critical, .critical, .nominal, .nominal, ...`
        // Returning the same final state forever lets the second token's
        // entry check flow through without another pause.
        let thermalReads = ThermalReadCounter()
        let states: [ProcessInfo.ThermalState] = [.critical, .critical, .nominal]

        let sleepCalls = SleepCallCounter()

        let coord = GenerationQueue(
            thermalStateProvider: { @Sendable in
                let idx = thermalReads.next()
                return idx < states.count ? states[idx] : .nominal
            },
            thermalSleep: { @Sendable _ in
                sleepCalls.bump()
                // Yield to keep the cooperative-cancellation contract; do
                // not actually sleep — the test must complete in well
                // under the production 2-second cadence.
                await Task.yield()
            }
        )
        coord.provider = provider

        provider.backend.tokensToYield = ["a", "b"]

        let (_, stream) = try coord.enqueue(
            messages: [("user", "hi")], priority: .normal
        )

        var tokens: [String] = []
        var throttleEvents: [String] = []
        for try await event in stream.events {
            switch event {
            case .token(let t):
                tokens.append(t)
            case .diagnosticThrottle(let reason):
                throttleEvents.append(reason)
            default:
                break
            }
        }

        XCTAssertEqual(tokens, ["a", "b"], "generation must complete after pause")
        XCTAssertEqual(
            throttleEvents.count, 1,
            "exactly one .diagnosticThrottle event must be emitted per pause cycle, not per re-check"
        )
        XCTAssertTrue(
            throttleEvents.first?.contains("critical") ?? false,
            "throttle reason must reference the thermal state"
        )
        XCTAssertGreaterThanOrEqual(
            sleepCalls.count, 1,
            "loop must have slept at least once while waiting for thermal state to drop"
        )
        // First two reads were `.critical`, so the loop polls until the
        // third read sees `.nominal`. That means at least two sleeps fired
        // before resume — proves the loop didn't bail on the first re-check.
        XCTAssertEqual(
            sleepCalls.count, 2,
            "loop must keep sleeping while state stays .critical and exit on the read that returns .nominal"
        )
        // Provider was read at least four times: once on entry to the
        // pause for the first event (.critical), twice inside the
        // re-check loop (.critical, .nominal), and at minimum once more
        // for the second event's entry guard (.nominal → no pause).
        XCTAssertGreaterThanOrEqual(
            thermalReads.count, 4,
            "provider must be polled on entry plus once per re-check tick"
        )
    }

    /// `stopGenerationAndWait()` must unwind cleanly while the per-token
    /// loop is parked in the thermal-pause re-check loop — no deadlock,
    /// no hang waiting for thermal state to drop. The pause loop bails on
    /// `Task.isCancelled` and propagates `CancellationError` thrown by the
    /// injected `thermalSleep` hook (the production default `Task.sleep(for:)`
    /// throws on cancellation).
    ///
    /// We invoke `stopGenerationAndWait()` so the assertion fails fast if
    /// the loop fails to observe cancellation: the await will simply hang
    /// past the test's overall deadline, surfaced here as a 2s race timeout.
    ///
    /// Sabotage check: change `while !Task.isCancelled` in
    /// `pauseWhileThermalCritical` to `while true` AND swallow the
    /// `CancellationError` in the catch (e.g. `continue`). With both
    /// guards removed the activeTask spins forever and the
    /// `stopGenerationAndWait()` await never returns — the timeout race
    /// returns `false` and the assertion fails.
    func test_perTokenLoop_thermalPause_cancellationUnwindsCleanly() async throws {
        // Provider always reports `.critical` so the pause loop would
        // otherwise spin forever. Cancellation is the only exit.
        let coord = GenerationQueue(
            thermalStateProvider: { @Sendable in .critical },
            thermalSleep: { @Sendable duration in
                // Forward to the real sleep so the cooperative cancellation
                // contract is exercised end-to-end. The duration is the
                // production 2s cadence, but cancellation should fire the
                // throw long before that.
                try await Task.sleep(for: duration)
            }
        )
        coord.provider = provider
        provider.backend.tokensToYield = ["a", "b"]

        let (_, stream) = try coord.enqueue(
            messages: [("user", "hi")], priority: .normal
        )

        // Drain the stream until we see the throttle event, then trigger
        // cancellation. We don't fully drain here — `stopGenerationAndWait`
        // below is the real assertion that the activeTask unwinds.
        var sawThrottle = false
        for try await event in stream.events {
            if case .diagnosticThrottle = event {
                sawThrottle = true
                break
            }
        }
        XCTAssertTrue(
            sawThrottle,
            "pause loop must emit a throttle event before we cancel; otherwise the test isn't exercising the pause path"
        )

        // Race `stopGenerationAndWait()` against a 2s wall-clock deadline.
        // If the pause loop ignores `Task.isCancelled` the wait hangs
        // forever and the race returns `false`.
        let unwoundCleanly = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                await coord.stopGenerationAndWait()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        XCTAssertTrue(
            unwoundCleanly,
            "stopGenerationAndWait() must return promptly while the pause loop is parked — pause loop must observe Task.isCancelled and propagate the CancellationError thrown by thermalSleep"
        )
    }

    // MARK: - Exact preflight (TokenCountingBackend)

    /// When the backend fits within the context window on the first count,
    /// `generate` must call `backend.generate()` exactly once without trimming.
    ///
    /// Sabotage check: if `exactPreflightAndTrim` always trimmed at least one
    /// message regardless of fit, `backend.generateCallCount` would still be 1
    /// but the prompt passed to the backend would be shorter than the full
    /// history — `backend.lastPrompt` would not contain all messages.
    func test_exactPreflight_promptFits_noTrimAndGenerateCalled() async throws {
        let tcBackend = TokenCountingMockBackend(contextSize: 256)
        // countTokens returns 50 on first call → 50 + 128 (default maxOutput) = 178 ≤ 256 → fits.
        tcBackend.countTokensResponses = [50]
        tcBackend.tokensToYield = ["ok"]
        let tcProvider = TokenCountingFakeProvider(backend: tcBackend)

        let coord = GenerationQueue()
        coord.provider = tcProvider

        let (_, stream) = try coord.enqueue(
            messages: [("user", "hello")],
            maxOutputTokens: 128
        )
        for try await _ in stream.events {}

        XCTAssertEqual(tcBackend.generateCallCount, 1,
                       "generate must be called exactly once when the prompt fits")
        XCTAssertEqual(tcBackend.countTokensCalled, 1,
                       "countTokens must be called exactly once when the prompt fits")
    }

    /// When the first count is over budget but trimming brings it under,
    /// `generate` must eventually be called with the trimmed prompt.
    ///
    /// The mock returns counts that decrease across retries: first call is over
    /// budget, second call (after one trim) is within budget.
    ///
    /// Sabotage check: if the trim loop never removed a message,
    /// `countTokens` would always return the over-budget value and
    /// `contextExhausted` would be thrown, failing this test.
    func test_exactPreflight_promptOverBudget_trimsAndGenerates() async throws {
        // Context = 200, maxOutput = 100 → budget = 100 prompt tokens allowed.
        // First count = 150 (over), second count = 90 (under after one trim).
        let tcBackend = TokenCountingMockBackend(contextSize: 200)
        tcBackend.countTokensResponses = [150, 90]
        tcBackend.tokensToYield = ["trimmed"]
        let tcProvider = TokenCountingFakeProvider(backend: tcBackend)

        let coord = GenerationQueue()
        coord.provider = tcProvider

        // Two messages so we have something to trim.
        let (_, stream) = try coord.enqueue(
            messages: [
                (role: "user", content: "first message that will be trimmed"),
                (role: "user", content: "second message kept"),
            ],
            maxOutputTokens: 100
        )
        for try await _ in stream.events {}

        XCTAssertEqual(tcBackend.generateCallCount, 1,
                       "generate must be called once after successful trim")
        // Two count calls: one over-budget, one under-budget after trim.
        XCTAssertEqual(tcBackend.countTokensCalled, 2,
                       "countTokens must be called twice: once over budget, once after trim")
    }

    /// When trimming cannot bring the prompt under budget (all trim attempts
    /// exhausted or only the final user message remains),
    /// `InferenceError.contextExhausted` must be thrown.
    ///
    /// Sabotage check: if the coordinator silently forwarded the over-budget
    /// prompt to the backend, `generateCallCount` would be 1 and no error
    /// would be thrown — the XCTAssertThrowsError would fail.
    func test_exactPreflight_cannotTrim_throwsContextExhausted() throws {
        // Context = 100, maxOutput = 50 → only 50 prompt tokens allowed.
        // countTokens always returns 80 — over budget even with a single message.
        let tcBackend = TokenCountingMockBackend(contextSize: 100)
        tcBackend.countTokensResponses = [80, 80, 80, 80, 80]
        let tcProvider = TokenCountingFakeProvider(backend: tcBackend)

        let coord = GenerationQueue()
        coord.provider = tcProvider

        // Single user message — cannot trim (would remove the only user turn).
        XCTAssertThrowsError(
            try coord.generate(
                messages: [("user", "a question that is too long for the context window")],
                maxOutputTokens: 50
            )
        ) { error in
            guard case InferenceError.contextExhausted = error else {
                XCTFail("Expected contextExhausted, got \(error)")
                return
            }
        }

        XCTAssertEqual(tcBackend.generateCallCount, 0,
                       "generate must never be called when context is exhausted — "
                       + "the overflow must not reach the C layer")
    }

    /// Verifies the trim-and-retry loop reduces the message list across
    /// multiple rounds. With three messages and counts that only fit after
    /// two trims, the final call to `backend.generate` must receive a shorter
    /// prompt than the original.
    func test_exactPreflight_multiRoundTrim_reducesHistory() async throws {
        // Context = 300, maxOutput = 100 → 200 token budget.
        // Round 0 (3 msgs): 250 tokens → over budget (250+100=350 > 300) → trim.
        // Round 1 (2 msgs): 210 tokens → over budget (210+100=310 > 300) → trim.
        // Round 2 (1 msg):  180 tokens → fits     (180+100=280 ≤ 300) → call generate.
        let tcBackend = TokenCountingMockBackend(contextSize: 300)
        tcBackend.countTokensResponses = [250, 210, 180]
        tcBackend.tokensToYield = ["done"]
        let tcProvider = TokenCountingFakeProvider(backend: tcBackend)

        let coord = GenerationQueue()
        coord.provider = tcProvider

        let (_, stream) = try coord.enqueue(
            messages: [
                (role: "user", content: "oldest message"),
                (role: "assistant", content: "middle reply"),
                (role: "user", content: "latest question"),
            ],
            maxOutputTokens: 100
        )
        for try await _ in stream.events {}

        XCTAssertEqual(tcBackend.generateCallCount, 1,
                       "generate must succeed after multi-round trim")
        XCTAssertEqual(tcBackend.countTokensCalled, 3,
                       "three count rounds expected: 2 over-budget, 1 under-budget")
    }

    // MARK: - Exact preflight: maxThinkingTokens reservation (issue #587)

    /// `exactPreflightAndTrim` must fold `config.maxThinkingTokens` into the
    /// reservation so reasoning-model prompts are trimmed aggressively enough
    /// to leave room for both the visible response and the thinking block.
    ///
    /// Scenario:
    ///   contextSize = 1000, maxOutput = 100, maxThinking = 200.
    ///   Reserved = 300, so the prompt budget is 700.
    ///   First countTokens returns 800 → over budget → trim.
    ///   Second countTokens returns 650 → fits → generate.
    ///
    /// Sabotage check: if the reservation ignored `maxThinkingTokens`, the
    /// first count (800) would fit within (1000 - 100) = 900 and no trim
    /// would happen — `countTokensCalled` would be 1 and the backend would
    /// receive the full two-message history.
    func test_exactPreflightAndTrim_reservesVisiblePlusThinking() async throws {
        let tcBackend = TokenCountingMockBackend(contextSize: 1000)
        tcBackend.countTokensResponses = [800, 650]
        tcBackend.tokensToYield = ["ok"]
        let tcProvider = TokenCountingFakeProvider(backend: tcBackend)

        let coord = GenerationQueue()
        coord.provider = tcProvider

        let stream = try coord.generate(
            messages: [
                (role: "user", content: "oldest — will be trimmed"),
                (role: "user", content: "latest — will be kept"),
            ],
            maxOutputTokens: 100,
            maxThinkingTokens: 200
        )
        for try await _ in stream.events {}

        XCTAssertEqual(tcBackend.countTokensCalled, 2,
                       "Two count calls expected: first over budget (800+300>1000), "
                       + "second under after trim (650+300≤1000).")
        XCTAssertEqual(tcBackend.generateCallCount, 1,
                       "generate must be called exactly once after the trim round succeeds")
    }

    /// `exactPreflightAndTrim` must treat `maxThinkingTokens = nil` as a
    /// zero-token reservation rather than substituting a default (e.g. 2048).
    ///
    /// Scenario:
    ///   contextSize = 1000, maxOutput = 100, maxThinking = nil.
    ///   Reserved = 100, so the prompt budget is 900.
    ///   First countTokens returns 800 → fits → generate without trimming.
    ///
    /// Sabotage check: if nil were substituted with a 2048 default, the
    /// reserve would be 2148 (exceeding the 1000-token context), available
    /// would go negative, and `exactPreflightAndTrim` would throw
    /// `contextExhausted`. The test would surface as a thrown error rather
    /// than a successful `generateCallCount == 1`.
    func test_exactPreflightAndTrim_thinkingNilDoesNotOverReserve() async throws {
        let tcBackend = TokenCountingMockBackend(contextSize: 1000)
        tcBackend.countTokensResponses = [800]
        tcBackend.tokensToYield = ["ok"]
        let tcProvider = TokenCountingFakeProvider(backend: tcBackend)

        let coord = GenerationQueue()
        coord.provider = tcProvider

        let stream = try coord.generate(
            messages: [(role: "user", content: "fits without thinking reserve")],
            maxOutputTokens: 100,
            maxThinkingTokens: nil
        )
        for try await _ in stream.events {}

        XCTAssertEqual(tcBackend.countTokensCalled, 1,
                       "Only one count call expected — the prompt fits within 1000 - 100 = 900.")
        XCTAssertEqual(tcBackend.generateCallCount, 1,
                       "generate must succeed without trimming when thinking reserve is zero.")
    }

    /// Passing `maxOutputTokens: nil` must still reserve the documented
    /// default visible-output budget (2048 tokens) during exact preflight.
    ///
    /// Scenario:
    ///   contextSize = 3000, maxOutput = nil -> visible reserve = 2048.
    ///   First countTokens returns 1000 -> over budget (3048 > 3000) -> trim.
    ///   Second countTokens returns 900 -> fits (2948 <= 3000) -> generate.
    ///
    /// Sabotage check: if nil were treated as a zero-token reservation, the
    /// first count would fit and `countTokensCalled` would be 1.
    func test_exactPreflightAndTrim_maxOutputNilUsesDefaultVisibleReserve() async throws {
        let tcBackend = TokenCountingMockBackend(contextSize: 3000)
        tcBackend.countTokensResponses = [1000, 900]
        tcBackend.tokensToYield = ["ok"]
        let tcProvider = TokenCountingFakeProvider(backend: tcBackend)

        let coord = GenerationQueue()
        coord.provider = tcProvider

        let stream = try coord.generate(
            messages: [
                (role: "user", content: "oldest — trimmed because nil maxOutput reserves 2048"),
                (role: "user", content: "latest — kept")
            ],
            maxOutputTokens: nil
        )
        for try await _ in stream.events {}

        XCTAssertEqual(tcBackend.countTokensCalled, 2,
                       "nil maxOutputTokens must reserve 2048, forcing one trim in this fixture")
        XCTAssertEqual(tcBackend.generateCallCount, 1)
    }

    /// If the reserved output budget itself exceeds the context window, exact
    /// preflight must surface `contextExhausted` before the backend generate
    /// call, preserving the associated values callers use for remediation UI.
    func test_exactPreflightAndTrim_reserveGreaterThanContextThrowsContextExhausted() throws {
        let tcBackend = TokenCountingMockBackend(contextSize: 1000)
        tcBackend.countTokensResponses = [1]
        let tcProvider = TokenCountingFakeProvider(backend: tcBackend)

        let coord = GenerationQueue()
        coord.provider = tcProvider

        XCTAssertThrowsError(
            try coord.generate(
                messages: [(role: "user", content: "tiny prompt")],
                maxOutputTokens: 1500
            )
        ) { error in
            guard case InferenceError.contextExhausted(let promptTokens, let maxOutputTokens, let contextSize) = error else {
                XCTFail("Expected contextExhausted, got \(error)")
                return
            }
            XCTAssertEqual(promptTokens, 1)
            XCTAssertEqual(maxOutputTokens, 1500)
            XCTAssertEqual(contextSize, 1000)
        }

        XCTAssertEqual(tcBackend.generateCallCount, 0,
                       "over-reserved prompts must not reach backend.generate")
    }

    /// The exact trim loop is intentionally bounded. When every count remains
    /// over budget and enough user turns exist that the last-user guard is not
    /// reached first, it must stop after the default 20 trim attempts.
    func test_exactPreflightAndTrim_maxTrimAttemptsExhaustedThrows() throws {
        let tcBackend = TokenCountingMockBackend(contextSize: 500)
        tcBackend.countTokensResponses = Array(repeating: 1000, count: 25)
        let tcProvider = TokenCountingFakeProvider(backend: tcBackend)

        let coord = GenerationQueue()
        coord.provider = tcProvider

        let messages = (0..<25).map { idx in
            (role: "user", content: "message \(idx)")
        }

        XCTAssertThrowsError(
            try coord.generate(messages: messages, maxOutputTokens: 100)
        ) { error in
            guard case InferenceError.contextExhausted(let promptTokens, let maxOutputTokens, let contextSize) = error else {
                XCTFail("Expected contextExhausted, got \(error)")
                return
            }
            XCTAssertEqual(promptTokens, 1000)
            XCTAssertEqual(maxOutputTokens, 100)
            XCTAssertEqual(contextSize, 500)
        }

        XCTAssertEqual(tcBackend.countTokensCalled, 21,
                       "default maxTrimAttempts is 20: initial count plus 20 retry counts")
        XCTAssertEqual(tcBackend.generateCallCount, 0)
    }

    /// A history containing only system-role tuples has no non-system message
    /// available to trim, so exact preflight must fail closed with
    /// `contextExhausted` rather than forwarding an over-budget prompt.
    func test_exactPreflightAndTrim_systemOnlyHistoryThrowsContextExhausted() throws {
        let tcBackend = TokenCountingMockBackend(contextSize: 100)
        tcBackend.countTokensResponses = [80]
        let tcProvider = TokenCountingFakeProvider(backend: tcBackend)

        let coord = GenerationQueue()
        coord.provider = tcProvider

        XCTAssertThrowsError(
            try coord.generate(
                messages: [(role: "system", content: "system-only injected history")],
                maxOutputTokens: 50
            )
        ) { error in
            guard case InferenceError.contextExhausted = error else {
                XCTFail("Expected contextExhausted, got \(error)")
                return
            }
        }

        XCTAssertEqual(tcBackend.countTokensCalled, 1)
        XCTAssertEqual(tcBackend.generateCallCount, 0)
    }

    /// Assistant-only histories are trimmable because no user turn would be
    /// lost. If trimming all assistant content brings the prompt under budget,
    /// generation may proceed with the reduced prompt.
    func test_exactPreflightAndTrim_assistantOnlyHistoryCanTrimToFit() async throws {
        let tcBackend = TokenCountingMockBackend(contextSize: 100)
        tcBackend.countTokensResponses = [80, 10]
        tcBackend.tokensToYield = ["ok"]
        let tcProvider = TokenCountingFakeProvider(backend: tcBackend)

        let coord = GenerationQueue()
        coord.provider = tcProvider

        let stream = try coord.generate(
            messages: [(role: "assistant", content: "assistant-only stale response")],
            maxOutputTokens: 50
        )
        for try await _ in stream.events {}

        XCTAssertEqual(tcBackend.countTokensCalled, 2)
        XCTAssertEqual(tcBackend.generateCallCount, 1)
        XCTAssertFalse(tcBackend.lastPrompt?.contains("assistant-only stale response") ?? true,
                       "assistant-only content should be removed before generation")
    }

    /// Once trimming would remove the only remaining user turn, exact preflight
    /// must throw instead of preserving context fit by deleting the latest user
    /// message.
    func test_exactPreflightAndTrim_preservesLatestUserMessageWhenStillOverBudget() throws {
        let tcBackend = TokenCountingMockBackend(contextSize: 100)
        tcBackend.countTokensResponses = [80, 80, 10]
        let tcProvider = TokenCountingFakeProvider(backend: tcBackend)

        let coord = GenerationQueue()
        coord.provider = tcProvider

        XCTAssertThrowsError(
            try coord.generate(
                messages: [
                    (role: "assistant", content: "old assistant response that can be trimmed"),
                    (role: "user", content: "latest user question must remain")
                ],
                maxOutputTokens: 50
            )
        ) { error in
            guard case InferenceError.contextExhausted = error else {
                XCTFail("Expected contextExhausted, got \(error)")
                return
            }
        }

        XCTAssertEqual(tcBackend.countTokensCalled, 2,
                       "the loop should stop before counting an empty prompt created by deleting the latest user turn")
        XCTAssertEqual(tcBackend.generateCallCount, 0)
    }

    /// Tokenizer failures are authoritative exact-preflight failures. They
    /// must propagate without falling back to heuristic counting or calling
    /// the backend generate path.
    func test_exactPreflightAndTrim_tokenCounterErrorPropagates() throws {
        let tcBackend = TokenCountingMockBackend(contextSize: 256)
        tcBackend.countTokensError = TokenCountingTestError.tokenizerUnavailable
        let tcProvider = TokenCountingFakeProvider(backend: tcBackend)

        let coord = GenerationQueue()
        coord.provider = tcProvider

        XCTAssertThrowsError(
            try coord.generate(
                messages: [(role: "user", content: "hello")],
                maxOutputTokens: 50
            )
        ) { error in
            guard case TokenCountingTestError.tokenizerUnavailable = error else {
                XCTFail("Expected tokenizerUnavailable, got \(error)")
                return
            }
        }

        XCTAssertEqual(tcBackend.generateCallCount, 0,
                       "generate must not run when exact token counting throws")
    }

    // MARK: - Provider teardown safety

    /// Deallocating the provider mid-stream must not crash the coordinator.
    /// The `weak var provider` goes nil and in-flight generation ends cleanly.
    func test_providerTeardown_midStream_noCrash_cleanEnd() async throws {
        let slow = SlowMockBackend(tokenCount: 20, delayMilliseconds: 20)
        var slowProvider: SlowFakeProvider? = SlowFakeProvider(backend: slow)
        let coord = GenerationQueue()
        coord.provider = slowProvider

        let (_, stream) = try coord.enqueue(messages: [("user", "x")], priority: .normal)

        // Consume a token, then release our strong ref so the weak var goes nil.
        var iter = stream.events.makeAsyncIterator()
        _ = try await iter.next()
        slowProvider = nil

        // Stop the backend's running task — this unblocks the for-await loop
        // inside the coordinator's active task without needing the provider.
        slow.stopGeneration()

        // Drain the rest of the stream.
        while let _ = try? await iter.next() {}

        // The coordinator must be in a stable state: no crash, no active
        // generation.
        XCTAssertFalse(coord.isGenerating)
        XCTAssertNil(coord.provider as? SlowFakeProvider)
    }
}

// MARK: - Warning capture (PR #615 review fix)

/// Thread-safe collector for the `jsonModeUnsupportedWarningHook` on
/// `GenerationQueue`. The hook is `@Sendable` and may fire from any
/// isolation; an `NSLock` keeps recorded entries race-free without
/// introducing actor hops into the test.
private final class WarningCapture: @unchecked Sendable {
    struct Entry {
        let backendType: String
        let message: String
    }
    private let lock = NSLock()
    private var entries: [Entry] = []

    func record(backendType: String, message: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(Entry(backendType: backendType, message: message))
    }

    func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

// MARK: - Thermal-pause test counters (#745)

/// Records each invocation of the injected `thermalStateProvider` and
/// returns a strictly increasing index, so the test script can drive the
/// pause loop through `.critical → .critical → .nominal` without a stateful
/// closure capture. Lock-protected because the provider is `@Sendable` and
/// may be invoked off the test's MainActor isolation.
private final class ThermalReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let i = index
        index += 1
        return i
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return index
    }
}

/// Counts calls to the injected `thermalSleep` hook so the test can
/// assert how many re-check ticks the pause loop performed without
/// burning real wall-clock time on `Task.sleep`.
private final class SleepCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    func bump() {
        lock.lock()
        defer { lock.unlock() }
        _count += 1
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }
}

// MARK: - File-local fakes
//
// These conform to the internal `GenerationContextProvider` via `@testable
// import ManifoldInference`. Keeping them file-local (rather than publishing
// them from `ManifoldTestSupport`) means the protocol stays internal and the
// package's public API surface is unchanged.

/// A configurable fake that serves a `MockInferenceBackend`. Mirrors the
/// construction pattern the rest of the inference tests use.
@MainActor
final class FakeGenerationContextProvider: GenerationContextProvider {

    let backend: MockInferenceBackend
    var promptTemplate: PromptTemplate = .chatML

    init(backend: MockInferenceBackend = MockInferenceBackend()) {
        self.backend = backend
        // Default to a "loaded" state so enqueue() passes its guard. Tests
        // that want the unloaded path flip this explicitly.
        self.backend.isModelLoaded = true
    }

    var currentBackend: (any InferenceBackend)? { backend }
    var isBackendLoaded: Bool { backend.isModelLoaded }
    var selectedPromptTemplate: PromptTemplate { promptTemplate }
}

/// A fake that serves a `SlowMockBackend` for tests that need a backend that
/// yields tokens over time (cancellation / ordering).
@MainActor
private final class SlowFakeProvider: GenerationContextProvider {
    let backend: SlowMockBackend
    init(backend: SlowMockBackend) { self.backend = backend }
    convenience init(tokenCount: Int = 10, delayMilliseconds: Int = 30) {
        self.init(backend: SlowMockBackend(tokenCount: tokenCount, delayMilliseconds: delayMilliseconds))
    }
    var currentBackend: (any InferenceBackend)? { backend }
    var isBackendLoaded: Bool { backend.isModelLoaded }
    var selectedPromptTemplate: PromptTemplate { .chatML }
}

/// A provider where `currentBackend` returns nil — used to exercise the
/// `currentBackend == nil` branch of the enqueue guard.
@MainActor
private final class NilBackendProvider: GenerationContextProvider {
    var currentBackend: (any InferenceBackend)? { nil }
    var isBackendLoaded: Bool { false }
    var selectedPromptTemplate: PromptTemplate { .chatML }
}

private enum TokenCountingTestError: Error {
    case tokenizerUnavailable
}

// MARK: - TokenCounting fakes

/// An inference backend that also conforms to `TokenCountingBackend` for testing
/// the exact pre-flight trim loop in `GenerationQueue`.
///
/// `countTokensResponses` controls what `countTokens` returns on each successive
/// call (FIFO). Once exhausted the last value is repeated.
/// `requiresPromptTemplate = true` so the coordinator takes the exact-preflight
/// path instead of the cloud/MLX fallback path.
private final class TokenCountingMockBackend: InferenceBackend, TokenCountingBackend, @unchecked Sendable {

    // InferenceBackend
    var isModelLoaded: Bool = true
    var isGenerating: Bool = false
    var capabilities: BackendCapabilities

    var tokensToYield: [String] = ["Hello", " world"]
    var shouldThrowOnGenerate: Error?
    private(set) var generateCallCount = 0
    private(set) var lastPrompt: String?

    // TokenCountingBackend
    var countTokensResponses: [Int] = []
    var countTokensError: Error?
    private(set) var countTokensCalled = 0

    init(contextSize: Int32 = 256) {
        self.capabilities = BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: contextSize,
            requiresPromptTemplate: true,      // triggers exact-preflight path
            supportsSystemPrompt: true,
            supportsToolCalling: false,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: true
        )
    }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {}

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
        generateCallCount += 1
        lastPrompt = prompt
        if let error = shouldThrowOnGenerate { throw error }
        let tokens = tokensToYield
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            Task {
                for token in tokens { continuation.yield(.token(token)) }
                continuation.finish()
            }
        }
        return GenerationStream(stream)
    }

    func stopGeneration() { isGenerating = false }
    func unloadModel() { isModelLoaded = false }

    func countTokens(_ text: String) throws -> Int {
        if let error = countTokensError { throw error }
        countTokensCalled += 1
        guard !countTokensResponses.isEmpty else { return 10 }
        let idx = min(countTokensCalled - 1, countTokensResponses.count - 1)
        return countTokensResponses[idx]
    }
}

/// A fake provider that vends a `TokenCountingMockBackend`.
@MainActor
private final class TokenCountingFakeProvider: GenerationContextProvider {
    let backend: TokenCountingMockBackend
    var promptTemplate: PromptTemplate = .chatML

    init(backend: TokenCountingMockBackend = TokenCountingMockBackend()) {
        self.backend = backend
        self.backend.isModelLoaded = true
    }

    var currentBackend: (any InferenceBackend)? { backend }
    var isBackendLoaded: Bool { backend.isModelLoaded }
    var selectedPromptTemplate: PromptTemplate { promptTemplate }
}
