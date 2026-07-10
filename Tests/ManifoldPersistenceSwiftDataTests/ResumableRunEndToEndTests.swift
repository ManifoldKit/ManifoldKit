import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldRuntime
import ManifoldTestSupport
import ManifoldPersistenceTestSupport

/// End-to-end durability proof for the P3b resumable-run stack (#1784).
///
/// Exercises the *whole* wiring path — `ConversationRuntimeOptions.runStore` →
/// `ConversationRuntime` driver selection → `ResumableRunDriver` →
/// `SwiftDataRunStore` over a real `ModelContainer` — and proves that a run
/// checkpointed by one runtime instance can be resumed to completion by a
/// fresh runtime over the *same* on-disk store, without re-running the steps
/// that already completed.
///
/// Classification: Integration (real on-disk SwiftData, MockInferenceBackend —
/// no network, no real model). The persistence layer is never mocked.
@MainActor
final class ResumableRunEndToEndTests: XCTestCase {

    private var tempStoreDirectory: URL?

    override func tearDown() async throws {
        if let tempStoreDirectory {
            try? FileManager.default.removeItem(at: tempStoreDirectory)
        }
        tempStoreDirectory = nil
        try await super.tearDown()
    }

    private func makeStoreURL() throws -> URL {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("ResumableRunE2E-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempStoreDirectory = dir
        return dir.appendingPathComponent("Manifold.sqlite")
    }

    /// Builds a fresh resumable-runs `ManifoldBootstrap` over the given on-disk
    /// store URL. Each call opens a *new* `ModelContainer` over the same file,
    /// modelling a fresh process launch — both the message store and the run
    /// store share that single container's main context (the real host shape).
    private func makeResumableBootstrap(storeURL: URL) throws -> ManifoldBootstrap {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["ok"]
        let service = InferenceService(backend: backend, name: "ResumableE2E")

        return try ManifoldBootstrap(
            configuration: ManifoldConfiguration(
                appName: "ResumableE2E",
                bundleIdentifier: "com.manifoldkit.resumable-e2e.\(UUID().uuidString)"
            ),
            inferenceService: service,
            enableResumableRuns: true,
            makeModelContainer: {
                try ModelContainerFactory.makeContainer(
                    configurations: [ModelConfiguration(url: storeURL)]
                )
            }
        )
    }

    /// Deterministic, idempotent provider that yields `.send(text:)` for the
    /// first `totalSteps` indices and `nil` afterward. Records every
    /// `stepIndex` it is asked for in a shared, cross-instance recorder so the
    /// test can prove completed steps are NOT re-driven on resume.
    private struct RecordingProvider: RunInputProvider, Sendable {
        let totalSteps: Int
        let recorder: IndexRecorder

        func nextInput(
            for run: ConversationRun,
            stepIndex: Int,
            prior: RunStep?
        ) async -> TurnInput? {
            await recorder.record(stepIndex)
            guard stepIndex < totalSteps else { return nil }
            return TurnInput(
                sessionID: run.sessionID,
                kind: .send(text: "\(run.goal) — step \(stepIndex)")
            )
        }
    }

    /// Shared recorder of the step indices the provider was asked to drive.
    /// Survives across both runtime instances so we can assert the resume run
    /// only drives indices >= the resume point.
    private actor IndexRecorder {
        private(set) var indices: [Int] = []
        func record(_ index: Int) { indices.append(index) }
        func snapshot() -> [Int] { indices }
    }

    // MARK: - The acceptance test

    func test_run_checkpointsThenResumesToCompletionOverFreshStore() async throws {
        let originalConfiguration = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfiguration }

        let storeURL = try makeStoreURL()
        let sessionID = UUID()
        let recorder = IndexRecorder()
        let totalSteps = 4

        // ── Phase 1: start a run, let it checkpoint at least one step, then
        // simulate process death by dropping the bootstrap mid-flight. We cap
        // consumption after the first completed step so step 0 is durably
        // checkpointed but the run never reaches a terminal state.
        let runID: UUID
        let completedAtCrash: Int
        do {
            let bootstrap = try makeResumableBootstrap(storeURL: storeURL)
            let store = try XCTUnwrap(bootstrap.runStore, "enableResumableRuns must expose a runStore")
            let run = ConversationRun(
                sessionID: sessionID,
                goal: "Plan the launch",
                maxSteps: totalSteps
            )
            runID = run.id

            let provider = RecordingProvider(totalSteps: totalSteps, recorder: recorder)
            var sawFirstStepCompleted = false
            var loopFinished = false
            for await event in bootstrap.conversationRuntime.startRun(run, using: provider) {
                switch event {
                case .stepCompleted(_, 0, _, _):
                    sawFirstStepCompleted = true
                    // Stop the loop *cleanly* once a step is durably checkpointed.
                    // We must not abandon a still-running loop: it would keep a
                    // second SwiftData ModelContainer live over this same on-disk
                    // store while phase 2 opens a fresh one, and two containers on
                    // one file in one process corrupts CoreData (intermittent
                    // SIGSEGV in sibling suites under the parallel gate). Cancelling
                    // lets the loop terminate and release its container; we then
                    // rewrite the persisted status back to a non-terminal value to
                    // model the real crash state — a process killed mid-run, before
                    // any terminal transition, with its completed prefix intact.
                    await bootstrap.conversationRuntime.cancelActiveRun()
                case .runCancelled, .runCompleted, .runFailed:
                    loopFinished = true
                default:
                    break
                }
                if loopFinished { break }
            }
            XCTAssertTrue(sawFirstStepCompleted, "Run did not checkpoint its first step")
            XCTAssertTrue(loopFinished, "Run loop did not terminate")

            // The completed steps must form a contiguous prefix from 0. Exactly how
            // many completed before the cancel took effect is timing-dependent (the
            // loop may finish the in-flight step first), so we capture the actual
            // count and drive every downstream assertion off it — testing the real
            // durability contract (resume from wherever it checkpointed) rather than
            // a fragile exact count.
            let completedIndices = try await store.fetchSteps(for: runID)
                .filter(\.isCompleted).map(\.stepIndex).sorted()
            XCTAssertGreaterThanOrEqual(completedIndices.count, 1, "Run did not durably checkpoint a step")
            XCTAssertLessThan(completedIndices.count, totalSteps, "Run finished before it could be resumed")
            XCTAssertEqual(completedIndices, Array(0..<completedIndices.count),
                           "Completed steps must form a contiguous prefix from 0")
            completedAtCrash = completedIndices.count

            // Restore the non-terminal state a kill would have left (the cancel was
            // only our in-test mechanism for stopping the loop deterministically).
            let fetchedMidRun = try await store.fetchRun(runID)
            var midRun = try XCTUnwrap(fetchedMidRun)
            midRun.status = .running
            try await store.updateRun(midRun)
        }

        let indicesBeforeResume = await recorder.snapshot()

        // ── Phase 2: a brand-new bootstrap (fresh container + SwiftDataRunStore)
        // over the SAME on-disk file resumes the run from its checkpoint.
        let resumeBootstrap = try makeResumableBootstrap(storeURL: storeURL)
        let resumeRuntime = resumeBootstrap.conversationRuntime
        let resumeStore = try XCTUnwrap(resumeBootstrap.runStore)
        let provider = RecordingProvider(totalSteps: totalSteps, recorder: recorder)

        var resumedAtStepCount: Int?
        var firstStepStartedIndex: Int?
        var finalStepCount: Int?
        for await event in resumeRuntime.resumeRun(runID, using: provider) {
            switch event {
            case let .runResumed(_, stepCount):
                if resumedAtStepCount == nil { resumedAtStepCount = stepCount }
            case let .stepStarted(_, idx, _):
                if firstStepStartedIndex == nil { firstStepStartedIndex = idx }
            case let .runCompleted(_, stepCount):
                finalStepCount = stepCount
            default:
                break
            }
        }

        // Resume started from the persisted checkpoint (the completed-step count).
        XCTAssertEqual(resumedAtStepCount, completedAtCrash, "Resume did not start from the persisted checkpoint")
        // The first step re-driven on resume is the first incomplete index — the
        // already-completed prefix was NOT re-run.
        XCTAssertEqual(firstStepStartedIndex, completedAtCrash, "Resume re-ran an already-completed step")
        // The run reached completion with the full step count.
        XCTAssertEqual(finalStepCount, totalSteps)

        // The provider was asked only for the not-yet-completed indices on
        // resume — completed step 0 was never re-driven.
        let indicesAfterResume = await recorder.snapshot()
        let resumeOnlyIndices = Array(indicesAfterResume.dropFirst(indicesBeforeResume.count))
        XCTAssertFalse(resumeOnlyIndices.contains(where: { $0 < completedAtCrash }),
                       "Resume re-drove an already-completed step")
        XCTAssertEqual(resumeOnlyIndices.min(), completedAtCrash, "Resume should begin at the first incomplete index")

        // The durable record is terminal-completed with the expected step count.
        let finalFetched = try await resumeStore.fetchRun(runID)
        let finalRun = try XCTUnwrap(finalFetched)
        XCTAssertEqual(finalRun.status, .completed)
        XCTAssertEqual(finalRun.stepCount, totalSteps)

        // All steps are durably completed exactly once each.
        let finalSteps = try await resumeStore.fetchSteps(for: runID)
        let completedIndices = finalSteps.filter(\.isCompleted).map(\.stepIndex).sorted()
        XCTAssertEqual(completedIndices, Array(0..<totalSteps))
    }

    // MARK: - Backward compatibility

    func test_runtimeWithoutRunStore_hasNoResumableSurface() async throws {
        // A runtime built WITHOUT a runStore uses SingleTurnDriver: the run API
        // is inert (logs + finishes immediately), proving the opt-in is the only
        // path to resumable behaviour and existing callers are unaffected.
        let harness = try InMemoryPersistenceHarness.make()
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["ok"]
        let service = InferenceService(backend: backend, name: "NoRunStore")

        let runtime = ConversationRuntime(
            messageStore: harness.provider,
            sessionStore: harness.provider,
            inferenceService: service
            // no runStore → SingleTurnDriver
        )

        // startRun on a non-resumable runtime yields no events and finishes.
        let run = ConversationRun(sessionID: UUID(), goal: "noop", maxSteps: 2)
        var eventCount = 0
        for await _ in runtime.startRun(run) { eventCount += 1 }
        XCTAssertEqual(eventCount, 0, "Non-resumable runtime must not drive a run")

        // But ordinary single-turn behaviour still works.
        let handle = try await runtime.processTurnWithOutcome(
            TurnInput(sessionID: UUID(), kind: .send(text: "Hello"))
        )
        _ = await handle?.outcome
    }
}
