import XCTest
@testable import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldTestSupport
import ManifoldPersistenceTestSupport

/// Tests for ``ConversationRun`` and ``RunStep`` value type invariants, plus
/// ``ResumableRunDriver`` lifecycle (start → complete path).
///
/// Classification: Unit (in-memory SwiftData, MockInferenceBackend — no real
/// model, no network, injected IDs/dates for determinism).
@MainActor
final class ConversationRunStateTests: XCTestCase {

    // MARK: - ConversationRun value type

    func test_conversationRun_defaultStatus_isPending() {
        let run = ConversationRun(sessionID: UUID(), goal: "Do something")
        XCTAssertEqual(run.status, .pending)
        XCTAssertEqual(run.stepCount, 0)
        XCTAssertNil(run.maxSteps)
    }

    func test_conversationRun_fullInit_roundtrip() {
        let id = UUID()
        let sessionID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let run = ConversationRun(
            id: id,
            sessionID: sessionID,
            goal: "Explicit init",
            status: .running,
            stepCount: 3,
            maxSteps: 10,
            createdAt: now,
            updatedAt: now
        )
        XCTAssertEqual(run.id, id)
        XCTAssertEqual(run.sessionID, sessionID)
        XCTAssertEqual(run.goal, "Explicit init")
        XCTAssertEqual(run.status, .running)
        XCTAssertEqual(run.stepCount, 3)
        XCTAssertEqual(run.maxSteps, 10)
    }

    func test_conversationRun_statusTransitions_allCasesExist() {
        // Exhaustive: if RunStatus grows, this test points at the gap.
        let allCases = RunStatus.allCases
        XCTAssertTrue(allCases.contains(.pending))
        XCTAssertTrue(allCases.contains(.running))
        XCTAssertTrue(allCases.contains(.paused))
        XCTAssertTrue(allCases.contains(.completed))
        XCTAssertTrue(allCases.contains(.cancelled))
        XCTAssertTrue(allCases.contains(.failed))
        XCTAssertEqual(allCases.count, 6, "Update when adding RunStatus cases")
    }

    func test_conversationRun_equatable() {
        let id = UUID()
        let sessionID = UUID()
        let now = Date()
        let a = ConversationRun(id: id, sessionID: sessionID, goal: "g",
                                 createdAt: now, updatedAt: now)
        var b = ConversationRun(id: id, sessionID: sessionID, goal: "g",
                                 createdAt: now, updatedAt: now)
        XCTAssertEqual(a, b)

        b.status = .running
        XCTAssertNotEqual(a, b, "Mutated status must break equality")
    }

    // MARK: - RunStep value type

    func test_runStep_defaultValues() {
        let runID = UUID()
        let step = RunStep(runID: runID, stepIndex: 2, turnInput: nil)
        XCTAssertEqual(step.runID, runID)
        XCTAssertEqual(step.stepIndex, 2)
        XCTAssertNil(step.turnInput)
        XCTAssertNil(step.messageID)
        XCTAssertFalse(step.isCompleted)
        XCTAssertFalse(step.isFailed)
        XCTAssertNil(step.failureReason)
    }

    // MARK: - ResumableRunDriver: single-step run lifecycle

    /// InMemoryRunStore for the driver tests. Not shared with the contract
    /// suite above — each test class uses its own isolated instance.
    @MainActor
    private final class InMemoryRunStore2: RunStore {
        private var runs: [ConversationRun] = []
        private var steps: [RunStep] = []

        func insertRun(_ run: ConversationRun) async throws { runs.append(run) }
        func updateRun(_ run: ConversationRun) async throws {
            guard let i = runs.firstIndex(where: { $0.id == run.id }) else {
                throw RunStoreError.runNotFound(run.id)
            }
            runs[i] = run
        }
        func deleteRun(_ id: UUID) async throws {
            guard let i = runs.firstIndex(where: { $0.id == id }) else {
                throw RunStoreError.runNotFound(id)
            }
            runs.remove(at: i)
        }
        func fetchRuns(for sessionID: UUID) async throws -> [ConversationRun] {
            runs.filter { $0.sessionID == sessionID }
        }
        func fetchRun(_ id: UUID) async throws -> ConversationRun? {
            runs.first(where: { $0.id == id })
        }
        func insertStep(_ step: RunStep) async throws { steps.append(step) }
        func updateStep(_ step: RunStep) async throws {
            guard let i = steps.firstIndex(where: { $0.id == step.id }) else {
                throw RunStoreError.stepNotFound(step.id)
            }
            steps[i] = step
        }
        func fetchSteps(for runID: UUID) async throws -> [RunStep] {
            steps.filter { $0.runID == runID }.sorted { $0.stepIndex < $1.stepIndex }
        }
    }

    func test_resolvableRunDriver_singleStep_completesSuccessfully() async throws {
        let persistenceStack = try InMemoryPersistenceHarness.make()
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["Done"]
        let service = InferenceService(backend: backend, name: "RunDriverTest")

        let runStore = InMemoryRunStore2()
        let driver = ResumableRunDriver(runStore: runStore)
        let runtime = ConversationRuntime(
            messageStore: persistenceStack.provider,
            sessionStore: persistenceStack.provider,
            inferenceService: service,
            emptyResponseObserver: nil,
            turnDriver: driver
        )

        let sessionID = UUID()
        let run = ConversationRun(sessionID: sessionID, goal: "Test single step")

        var events: [RunEvent] = []
        let stream = runtime.startRun(run, using: FixedGoalRunInputProvider())

        // Drain the stream with a deadline.
        let end = ContinuousClock.now.advanced(by: .seconds(10))
        for await event in stream {
            events.append(event)
            if case .runCompleted = event { break }
            if case .runFailed = event { break }
            if ContinuousClock.now > end { break }
        }

        // Verify event sequence.
        XCTAssertTrue(events.contains { if case .runStarted = $0 { return true }; return false },
                      "Expected .runStarted event")
        XCTAssertTrue(events.contains { if case .stepStarted = $0 { return true }; return false },
                      "Expected .stepStarted event")
        XCTAssertTrue(events.contains { if case .stepCompleted = $0 { return true }; return false },
                      "Expected .stepCompleted event")
        XCTAssertTrue(events.contains { if case .runCompleted = $0 { return true }; return false },
                      "Expected .runCompleted event")

        // The final run record should be .completed with stepCount == 1.
        let stored = try await runStore.fetchRun(run.id)
        let storedRun = try XCTUnwrap(stored, "Run should be persisted")
        XCTAssertEqual(storedRun.status, .completed)
        XCTAssertEqual(storedRun.stepCount, 1)

        // A message was persisted for the step.
        let messages = try await persistenceStack.provider.fetchMessages(for: sessionID)
        XCTAssertEqual(messages.count, 2, "Expected user + assistant messages")
    }

    func test_resolvableRunDriver_noRunActive_behavesLikeSingleTurn() async throws {
        // When ResumableRunDriver is wired but processTurn is called directly
        // (without startRun), behavior must be identical to SingleTurnDriver.
        let persistenceStack = try InMemoryPersistenceHarness.make()
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["Hi"]
        let service = InferenceService(backend: backend, name: "FallbackTest")

        let runStore = InMemoryRunStore2()
        let driver = ResumableRunDriver(runStore: runStore)
        let runtime = ConversationRuntime(
            messageStore: persistenceStack.provider,
            sessionStore: persistenceStack.provider,
            inferenceService: service,
            emptyResponseObserver: nil,
            turnDriver: driver
        )

        let sessionID = UUID()
        let handle = try await runtime.processTurnWithOutcome(
            TurnInput(sessionID: sessionID, kind: .send(text: "Fallback"))
        )
        await handle?.outcome

        let messages = try await persistenceStack.provider.fetchMessages(for: sessionID)
        XCTAssertEqual(messages.count, 2, "Direct processTurn must produce user + assistant message")
    }

    func test_resolvableRunDriver_maxSteps_completesEarly() async throws {
        let persistenceStack = try InMemoryPersistenceHarness.make()
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["Step"]
        let service = InferenceService(backend: backend, name: "MaxStepsTest")

        let runStore = InMemoryRunStore2()
        let driver = ResumableRunDriver(runStore: runStore)
        let runtime = ConversationRuntime(
            messageStore: persistenceStack.provider,
            sessionStore: persistenceStack.provider,
            inferenceService: service,
            emptyResponseObserver: nil,
            turnDriver: driver
        )

        // A provider that would run forever, but maxSteps = 0 terminates immediately.
        let sessionID = UUID()
        let run = ConversationRun(
            id: UUID(), sessionID: sessionID, goal: "Max steps 0",
            status: .pending, stepCount: 0, maxSteps: 0,
            createdAt: Date(), updatedAt: Date()
        )

        var events: [RunEvent] = []
        let stream = runtime.startRun(run, using: FixedGoalRunInputProvider())
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        for await event in stream {
            events.append(event)
            if case .runCompleted = event { break }
            if case .runFailed = event { break }
            if ContinuousClock.now > end { break }
        }

        // maxSteps = 0 completes immediately without executing any steps.
        XCTAssertTrue(events.contains { if case .runCompleted = $0 { return true }; return false },
                      "maxSteps=0 run should complete without steps")
        XCTAssertFalse(events.contains { if case .stepStarted = $0 { return true }; return false },
                       "No steps should have started when maxSteps=0")
    }

    // MARK: - Multi-step provider

    /// Drives a fixed number of `.send` steps, then returns `nil` to complete.
    /// Each step's text encodes its index so step attribution is verifiable.
    private struct CountingProvider: RunInputProvider {
        let stepCount: Int
        func nextInput(
            for run: ConversationRun,
            stepIndex: Int,
            prior: RunStep?
        ) async -> TurnInput? {
            guard stepIndex < stepCount else { return nil }
            return TurnInput(
                sessionID: run.sessionID,
                kind: .send(text: "step-\(stepIndex)"),
                config: TurnConfig()
            )
        }
    }

    func test_resumableRunDriver_multiStep_runsEachStepInOrder() async throws {
        let persistenceStack = try InMemoryPersistenceHarness.make()
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["ok"]
        let service = InferenceService(backend: backend, name: "MultiStepTest")

        let runStore = InMemoryRunStore2()
        let driver = ResumableRunDriver(runStore: runStore)
        let runtime = ConversationRuntime(
            messageStore: persistenceStack.provider,
            sessionStore: persistenceStack.provider,
            inferenceService: service,
            emptyResponseObserver: nil,
            turnDriver: driver
        )

        let run = ConversationRun(sessionID: UUID(), goal: "multi")
        var events: [RunEvent] = []
        let end = ContinuousClock.now.advanced(by: .seconds(15))
        for await event in runtime.startRun(run, using: CountingProvider(stepCount: 3)) {
            events.append(event)
            if case .runCompleted = event { break }
            if case .runFailed = event { break }
            if ContinuousClock.now > end { break }
        }

        // Three steps must have started, in index order 0,1,2.
        let startedIndices: [Int] = events.compactMap {
            if case let .stepStarted(_, idx, _) = $0 { return idx }
            return nil
        }
        XCTAssertEqual(startedIndices, [0, 1, 2], "Steps must run in ascending index order")

        // Persisted step records mirror the three steps.
        let steps = try await runStore.fetchSteps(for: run.id)
        XCTAssertEqual(steps.map(\.stepIndex), [0, 1, 2])
        XCTAssertTrue(steps.allSatisfy(\.isCompleted), "All steps should be marked completed")

        let fetchedRun = try await runStore.fetchRun(run.id)
        let stored = try XCTUnwrap(fetchedRun)
        XCTAssertEqual(stored.status, .completed)
        XCTAssertEqual(stored.stepCount, 3)
    }

    // MARK: - Cancel

    /// Provider that requests cancellation on the driver once the run reaches
    /// step 1, then keeps offering steps. Cancellation is deterministic — it
    /// is driven off the run's own step progression, not a timer.
    private struct CancelAtStepProvider: RunInputProvider {
        let driver: ResumableRunDriver
        func nextInput(
            for run: ConversationRun,
            stepIndex: Int,
            prior: RunStep?
        ) async -> TurnInput? {
            if stepIndex == 1 { await driver.cancelRun() }
            // Keep offering steps so only the cancel can terminate the run.
            return TurnInput(
                sessionID: run.sessionID,
                kind: .send(text: "step-\(stepIndex)"),
                config: TurnConfig()
            )
        }
    }

    func test_resumableRunDriver_cancel_stopsRunWithCancelledStatus() async throws {
        let persistenceStack = try InMemoryPersistenceHarness.make()
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["ok"]
        let service = InferenceService(backend: backend, name: "CancelTest")

        let runStore = InMemoryRunStore2()
        let driver = ResumableRunDriver(runStore: runStore)
        let runtime = ConversationRuntime(
            messageStore: persistenceStack.provider,
            sessionStore: persistenceStack.provider,
            inferenceService: service,
            emptyResponseObserver: nil,
            turnDriver: driver
        )

        let provider = CancelAtStepProvider(driver: driver)
        let run = ConversationRun(sessionID: UUID(), goal: "cancel me")
        var sawCancelled = false
        let end = ContinuousClock.now.advanced(by: .seconds(15))
        for await event in runtime.startRun(run, using: provider) {
            if case .runCancelled = event { sawCancelled = true; break }
            if case .runCompleted = event { break }
            if case .runFailed = event { break }
            if ContinuousClock.now > end { break }
        }

        XCTAssertTrue(sawCancelled, "Run should terminate via .runCancelled once cancelRun() is requested")
        let fetchedRun = try await runStore.fetchRun(run.id)
        let stored = try XCTUnwrap(fetchedRun)
        XCTAssertEqual(stored.status, .cancelled, "Persisted run must reflect cancelled status")
    }

    // MARK: - Resume from store (M1 replay-from-provider)

    /// Records the step indices a provider was asked for. An actor keeps the
    /// recorder safe under the driver's off-main-actor step loop.
    private actor IndexRecorder {
        private(set) var requested: [Int] = []
        func record(_ index: Int) { requested.append(index) }
    }

    /// Counting provider that records which step indices it was asked for, so
    /// resume tests can assert the loop skipped already-completed steps.
    /// Idempotent: keys only on `stepIndex` and `run.goal` (satisfies the
    /// M1 ``RunInputProvider`` contract).
    private struct RecordingCountingProvider: RunInputProvider {
        let stepCount: Int
        let recorder: IndexRecorder
        func nextInput(
            for run: ConversationRun,
            stepIndex: Int,
            prior: RunStep?
        ) async -> TurnInput? {
            await recorder.record(stepIndex)
            guard stepIndex < stepCount else { return nil }
            return TurnInput(
                sessionID: run.sessionID,
                kind: .send(text: "step-\(stepIndex)"),
                config: TurnConfig()
            )
        }
    }

    func test_resume_continuesFromCheckpoint() async throws {
        let persistenceStack = try InMemoryPersistenceHarness.make()
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["ok"]
        let service = InferenceService(backend: backend, name: "ResumeTest")

        let runStore = InMemoryRunStore2()
        let driver = ResumableRunDriver(runStore: runStore)
        let runtime = ConversationRuntime(
            messageStore: persistenceStack.provider,
            sessionStore: persistenceStack.provider,
            inferenceService: service,
            emptyResponseObserver: nil,
            turnDriver: driver
        )

        // Pre-seed: a running run (maxSteps 3) with step 0 already completed.
        let runID = UUID()
        let sessionID = UUID()
        let now = Date()
        let seededRun = ConversationRun(
            id: runID, sessionID: sessionID, goal: "resume me",
            status: .running, stepCount: 1, maxSteps: 3,
            createdAt: now, updatedAt: now
        )
        try await runStore.insertRun(seededRun)
        let step0 = RunStep(
            id: UUID(), runID: runID, stepIndex: 0,
            turnInput: TurnInput(sessionID: sessionID, kind: .send(text: "step-0")),
            messageID: nil, isCompleted: true, isFailed: false, failureReason: nil,
            createdAt: now, updatedAt: now
        )
        try await runStore.insertStep(step0)

        let recorder = IndexRecorder()
        let provider = RecordingCountingProvider(stepCount: 3, recorder: recorder)
        var events: [RunEvent] = []
        let end = ContinuousClock.now.advanced(by: .seconds(15))
        for await event in runtime.resumeRun(runID, using: provider) {
            events.append(event)
            if case .runCompleted = event { break }
            if case .runFailed = event { break }
            if ContinuousClock.now > end { break }
        }

        // The provider was asked for indices 1 and 2 (not 0 — already done),
        // then 3 (which returns nil → completion is the maxSteps guard anyway).
        let requested = await recorder.requested
        XCTAssertEqual(requested, [1, 2],
                       "Resume must re-drive only the not-yet-completed indices")

        // Resume announces itself, then runs steps 1 and 2.
        XCTAssertTrue(events.contains { if case .runResumed = $0 { return true }; return false },
                      "Expected a .runResumed event on resume")
        let startedIndices: [Int] = events.compactMap {
            if case let .stepStarted(_, idx, _) = $0 { return idx }
            return nil
        }
        XCTAssertEqual(startedIndices, [1, 2], "Resume should start steps 1 and 2 only")
        XCTAssertTrue(events.contains { if case .runCompleted = $0 { return true }; return false },
                      "Run should complete after reaching maxSteps")

        let fetchedForAssert = try await runStore.fetchRun(runID)
        let stored = try XCTUnwrap(fetchedForAssert)
        XCTAssertEqual(stored.status, .completed)
        XCTAssertEqual(stored.stepCount, 3, "stepCount = 1 seeded + 2 resumed")

        // The completed steps in the store are 0 (seeded), 1, 2.
        let completed = try await runStore.fetchSteps(for: runID).filter(\.isCompleted)
        XCTAssertEqual(completed.map(\.stepIndex), [0, 1, 2])
    }

    func test_resume_unknownRunID_failsWithoutExecution() async throws {
        let persistenceStack = try InMemoryPersistenceHarness.make()
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        let service = InferenceService(backend: backend, name: "ResumeUnknownTest")

        let runStore = InMemoryRunStore2()
        let driver = ResumableRunDriver(runStore: runStore)
        let runtime = ConversationRuntime(
            messageStore: persistenceStack.provider,
            sessionStore: persistenceStack.provider,
            inferenceService: service,
            emptyResponseObserver: nil,
            turnDriver: driver
        )

        let unknownID = UUID()
        let recorder = IndexRecorder()
        let provider = RecordingCountingProvider(stepCount: 3, recorder: recorder)
        var events: [RunEvent] = []
        for await event in runtime.resumeRun(unknownID, using: provider) {
            events.append(event)
        }

        XCTAssertEqual(events.count, 1, "Unknown run should emit exactly one terminal event")
        guard case let .runFailed(failedID, reason) = events.first else {
            return XCTFail("Expected .runFailed for an unknown run id")
        }
        XCTAssertEqual(failedID, unknownID)
        XCTAssertTrue(reason.contains(unknownID.uuidString), "Reason should name the missing run id")
        let requested = await recorder.requested
        XCTAssertTrue(requested.isEmpty, "No steps should be driven for an unknown run")
    }

    func test_resume_alreadyCompletedRun_emitsTerminalWithoutExecution() async throws {
        let persistenceStack = try InMemoryPersistenceHarness.make()
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        let service = InferenceService(backend: backend, name: "ResumeCompletedTest")

        let runStore = InMemoryRunStore2()
        let driver = ResumableRunDriver(runStore: runStore)
        let runtime = ConversationRuntime(
            messageStore: persistenceStack.provider,
            sessionStore: persistenceStack.provider,
            inferenceService: service,
            emptyResponseObserver: nil,
            turnDriver: driver
        )

        let runID = UUID()
        let now = Date()
        let completedRun = ConversationRun(
            id: runID, sessionID: UUID(), goal: "done",
            status: .completed, stepCount: 2, maxSteps: nil,
            createdAt: now, updatedAt: now
        )
        try await runStore.insertRun(completedRun)

        let recorder = IndexRecorder()
        let provider = RecordingCountingProvider(stepCount: 3, recorder: recorder)
        var events: [RunEvent] = []
        for await event in runtime.resumeRun(runID, using: provider) {
            events.append(event)
        }

        XCTAssertEqual(events.count, 1, "A finished run should emit one terminal event only")
        guard case let .runCompleted(id, stepCount) = events.first else {
            return XCTFail("Expected .runCompleted terminal event for an already-completed run")
        }
        XCTAssertEqual(id, runID)
        XCTAssertEqual(stepCount, 2)
        let requested = await recorder.requested
        XCTAssertTrue(requested.isEmpty, "No steps should be driven for a finished run")
    }

    func test_startRun_unchanged_startsAtIndexZero() async throws {
        // Regression guard: after extracting the shared loop, a fresh startRun
        // must still begin at index 0 (priorStep nil) and run all provider steps.
        let persistenceStack = try InMemoryPersistenceHarness.make()
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["ok"]
        let service = InferenceService(backend: backend, name: "StartRunRegressionTest")

        let runStore = InMemoryRunStore2()
        let driver = ResumableRunDriver(runStore: runStore)
        let runtime = ConversationRuntime(
            messageStore: persistenceStack.provider,
            sessionStore: persistenceStack.provider,
            inferenceService: service,
            emptyResponseObserver: nil,
            turnDriver: driver
        )

        let recorder = IndexRecorder()
        let provider = RecordingCountingProvider(stepCount: 2, recorder: recorder)
        let run = ConversationRun(sessionID: UUID(), goal: "fresh")
        var events: [RunEvent] = []
        let end = ContinuousClock.now.advanced(by: .seconds(15))
        for await event in runtime.startRun(run, using: provider) {
            events.append(event)
            if case .runCompleted = event { break }
            if case .runFailed = event { break }
            if ContinuousClock.now > end { break }
        }

        let requested = await recorder.requested
        XCTAssertEqual(requested.first, 0, "Fresh startRun must begin at index 0")
        XCTAssertTrue(events.contains { if case .runStarted = $0 { return true }; return false },
                      "Fresh startRun must emit .runStarted, not .runResumed")
        XCTAssertFalse(events.contains { if case .runResumed = $0 { return true }; return false },
                       "Fresh startRun must not emit .runResumed")
        let startedIndices: [Int] = events.compactMap {
            if case let .stepStarted(_, idx, _) = $0 { return idx }
            return nil
        }
        XCTAssertEqual(startedIndices, [0, 1])
    }

    // MARK: - startRun on non-ResumableRunDriver runtime

    func test_startRun_withoutResumableDriver_returnsEmptyStream() async throws {
        // ConversationRuntime defaults to SingleTurnDriver. Calling startRun
        // on it logs a warning and returns a stream that finishes immediately.
        let persistenceStack = try InMemoryPersistenceHarness.make()
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        let service = InferenceService(backend: backend, name: "WarnTest")
        let runtime = ConversationRuntime(
            messageStore: persistenceStack.provider,
            sessionStore: persistenceStack.provider,
            inferenceService: service
        )

        let run = ConversationRun(sessionID: UUID(), goal: "Should not start")
        var events: [RunEvent] = []
        for await event in runtime.startRun(run) {
            events.append(event)
        }
        // The stream should finish immediately with no events.
        XCTAssertTrue(events.isEmpty, "Non-resumable runtime must return an empty RunEvent stream")
    }
}
