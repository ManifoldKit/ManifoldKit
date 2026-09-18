import XCTest
@testable import ManifoldFuzz
import ManifoldInference
import ManifoldTestSupport

final class StopResidueBackend: InferenceBackend, @unchecked Sendable {
    private struct State {
        var isModelLoaded = true
        var isGenerating = false
        var turn = 0
        var activeContinuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation?
        var leakIntoSuccessor: Bool
        var shouldPrefixResidue = false
        var stopObservedWhileGenerating = false
        var generateCallCount = 0
        var stopCallCount = 0
        var activeRequestHadTools = false
        var generationConfigs: [GenerationConfig] = []
    }

    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4_096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true,
        supportsToolCalling: true
    )

    private let lock = NSLock()
    private var state: State
    private let residue = " residue"
    private let firstTurnTokens: [String]
    private let requiresToolsForResidue: Bool

    init(
        leakIntoSuccessor: Bool,
        firstTurnTokens: [String] = ["old response residue"],
        requiresToolsForResidue: Bool = false
    ) {
        state = State(leakIntoSuccessor: leakIntoSuccessor)
        self.firstTurnTokens = firstTurnTokens
        self.requiresToolsForResidue = requiresToolsForResidue
    }

    var isModelLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.isModelLoaded
    }

    var isGenerating: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.isGenerating
    }

    var didObserveStopWhileGenerating: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.stopObservedWhileGenerating
    }

    var generateCallCount: Int { lock.withLock { state.generateCallCount } }
    var stopCallCount: Int { lock.withLock { state.stopCallCount } }
    var generationConfigs: [GenerationConfig] { lock.withLock { state.generationConfigs } }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        lock.withLock {
            state.isModelLoaded = true
        }
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig,
        hints: GenerationRuntimeHints
    ) throws -> GenerationStream {
        lock.lock()
        let turn = state.turn
        state.turn += 1
        state.generateCallCount += 1
        state.isGenerating = true
        state.activeRequestHadTools = !config.tools.isEmpty
        state.generationConfigs.append(config)
        let prefixResidue = state.shouldPrefixResidue
        state.shouldPrefixResidue = false
        lock.unlock()

        return GenerationStream(AsyncThrowingStream<GenerationEvent, Error> { [self] continuation in
            lock.lock()
            state.activeContinuation = continuation
            lock.unlock()

            if turn == 0 {
                // The stream deliberately remains open after its first token.
                // Only a real stop can finish this turn and admit turn 2.
                for token in firstTurnTokens {
                    continuation.yield(.token(token))
                }
            } else {
                continuation.yield(.token(prefixResidue ? residue + " successor" : "clean successor"))
                lock.lock()
                state.isGenerating = false
                state.activeContinuation = nil
                lock.unlock()
                continuation.finish()
            }
        })
    }

    func stopGeneration() {
        lock.lock()
        let wasGenerating = state.isGenerating
        state.stopCallCount += 1
        state.stopObservedWhileGenerating = wasGenerating
        if wasGenerating && state.leakIntoSuccessor
            && (!requiresToolsForResidue || state.activeRequestHadTools) {
            state.shouldPrefixResidue = true
        }
        state.isGenerating = false
        let continuation = state.activeContinuation
        state.activeContinuation = nil
        lock.unlock()
        continuation?.finish()
    }

    func unloadModel() {
        stopGeneration()
        lock.lock()
        state.isModelLoaded = false
        lock.unlock()
    }
}

private actor EnqueueBarrier {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let waitingForEntry = entryWaiters
        entryWaiters.removeAll()
        for waiter in waitingForEntry { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        let waiting = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
}

@MainActor
final class SessionScriptRunnerTests: XCTestCase {

    /// Builds a service backed by a `MockInferenceBackend` that yields the
    /// given scripted reply. The `#if DEBUG` convenience initializer does
    /// the heavy lifting so we don't have to wire a factory for each test.
    private func makeService(replying tokens: [String] = ["ok"]) -> (InferenceService, MockInferenceBackend) {
        let mock = MockInferenceBackend()
        mock.tokensToYield = tokens
        mock.isModelLoaded = true // bypass the explicit load step
        let service = InferenceService(backend: mock, name: "SessionRunnerTest")
        return (service, mock)
    }

    func test_sendStep_enqueuesAndCapturesRecord() async throws {
        let (service, mock) = makeService(replying: ["hello", " there"])
        let runner = SessionScriptRunner(
            service: service,
            options: .init(modelId: "mock-1"),
            seed: 42
        )
        let script = SessionScript(
            id: "basic-send",
            steps: [.send(text: "hi")]
        )
        let capture = await runner.execute(script)

        XCTAssertEqual(capture.steps.count, 1)
        XCTAssertEqual(capture.steps[0].timeline, .executed)
        let record = try XCTUnwrap(capture.steps[0].record)
        XCTAssertEqual(record.raw, "hello there")
        XCTAssertEqual(record.model.id, "mock-1")
        XCTAssertEqual(mock.generateCallCount, 1)
    }

    func test_stopStep_invokesStopGeneration() async {
        let (service, mock) = makeService()
        let runner = SessionScriptRunner(service: service)
        let script = SessionScript(
            id: "just-stop",
            steps: [.stop]
        )
        let capture = await runner.execute(script)

        XCTAssertEqual(capture.steps.count, 1)
        XCTAssertEqual(capture.steps[0].timeline, .stopRequested)
        XCTAssertNil(capture.steps[0].record)
        XCTAssertEqual(mock.stopCallCount, 1)
    }

    func test_adjacentStop_overlapsActiveTurn_andDetectsSuccessorPrefixResidue() async throws {
        let backend = StopResidueBackend(leakIntoSuccessor: true)
        let service = InferenceService(backend: backend, name: "StopResidueTest")
        let runner = SessionScriptRunner(service: service, options: .init(requestTimeout: 0.2))
        let script = SessionScript(
            id: "real-stop-residue",
            steps: [.send(text: "first"), .stop, .send(text: "second")]
        )

        let capture = await runner.execute(script)
        let observation = try XCTUnwrap(capture.steps[1].stopObservation)

        XCTAssertTrue(backend.didObserveStopWhileGenerating)
        XCTAssertEqual(observation.qualification, .inFlight)
        XCTAssertTrue(observation.tailObservedBeforeStopReturned.hasSuffix(" residue"))
        XCTAssertEqual(
            observation.textObservedAfterStopReturned,
            "",
            "queue cancellation should not be mislabeled as proof of post-stop backend emission"
        )
        XCTAssertTrue(try XCTUnwrap(capture.steps[2].record).raw.hasPrefix(" residue"))

        let findings = CancellationRaceDetector().inspect([capture])
        XCTAssertEqual(findings.map(\.subCheck), ["stopped-turn-tail-at-successor-prefix"])
    }

    func test_adjacentStop_cleanSuccessor_isQualifiedWithoutResidueFinding() async throws {
        let backend = StopResidueBackend(leakIntoSuccessor: false)
        let service = InferenceService(backend: backend, name: "StopResidueControl")
        let runner = SessionScriptRunner(service: service)
        let script = SessionScript(
            id: "real-stop-clean-control",
            steps: [.send(text: "first"), .stop, .send(text: "second")]
        )

        let capture = await runner.execute(script)
        XCTAssertTrue(backend.didObserveStopWhileGenerating)
        XCTAssertEqual(capture.steps[1].stopObservation?.qualification, .inFlight)
        XCTAssertEqual(try XCTUnwrap(capture.steps[2].record).raw, "clean successor")
        XCTAssertTrue(CancellationRaceDetector().inspect([capture]).isEmpty)
    }

    /// Session-script records are replay inputs. A configured runner seed must
    /// therefore reach the backend for ordinary sends, the send that is
    /// cancelled by an adjacent stop, and regenerated turns alike.
    func test_seed_reachesBackendAndRecordsAcrossSendRegenerateAndPairedStop() async throws {
        let seed: UInt64 = 0xC0FFEE
        let backend = StopResidueBackend(leakIntoSuccessor: false)
        let service = InferenceService(backend: backend, name: "SessionSeedWiring")
        let runner = SessionScriptRunner(service: service, seed: seed)
        let script = SessionScript(
            id: "seed-through-session-turns",
            steps: [.send(text: "first"), .stop, .send(text: "second"), .regenerate]
        )

        let capture = await runner.execute(script)
        let records = capture.turnRecords
        let backendConfigs = backend.generationConfigs
        let expectedSeeds = Array(repeating: seed, count: 3)

        XCTAssertEqual(capture.steps.map(\.timeline), [.executed, .stopRequested, .executed, .executed])
        XCTAssertEqual(capture.steps[1].stopObservation?.qualification, .inFlight)
        XCTAssertEqual(backendConfigs.count, 3)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(backendConfigs.map(\.seed), expectedSeeds.map(Optional.some))
        XCTAssertEqual(records.map(\.config.seed), expectedSeeds)
        XCTAssertEqual(
            backendConfigs.map(\.seed),
            records.map { Optional($0.config.seed) },
            "the replay seed recorded for every session turn must be the seed sent to its backend"
        )
    }

    func test_adjacentStop_withoutVisibleContent_reportsUnexercisedWindow() async {
        let (service, mock) = makeService()
        mock.tokensToYieldPerTurn = [[], ["clean successor"]]
        let runner = SessionScriptRunner(service: service)
        let script = SessionScript(
            id: "no-visible-stop-window",
            steps: [.send(text: "first"), .stop, .send(text: "second")]
        )

        let capture = await runner.execute(script)
        XCTAssertEqual(capture.steps[1].stopObservation?.qualification, .noVisibleContent)
        XCTAssertEqual(
            CancellationRaceDetector().inspect([capture]).map(\.subCheck),
            ["stop-window-unexercised"]
        )
    }

    func test_adjacentStop_emptyTokensNeverQualifyVisibleWindow() async {
        let backend = StopResidueBackend(
            leakIntoSuccessor: false,
            firstTurnTokens: ["", ""]
        )
        let service = InferenceService(backend: backend, name: "EmptyTokenStopWindow")
        let runner = SessionScriptRunner(
            service: service,
            options: .init(requestTimeout: 0.2)
        )
        let capture = await runner.execute(.init(
            id: "empty-token-stop-window",
            steps: [.send(text: "first"), .stop, .send(text: "second")]
        ))

        XCTAssertEqual(capture.steps[1].stopObservation?.qualification, .noVisibleContent)
        XCTAssertGreaterThanOrEqual(backend.stopCallCount, 1, "timeout cleanup must close the empty-token stream")
        XCTAssertEqual(
            CancellationRaceDetector().inspect([capture]).map(\.subCheck),
            ["stop-window-unexercised"]
        )
    }

    func test_preCancelledExecute_neverCreatesRequest_andReportsInterruptedWindow() async throws {
        let backend = StopResidueBackend(leakIntoSuccessor: false)
        let service = InferenceService(backend: backend, name: "PreCancelledStopWindow")
        let runner = SessionScriptRunner(service: service, options: .init(requestTimeout: 0.2))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await runner.execute(.init(
                id: "pre-cancelled-stop-window",
                steps: [.send(text: "first"), .stop]
            ))
        }

        let capture = await task.value
        XCTAssertEqual(capture.steps[1].stopObservation?.qualification, .cancelledBeforeObservation)
        XCTAssertEqual(backend.generateCallCount, 0)
        XCTAssertGreaterThanOrEqual(backend.stopCallCount, 1)
        XCTAssertFalse(backend.isGenerating)
    }

    func test_cancelWhileChildWaitsBeforeEnqueue_cannotLeaveLaterGenerationActive() async {
        let backend = StopResidueBackend(leakIntoSuccessor: false)
        let service = InferenceService(backend: backend, name: "EnqueueBarrierStopWindow")
        let barrier = EnqueueBarrier()
        let runner = SessionScriptRunner(
            service: service,
            options: .init(requestTimeout: 0.2),
            beforeEnqueue: {
                await barrier.wait()
            }
        )
        let task = Task {
            await runner.execute(.init(
                id: "cancel-before-enqueue",
                steps: [.send(text: "first"), .stop]
            ))
        }

        await barrier.waitUntilEntered()
        task.cancel()
        await barrier.release()
        let capture = await task.value

        XCTAssertEqual(capture.steps[1].stopObservation?.qualification, .cancelledBeforeObservation)
        XCTAssertEqual(backend.generateCallCount, 0, "a child released after cleanup must not enqueue late")
        XCTAssertGreaterThanOrEqual(backend.stopCallCount, 1, "parent cancellation still executes backend cleanup")
        XCTAssertFalse(backend.isGenerating)
    }

    /// A `.send` step whose generation never completes (a `TokenEmissionGate`
    /// that's never advanced, mirroring a truly hung local-backend
    /// generation) is bounded by `options.requestTimeout`, AND the timeout's
    /// `onTimeout` actually calls `InferenceService.cancel(_:)` — not just
    /// abandons the operation task. Regression test for the review finding
    /// that `GenerationTimeout` alone doesn't stop an in-flight generation;
    /// `SessionScriptRunner.cancelInFlight(token:)` is the real stop path.
    func test_sendStep_hungGeneration_isBoundedAndActuallyCancelled() async throws {
        let (service, mock) = makeService()
        mock.tokenEmissionGate = TokenEmissionGate() // never advanced — first token blocks forever
        let runner = SessionScriptRunner(
            service: service,
            options: .init(requestTimeout: 0.3),
            seed: 1
        )
        let script = SessionScript(
            id: "hung-send",
            steps: [.send(text: "hi")]
        )

        let start = ContinuousClock.now
        let capture = await runner.execute(script)
        let elapsed = start.duration(to: ContinuousClock.now)

        XCTAssertLessThan(elapsed, .seconds(5), "a permanently-gated stream must still be bounded by requestTimeout")
        XCTAssertEqual(capture.steps.count, 1)
        let record = try XCTUnwrap(capture.steps[0].record)
        XCTAssertEqual(record.phase, "timeout")
        XCTAssertGreaterThanOrEqual(
            mock.stopCallCount, 1,
            "onTimeout must route through InferenceService.cancel(_:) to InferenceBackend.stopGeneration(), not just abandon the operation task"
        )
    }

    func test_editStep_mutatesMessageArray_withoutGeneration() async {
        let (service, mock) = makeService(replying: ["r1"])
        let runner = SessionScriptRunner(service: service)
        let script = SessionScript(
            id: "edit-no-regen",
            steps: [
                .send(text: "original"),
                .edit(messageIndex: 0, newText: "edited"),
            ]
        )
        _ = await runner.execute(script)
        // Edit alone should NOT trigger a second generate.
        XCTAssertEqual(mock.generateCallCount, 1)
    }

    func test_regenerateStep_dropsAssistantAndEnqueuesAgain() async {
        let (service, mock) = makeService(replying: ["first"])
        let runner = SessionScriptRunner(service: service)
        let script = SessionScript(
            id: "regen",
            steps: [
                .send(text: "hello"),
                .regenerate,
            ]
        )
        _ = await runner.execute(script)
        XCTAssertEqual(mock.generateCallCount, 2,
            "regenerate must re-enqueue and produce a second generate() call")
    }

    func test_deleteWithInvalidIndex_emitsTimelineEvent() async {
        let (service, _) = makeService()
        let runner = SessionScriptRunner(service: service)
        let script = SessionScript(
            id: "bad-delete",
            steps: [.delete(messageIndex: 999)]
        )
        let capture = await runner.execute(script)
        XCTAssertEqual(capture.steps[0].timeline, .indexOutOfRange)
    }

    func test_stepOrdering_preservesScriptOrder() async {
        let (service, _) = makeService(replying: ["hi"])
        let runner = SessionScriptRunner(service: service)
        let script = SessionScript(
            id: "ordering",
            steps: [
                .send(text: "one"),
                .stop,
                .edit(messageIndex: 0, newText: "two"),
                .regenerate,
            ]
        )
        let capture = await runner.execute(script)
        XCTAssertEqual(capture.steps.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(capture.steps.map(\.timeline), [
            .executed, .stopRequested, .edited, .executed,
        ])
    }

    // MARK: - 2026-07 inert-code audit findings #39 / #45

    /// `--tools` (`Options.toolDefinitions`) must reach `GenerationConfig.tools`
    /// on the session-scripts path — previously silently ignored there while
    /// working on the single-turn `FuzzRunner` path. Needs a tool-capable mock
    /// backend — `MockInferenceBackend`'s default `supportsToolCalling: false`
    /// makes `GenerationQueue` reject a tool-carrying enqueue before `generate`
    /// is ever called, which would otherwise mask this exact wiring gap.
    func test_toolDefinitions_reachGenerationConfig() async throws {
        let mock = MockInferenceBackend(capabilities: BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false
        ))
        mock.tokensToYield = ["ok"]
        mock.isModelLoaded = true
        let service = InferenceService(backend: mock, name: "SessionRunnerTest")
        let tools = SyntheticToolset.definitions
        XCTAssertFalse(tools.isEmpty, "test precondition: SyntheticToolset must declare at least one tool")
        let runner = SessionScriptRunner(
            service: service,
            options: .init(modelId: "mock-1", toolDefinitions: tools)
        )
        let script = SessionScript(id: "tools", steps: [.send(text: "hi")])
        _ = await runner.execute(script)

        XCTAssertEqual(mock.lastConfig?.tools.map(\.name), tools.map(\.name))
        XCTAssertEqual(mock.lastConfig?.toolChoice, .auto)
    }

    /// No tools configured → `GenerationConfig.tools` stays empty, matching the
    /// single-turn path's default (no tool-choice constraint imposed).
    func test_noToolDefinitions_leavesGenerationConfigToolsEmpty() async throws {
        let (service, mock) = makeService(replying: ["ok"])
        let runner = SessionScriptRunner(service: service, options: .init(modelId: "mock-1"))
        let script = SessionScript(id: "no-tools", steps: [.send(text: "hi")])
        _ = await runner.execute(script)

        XCTAssertEqual(mock.lastConfig?.tools, [])
    }

    /// `Options.contextLimit` / `Options.memoryBudgetBytes` must land on the
    /// captured `RunRecord`'s `ConfigSnapshot.contextLimit` /
    /// `ModelSnapshot.memoryBudgetBytes` — feeding
    /// `ContextExhaustionSilentDetector` / `MemoryGrowthDetector`'s previously
    /// permanently-dead branches. `PromptSnapshot.estimatedPromptTokens` must
    /// be populated too, independent of whether a limit/budget was supplied.
    func test_capturesContextLimitAndMemoryBudgetOnRunRecord() async throws {
        let (service, _) = makeService(replying: ["ok"])
        let runner = SessionScriptRunner(
            service: service,
            options: .init(modelId: "mock-1", contextLimit: 4096, memoryBudgetBytes: 1_000_000)
        )
        let script = SessionScript(id: "budget", steps: [.send(text: "hello there")])
        let capture = await runner.execute(script)
        let record = try XCTUnwrap(capture.steps[0].record)

        XCTAssertEqual(record.config.contextLimit, 4096)
        XCTAssertEqual(record.model.memoryBudgetBytes, 1_000_000)
        XCTAssertNotNil(record.prompt.estimatedPromptTokens)
        XCTAssertGreaterThan(try XCTUnwrap(record.prompt.estimatedPromptTokens), 0)
    }

    /// Without an explicit `contextLimit`/`memoryBudgetBytes`, both stay `nil` —
    /// no fabricated defaults — while `estimatedPromptTokens` is still computed
    /// (it only needs the message text, not backend metadata).
    func test_omittedContextLimitAndMemoryBudgetStayNil() async throws {
        let (service, _) = makeService(replying: ["ok"])
        let runner = SessionScriptRunner(service: service, options: .init(modelId: "mock-1"))
        let script = SessionScript(id: "no-budget", steps: [.send(text: "hello there")])
        let capture = await runner.execute(script)
        let record = try XCTUnwrap(capture.steps[0].record)

        XCTAssertNil(record.config.contextLimit)
        XCTAssertNil(record.model.memoryBudgetBytes)
        XCTAssertNotNil(record.prompt.estimatedPromptTokens)
    }

    func test_turnRecords_filtersNonExecutedSteps() async {
        let (service, _) = makeService(replying: ["r"])
        let runner = SessionScriptRunner(service: service)
        let script = SessionScript(
            id: "filter",
            steps: [.send(text: "a"), .edit(messageIndex: 0, newText: "b"), .regenerate]
        )
        let capture = await runner.execute(script)
        XCTAssertEqual(capture.turnRecords.count, 2,
            "only the two enqueue-producing steps should appear in turnRecords")
    }
}
