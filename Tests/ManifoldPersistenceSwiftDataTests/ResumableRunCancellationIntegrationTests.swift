import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldRuntime
import ManifoldTestSupport
import ManifoldPersistenceTestSupport

/// Cancellation boundary tests over real in-memory SwiftData. The forwarding
/// observer delays operations but never substitutes persistence behavior.
@MainActor
final class ResumableRunCancellationIntegrationTests: XCTestCase {
    private actor Gate {
        let reached: XCTestExpectation
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private var entered = false

        init(_ reached: XCTestExpectation) { self.reached = reached }
        func wait() async {
            if !entered {
                entered = true
                reached.fulfill()
            }
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private struct GatedProvider: RunInputProvider {
        let gate: Gate
        func nextInput(for run: ConversationRun, stepIndex: Int, prior: RunStep?) async -> TurnInput? {
            guard stepIndex == 0 else { return nil }
            await gate.wait()
            return TurnInput(sessionID: run.sessionID, kind: .send(text: run.goal))
        }
    }

    private final class ObservedStore: RunStore {
        let base: SwiftDataRunStore
        var fetchGate: Gate?
        var insertGate: Gate?
        var updateGate: Gate?
        var fetchCount = 0
        var abandonedCheckpoint: XCTestExpectation?
        var stepWrites = 0
        private var statusObservers: [(UUID, RunStatus, XCTestExpectation)] = []
        func expectStatus(_ status: RunStatus, for runID: UUID) async throws -> XCTestExpectation {
            let expectation = XCTestExpectation(description: "run reaches \(status)")
            if try await base.fetchRun(runID)?.status == status {
                expectation.fulfill()
            } else {
                statusObservers.append((runID, status, expectation))
            }
            return expectation
        }

        init(_ base: SwiftDataRunStore) { self.base = base }
        func insertRun(_ run: ConversationRun) async throws { try await base.insertRun(run) }
        func updateRun(_ run: ConversationRun) async throws {
            try await base.updateRun(run)
            if run.status == .paused || run.status == .cancelled {
                abandonedCheckpoint?.fulfill()
                abandonedCheckpoint = nil
            }
            let matching = statusObservers.filter { $0.0 == run.id && $0.1 == run.status }
            statusObservers.removeAll { $0.0 == run.id && $0.1 == run.status }
            for (_, _, expectation) in matching { expectation.fulfill() }
        }
        func deleteRun(_ id: UUID) async throws { try await base.deleteRun(id) }
        func fetchRuns(for id: UUID) async throws -> [ConversationRun] { try await base.fetchRuns(for: id) }
        func fetchRun(_ id: UUID) async throws -> ConversationRun? {
            fetchCount += 1
            return try await base.fetchRun(id)
        }
        func insertStep(_ step: RunStep) async throws {
            try await base.insertStep(step)
            if let insertGate { await insertGate.wait() }
        }
        func updateStep(_ step: RunStep) async throws {
            stepWrites += 1
            try await base.updateStep(step)
            if let updateGate { await updateGate.wait() }
        }
        func fetchSteps(for id: UUID) async throws -> [RunStep] {
            let steps = try await base.fetchSteps(for: id)
            if let fetchGate { await fetchGate.wait() }
            return steps
        }
    }

    private struct Fixture {
        let harness: InMemoryPersistenceHarness.Stack
        let store: ObservedStore
        let runtime: ConversationRuntime
        let driver: ResumableRunDriver
    }

    private func makeFixture() throws -> Fixture {
        let harness = try InMemoryPersistenceHarness.make()
        let base = SwiftDataRunStore(modelContext: ModelContext(harness.container))
        let store = ObservedStore(base)
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["ok"]
        let driver = ResumableRunDriver(runStore: store)
        let runtime = ConversationRuntime(
            messageStore: harness.provider,
            sessionStore: harness.provider,
            inferenceService: InferenceService(backend: backend, name: "CancellationBoundary"),
            emptyResponseObserver: nil,
            turnDriver: driver
        )
        return Fixture(harness: harness, store: store, runtime: runtime, driver: driver)
    }

    private func joinProducer(_ fixture: Fixture) async {
        // A zero-step successor waits for the previous producer to checkpoint.
        let fence = ConversationRun(sessionID: UUID(), goal: "join", maxSteps: 0)
        for await _ in fixture.runtime.startRun(fence) {}
    }

    func test_explicitCancelAndImmediateResume_waitsForCancelledCheckpoint() async throws {
        let fixture = try makeFixture()
        let entered = expectation(description: "provider suspended")
        let gate = Gate(entered)
        let run = ConversationRun(sessionID: UUID(), goal: "cancelled", maxSteps: 1)
        let consumer = Task {
            for await _ in fixture.runtime.startRun(run, using: GatedProvider(gate: gate)) {}
        }
        await fulfillment(of: [entered], timeout: 3)
        await fixture.runtime.cancelActiveRun()
        consumer.cancel()
        await consumer.value

        let abandonedResume = Task { for await _ in fixture.runtime.resumeRun(run.id) {} }
        abandonedResume.cancel()
        await abandonedResume.value
        let resume = Task { () -> [RunEvent] in
            var events: [RunEvent] = []
            for await event in fixture.runtime.resumeRun(run.id) { events.append(event) }
            return events
        }
        // Give the successor a scheduling window while its predecessor is
        // deliberately held; no durable read may cross that held boundary.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fixture.store.fetchCount, 0, "Resume read an unfinished checkpoint")
        let checkpoint = expectation(description: "abandoned predecessor finished checkpointing")
        fixture.store.abandonedCheckpoint = checkpoint
        await gate.release()
        let events = await resume.value
        await fulfillment(of: [checkpoint], timeout: 3)
        XCTAssertEqual(fixture.store.fetchCount, 1, "A queued abandoned producer must perform no reads")
        XCTAssertEqual(events.count, 1)
        guard case .runCancelled = events.first else { return XCTFail("Explicit cancel must remain terminal") }
        let saved = try await fixture.store.base.fetchRun(run.id)
        XCTAssertEqual(saved?.status, .cancelled)
        let steps = try await fixture.store.base.fetchSteps(for: run.id)
        XCTAssertTrue(steps.isEmpty, "A cancelled provider must not replay its turn")
    }

    func test_durableResumeOfObservedPausedRun_transfersSameRunWithoutCancellingUnrelatedRun() async throws {
        let fixture = try makeFixture()
        let run = ConversationRun(sessionID: UUID(), goal: "live paused", maxSteps: 1)
        let paused = expectation(description: "original observed run paused")
        let recorder = IndexRecorder()
        var originalFinished = false
        let original = Task { () -> [RunEvent] in
            var events: [RunEvent] = []
            for await event in fixture.runtime.startRun(
                run, using: PauseAfterFirstStepProvider(driver: fixture.driver, recorder: recorder)
            ) {
                events.append(event)
                if case .runPaused = event { paused.fulfill() }
            }
            originalFinished = true
            return events
        }
        await fulfillment(of: [paused], timeout: 3)
        let unrelated = ConversationRun(id: UUID(), sessionID: UUID(), goal: "unrelated",
                                        status: .paused, createdAt: Date(), updatedAt: Date())
        try await fixture.store.base.insertRun(unrelated)
        var rejected: [RunEvent] = []
        for await event in fixture.runtime.resumeRun(unrelated.id) { rejected.append(event) }
        guard case .runFailed = rejected.first else {
            original.cancel()
            await original.value
            return XCTFail("An unrelated live run must fail busy")
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(originalFinished, "An unrelated resume must leave the observed producer alive")
        let unchanged = try await fixture.store.base.fetchRun(unrelated.id)
        XCTAssertEqual(unchanged?.updatedAt, unrelated.updatedAt)
        let live = try await fixture.store.base.fetchRun(run.id)
        XCTAssertEqual(live?.status, .paused)

        var resumed: [RunEvent] = []
        for await event in fixture.runtime.resumeRun(run.id) { resumed.append(event) }
        let originalEvents = await original.value
        XCTAssertTrue(originalEvents.contains(.runPaused(runID: run.id, stepCount: 1)))
        XCTAssertEqual(resumed.last, .runCompleted(runID: run.id, stepCount: 1))
        let steps = try await fixture.store.base.fetchSteps(for: run.id)
        XCTAssertEqual(steps.filter(\.isCompleted).count, 1)
        let final = try await fixture.store.base.fetchRun(run.id)
        XCTAssertEqual(final?.status, .completed)
    }

    func test_dropDuringResumeFetch_leavesSavedRunAndStepUnchanged() async throws {
        let fixture = try makeFixture()
        let run = ConversationRun(id: UUID(), sessionID: UUID(), goal: "saved", status: .paused, createdAt: Date(), updatedAt: Date())
        let step = RunStep(runID: run.id, stepIndex: 0,
                           turnInput: TurnInput(sessionID: run.sessionID, kind: .send(text: "saved")))
        try await fixture.store.base.insertRun(run)
        try await fixture.store.base.insertStep(step)
        let entered = expectation(description: "fetch suspended")
        let gate = Gate(entered)
        fixture.store.fetchGate = gate
        let consumer = Task { for await _ in fixture.runtime.resumeRun(run.id) {} }
        await fulfillment(of: [entered], timeout: 3)
        consumer.cancel()
        await consumer.value
        await gate.release()
        await joinProducer(fixture)
        XCTAssertEqual(fixture.store.stepWrites, 0)
        let savedRun = try await fixture.store.base.fetchRun(run.id)
        let savedSteps = try await fixture.store.base.fetchSteps(for: run.id)
        XCTAssertEqual(savedRun?.status, run.status)
        XCTAssertEqual(savedRun?.updatedAt, run.updatedAt)
        XCTAssertEqual(savedSteps.first?.failureReason, step.failureReason)
        XCTAssertEqual(savedSteps.first?.updatedAt, step.updatedAt)
    }

    func test_dropDuringSupersedingWrite_stopsBeforeNextSavedStepMutation() async throws {
        let fixture = try makeFixture()
        let run = ConversationRun(id: UUID(), sessionID: UUID(), goal: "saved", status: .paused, createdAt: Date(), updatedAt: Date())
        let first = RunStep(runID: run.id, stepIndex: 0, turnInput: nil)
        let second = RunStep(runID: run.id, stepIndex: 1, turnInput: nil)
        try await fixture.store.base.insertRun(run)
        try await fixture.store.base.insertStep(first)
        try await fixture.store.base.insertStep(second)
        let entered = expectation(description: "first superseding write suspended")
        let gate = Gate(entered)
        fixture.store.updateGate = gate
        let consumer = Task { for await _ in fixture.runtime.resumeRun(run.id) {} }
        await fulfillment(of: [entered], timeout: 3)
        consumer.cancel()
        await consumer.value
        await gate.release()
        await joinProducer(fixture)
        XCTAssertEqual(fixture.store.stepWrites, 1)
        let savedRun = try await fixture.store.base.fetchRun(run.id)
        let savedSteps = try await fixture.store.base.fetchSteps(for: run.id)
        XCTAssertEqual(savedRun?.updatedAt, run.updatedAt)
        XCTAssertEqual(savedSteps.first { $0.id == second.id }?.failureReason, nil)
        XCTAssertEqual(savedSteps.first { $0.id == second.id }?.updatedAt, second.updatedAt)
    }

    func test_dropDuringStepInsert_checkpointsWithoutExecutingTurn_thenResumes() async throws {
        let fixture = try makeFixture()
        let entered = expectation(description: "insert suspended")
        let gate = Gate(entered)
        fixture.store.insertGate = gate
        let run = ConversationRun(sessionID: UUID(), goal: "retry", maxSteps: 1)
        let consumer = Task { for await _ in fixture.runtime.startRun(run) {} }
        await fulfillment(of: [entered], timeout: 3)
        consumer.cancel()
        await consumer.value
        await gate.release()
        await joinProducer(fixture)
        fixture.store.insertGate = nil
        let savedRun = try await fixture.store.base.fetchRun(run.id)
        let steps = try await fixture.store.base.fetchSteps(for: run.id)
        XCTAssertEqual(savedRun?.status, .paused)
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps.first?.isCompleted, false)
        let messagesBefore = try await fixture.harness.provider.fetchMessages(for: run.sessionID)
        XCTAssertTrue(messagesBefore.isEmpty, "Dropping during insert must not persist a user turn")

        for await _ in fixture.runtime.resumeRun(run.id) {}
        let finalRun = try await fixture.store.base.fetchRun(run.id)
        let finalSteps = try await fixture.store.base.fetchSteps(for: run.id)
        XCTAssertEqual(finalRun?.status, .completed)
        XCTAssertEqual(finalSteps.filter(\.isCompleted).count, 1)
        XCTAssertEqual(finalSteps.filter { $0.failureReason == "superseded on resume" }.count, 1)
    }
    /// Requests a pause during step zero, then offers no more work. The
    /// pause is reached at a step boundary regardless of backend speed.
    private struct PauseAfterFirstStepProvider: RunInputProvider {
        let driver: ResumableRunDriver
        let recorder: IndexRecorder

        func nextInput(
            for run: ConversationRun,
            stepIndex: Int,
            prior: RunStep?
        ) async -> TurnInput? {
            await recorder.record(stepIndex)
            guard stepIndex == 0 else { return nil }
            await driver.pauseRun()
            return TurnInput(sessionID: run.sessionID, kind: .send(text: "first step"))
        }
    }

    func test_streamTerminationWhilePaused_preservesDurableCheckpoint() async throws {
        let persistenceStack = try InMemoryPersistenceHarness.make()
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["ok"]
        let service = InferenceService(backend: backend, name: "PausedTerminationTest")
        let runStore = ObservedStore(SwiftDataRunStore(modelContext: ModelContext(persistenceStack.container)))
        let driver = ResumableRunDriver(runStore: runStore)
        let runtime = ConversationRuntime(
            messageStore: persistenceStack.provider,
            sessionStore: persistenceStack.provider,
            inferenceService: service,
            emptyResponseObserver: nil,
            turnDriver: driver
        )
        let run = ConversationRun(sessionID: UUID(), goal: "pause and abandon")
        let recorder = IndexRecorder()
        let provider = PauseAfterFirstStepProvider(driver: driver, recorder: recorder)

        // Ending the consumer at runPaused must cancel the producer's wait.
        let consumer = Task { () -> RunEvent? in
            for await event in runtime.startRun(run, using: provider) {
                if case .runPaused = event { return event }
            }
            return nil
        }
        guard case let .runPaused(id, count) = await consumer.value else {
            return XCTFail("Expected the first step to reach the pause boundary")
        }
        XCTAssertEqual(id, run.id)
        XCTAssertEqual(count, 1)

        let paused = try await runStore.expectStatus(.paused, for: run.id)
        await fulfillment(of: [paused], timeout: 3)
        let pausedRun = try await runStore.fetchRun(run.id)
        XCTAssertEqual(pausedRun?.stepCount, 1)

        // Clearing the in-memory pause cannot resurrect an abandoned producer.
        await driver.resumeRun()
        try await Task.sleep(for: .milliseconds(300))
        let stillPaused = try await runStore.fetchRun(run.id)
        XCTAssertEqual(stillPaused?.status, .paused)
        let requested = await recorder.requested
        XCTAssertEqual(requested, [0])

        // The persisted checkpoint is still usable by a new stream.
        var resumedEvents: [RunEvent] = []
        for await event in runtime.resumeRun(run.id, using: CountingProvider(stepCount: 1)) {
            resumedEvents.append(event)
        }
        XCTAssertEqual(resumedEvents.last, .runCompleted(runID: run.id, stepCount: 1))
        let completedRun = try await runStore.fetchRun(run.id)
        XCTAssertEqual(completedRun?.status, .completed)
    }

    func test_explicitCancelWhilePaused_remainsTerminal() async throws {
        let persistenceStack = try InMemoryPersistenceHarness.make()
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["ok"]
        let service = InferenceService(backend: backend, name: "PausedCancelTest")
        let runStore = ObservedStore(SwiftDataRunStore(modelContext: ModelContext(persistenceStack.container)))
        let driver = ResumableRunDriver(runStore: runStore)
        let runtime = ConversationRuntime(
            messageStore: persistenceStack.provider,
            sessionStore: persistenceStack.provider,
            inferenceService: service,
            emptyResponseObserver: nil,
            turnDriver: driver
        )
        let run = ConversationRun(sessionID: UUID(), goal: "pause then cancel")
        let recorder = IndexRecorder()
        let provider = PauseAfterFirstStepProvider(driver: driver, recorder: recorder)

        var events: [RunEvent] = []
        for await event in runtime.startRun(run, using: provider) {
            events.append(event)
            if case .runPaused = event { await runtime.cancelActiveRun() }
        }
        XCTAssertTrue(events.contains(.runPaused(runID: run.id, stepCount: 1)))
        XCTAssertEqual(events.last, .runCancelled(runID: run.id, stepCount: 1))
        let stored = try await runStore.fetchRun(run.id)
        XCTAssertEqual(stored?.status, .cancelled)
        XCTAssertEqual(stored?.stepCount, 1)
        let requested = await recorder.requested
        XCTAssertEqual(requested, [0])
    }

    func test_streamTerminationDuringTurn_cancelsTurnAndLeavesReplayableStep() async throws {
        let persistenceStack = try InMemoryPersistenceHarness.make()
        let backend = SlowMockBackend(tokenCount: 100, delayMilliseconds: 100)
        let service = InferenceService(backend: backend, name: "ActiveTerminationTest")
        let runStore = ObservedStore(SwiftDataRunStore(modelContext: ModelContext(persistenceStack.container)))
        let driver = ResumableRunDriver(runStore: runStore)
        let runtime = ConversationRuntime(
            messageStore: persistenceStack.provider,
            sessionStore: persistenceStack.provider,
            inferenceService: service,
            emptyResponseObserver: nil,
            turnDriver: driver
        )
        let run = ConversationRun(sessionID: UUID(), goal: "abandon active turn")

        let consumer = Task { () -> (RunEvent?, Bool) in
            for await event in runtime.startRun(run, using: FixedGoalRunInputProvider()) {
                if case .stepStarted = event {
                    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                    while !backend.isGenerating && ContinuousClock.now < deadline {
                        do {
                            try await Task.sleep(for: .milliseconds(10))
                        } catch {
                            return (event, false)
                        }
                    }
                    return (event, backend.isGenerating)
                }
            }
            return (nil, false)
        }
        let (observedEvent, wasGenerating) = await consumer.value
        guard case let .stepStarted(id, index, _) = observedEvent else {
            return XCTFail("Expected an active step before terminating observation")
        }
        XCTAssertEqual(id, run.id)
        XCTAssertEqual(index, 0)
        XCTAssertTrue(wasGenerating, "Observation must end while generation is active")
        XCTAssertEqual(backend.generateCallCount, 1)

        let paused = try await runStore.expectStatus(.paused, for: run.id)
        await fulfillment(of: [paused], timeout: 3)
        let fetchedRun = try await runStore.fetchRun(run.id)
        let stored = try XCTUnwrap(fetchedRun)
        XCTAssertEqual(stored.status, .paused)
        XCTAssertEqual(stored.stepCount, 0)
        let steps = try await runStore.fetchSteps(for: run.id)
        XCTAssertEqual(steps.count, 1)
        XCTAssertFalse(steps[0].isCompleted)
        XCTAssertFalse(backend.isGenerating)
    }

    func test_explicitCancelThenStreamTermination_keepsTerminalCancellation() async throws {
        let persistenceStack = try InMemoryPersistenceHarness.make()
        let backend = SlowMockBackend(tokenCount: 100, delayMilliseconds: 100)
        let service = InferenceService(backend: backend, name: "CancelTerminationRaceTest")
        let runStore = ObservedStore(SwiftDataRunStore(modelContext: ModelContext(persistenceStack.container)))
        let driver = ResumableRunDriver(runStore: runStore)
        let runtime = ConversationRuntime(
            messageStore: persistenceStack.provider,
            sessionStore: persistenceStack.provider,
            inferenceService: service,
            emptyResponseObserver: nil,
            turnDriver: driver
        )
        let run = ConversationRun(sessionID: UUID(), goal: "cancel while active")

        let consumer = Task { () -> Bool in
            for await event in runtime.startRun(run, using: FixedGoalRunInputProvider()) {
                if case .stepStarted = event {
                    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                    while !backend.isGenerating && ContinuousClock.now < deadline {
                        do {
                            try await Task.sleep(for: .milliseconds(10))
                        } catch {
                            return false
                        }
                    }
                    guard backend.isGenerating else { return false }
                    await runtime.cancelActiveRun()
                    return true // Terminate observation after the explicit cancel.
                }
            }
            return false
        }
        let cancelledDuringTurn = await consumer.value
        XCTAssertTrue(cancelledDuringTurn, "Cancellation must be requested during a live turn")
        let cancelled = try await runStore.expectStatus(.cancelled, for: run.id)
        await fulfillment(of: [cancelled], timeout: 3)
        let fetched = try await runStore.fetchRun(run.id)
        XCTAssertEqual(fetched?.status, .cancelled)
        XCTAssertEqual(fetched?.stepCount, 0)
        XCTAssertFalse(backend.isGenerating)

        let recorder = IndexRecorder()
        var resumeEvents: [RunEvent] = []
        for await event in runtime.resumeRun(
            run.id, using: RecordingCountingProvider(stepCount: 1, recorder: recorder)
        ) {
            resumeEvents.append(event)
        }
        XCTAssertEqual(resumeEvents, [.runCancelled(runID: run.id, stepCount: 0)])
        let requested = await recorder.requested
        XCTAssertTrue(requested.isEmpty, "A cancelled run must never replay its step")
    }

    private struct SuspendedProvider: RunInputProvider {
        func nextInput(
            for run: ConversationRun,
            stepIndex: Int,
            prior: RunStep?
        ) async -> TurnInput? {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return nil
            }
            return TurnInput(sessionID: run.sessionID, kind: .send(text: "late work"))
        }
    }

    func test_resumeStreamTermination_leavesExistingCheckpointPaused() async throws {
        let persistenceStack = try InMemoryPersistenceHarness.make()
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        let service = InferenceService(backend: backend, name: "ResumeTerminationTest")
        let runStore = ObservedStore(SwiftDataRunStore(modelContext: ModelContext(persistenceStack.container)))
        let driver = ResumableRunDriver(runStore: runStore)
        let runtime = ConversationRuntime(
            messageStore: persistenceStack.provider,
            sessionStore: persistenceStack.provider,
            inferenceService: service,
            emptyResponseObserver: nil,
            turnDriver: driver
        )
        let now = Date()
        let run = ConversationRun(
            id: UUID(), sessionID: UUID(), goal: "resume then abandon",
            status: .paused, createdAt: now, updatedAt: now
        )
        try await runStore.insertRun(run)

        let consumer = Task { () -> RunEvent? in
            for await event in runtime.resumeRun(run.id, using: SuspendedProvider()) {
                if case .runResumed = event { return event }
            }
            return nil
        }
        guard case let .runResumed(id, count) = await consumer.value else {
            return XCTFail("Expected a resume event before observation ends")
        }
        XCTAssertEqual(id, run.id)
        XCTAssertEqual(count, 0)

        let paused = try await runStore.expectStatus(.paused, for: run.id)
        await fulfillment(of: [paused], timeout: 3)
        let fetchedRun = try await runStore.fetchRun(run.id)
        let checkpoint = try XCTUnwrap(fetchedRun)
        XCTAssertEqual(checkpoint.status, .paused)
        XCTAssertEqual(checkpoint.stepCount, 0)
        let steps = try await runStore.fetchSteps(for: run.id)
        XCTAssertTrue(steps.isEmpty)
    }

    private actor IndexRecorder {
        private(set) var requested: [Int] = []
        func record(_ index: Int) { requested.append(index) }
    }
    private struct CountingProvider: RunInputProvider {
        let stepCount: Int
        func nextInput(for run: ConversationRun, stepIndex: Int, prior: RunStep?) async -> TurnInput? {
            guard stepIndex < stepCount else { return nil }
            return TurnInput(sessionID: run.sessionID, kind: .send(text: "step-\(stepIndex)"))
        }
    }
    private struct RecordingCountingProvider: RunInputProvider {
        let stepCount: Int
        let recorder: IndexRecorder
        func nextInput(for run: ConversationRun, stepIndex: Int, prior: RunStep?) async -> TurnInput? {
            await recorder.record(stepIndex)
            return await CountingProvider(stepCount: stepCount).nextInput(for: run, stepIndex: stepIndex, prior: prior)
        }
    }
}
