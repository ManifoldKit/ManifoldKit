import XCTest
@testable import ManifoldRuntime
import ManifoldInference

/// Locks the ``RunStore`` protocol contract via an in-memory reference
/// implementation. The SwiftData-backed implementation will be exercised
/// in a future P3b persistence sub-phase; this file defends the documented
/// surface independently of any backing store.
///
/// Classification: Unit (no SwiftData, no backend, no network).
@MainActor
final class RunStoreContractTests: XCTestCase {

    // MARK: - In-memory reference implementation

    private final class InMemoryRunStore: RunStore {
        private var runs: [ConversationRun] = []
        private var steps: [RunStep] = []

        func insertRun(_ run: ConversationRun) async throws {
            runs.append(run)
        }

        func updateRun(_ run: ConversationRun) async throws {
            guard let idx = runs.firstIndex(where: { $0.id == run.id }) else {
                throw RunStoreError.runNotFound(run.id)
            }
            runs[idx] = run
        }

        func deleteRun(_ id: UUID) async throws {
            guard let idx = runs.firstIndex(where: { $0.id == id }) else {
                throw RunStoreError.runNotFound(id)
            }
            runs.remove(at: idx)
        }

        func fetchRuns(for sessionID: UUID) async throws -> [ConversationRun] {
            runs.filter { $0.sessionID == sessionID }
                .sorted { $0.createdAt > $1.createdAt }
        }

        func fetchRun(_ id: UUID) async throws -> ConversationRun? {
            runs.first(where: { $0.id == id })
        }

        func insertStep(_ step: RunStep) async throws {
            steps.append(step)
        }

        func updateStep(_ step: RunStep) async throws {
            guard let idx = steps.firstIndex(where: { $0.id == step.id }) else {
                throw RunStoreError.stepNotFound(step.id)
            }
            steps[idx] = step
        }

        func fetchSteps(for runID: UUID) async throws -> [RunStep] {
            steps.filter { $0.runID == runID }
                .sorted { $0.stepIndex < $1.stepIndex }
        }
    }

    // MARK: - ConversationRun CRUD

    func test_insertRun_fetchRun_roundtrip() async throws {
        let store = InMemoryRunStore()
        let sessionID = UUID()
        let run = ConversationRun(sessionID: sessionID, goal: "Test goal")
        try await store.insertRun(run)

        let fetched = try await store.fetchRun(run.id)
        let unwrapped = try XCTUnwrap(fetched, "Expected inserted run to be fetchable")
        XCTAssertEqual(unwrapped.id, run.id)
        XCTAssertEqual(unwrapped.goal, "Test goal")
        XCTAssertEqual(unwrapped.status, .pending)
    }

    func test_fetchRuns_emptyStore_returnsEmpty() async throws {
        let store = InMemoryRunStore()
        let result = try await store.fetchRuns(for: UUID())
        XCTAssertTrue(result.isEmpty)
    }

    func test_fetchRuns_filtersBySessionID() async throws {
        let store = InMemoryRunStore()
        let sessionA = UUID()
        let sessionB = UUID()
        let runA = ConversationRun(sessionID: sessionA, goal: "A")
        let runB = ConversationRun(sessionID: sessionB, goal: "B")
        try await store.insertRun(runA)
        try await store.insertRun(runB)

        let resultsA = try await store.fetchRuns(for: sessionA)
        XCTAssertEqual(resultsA.map(\.id), [runA.id])
        let resultsB = try await store.fetchRuns(for: sessionB)
        XCTAssertEqual(resultsB.map(\.id), [runB.id])
    }

    func test_updateRun_persistsStatusChange() async throws {
        let store = InMemoryRunStore()
        var run = ConversationRun(sessionID: UUID(), goal: "Update me")
        try await store.insertRun(run)

        run.status = .running
        run.updatedAt = Date()
        try await store.updateRun(run)

        let fetched = try await store.fetchRun(run.id)
        let unwrappedFetched = try XCTUnwrap(fetched)
        XCTAssertEqual(unwrappedFetched.status, .running)
    }

    func test_updateRun_unknownID_throwsRunNotFound() async throws {
        let store = InMemoryRunStore()
        let run = ConversationRun(sessionID: UUID(), goal: "Ghost")
        do {
            try await store.updateRun(run)
            XCTFail("Expected RunStoreError.runNotFound")
        } catch RunStoreError.runNotFound(let id) {
            XCTAssertEqual(id, run.id)
        } catch {
            XCTFail("Expected RunStoreError.runNotFound, got \(error)")
        }
    }

    func test_deleteRun_removesRun() async throws {
        let store = InMemoryRunStore()
        let run = ConversationRun(sessionID: UUID(), goal: "Delete me")
        try await store.insertRun(run)
        try await store.deleteRun(run.id)

        let fetched = try await store.fetchRun(run.id)
        XCTAssertNil(fetched, "Deleted run must not be fetchable")
    }

    func test_deleteRun_unknownID_throwsRunNotFound() async throws {
        let store = InMemoryRunStore()
        let id = UUID()
        do {
            try await store.deleteRun(id)
            XCTFail("Expected RunStoreError.runNotFound")
        } catch RunStoreError.runNotFound(let missingID) {
            XCTAssertEqual(missingID, id)
        } catch {
            XCTFail("Expected RunStoreError.runNotFound, got \(error)")
        }
    }

    // MARK: - RunStep CRUD

    func test_insertStep_fetchSteps_roundtrip() async throws {
        let store = InMemoryRunStore()
        let runID = UUID()
        let step = RunStep(runID: runID, stepIndex: 0, turnInput: nil)
        try await store.insertStep(step)

        let steps = try await store.fetchSteps(for: runID)
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps.first?.id, step.id)
        XCTAssertEqual(steps.first?.stepIndex, 0)
    }

    func test_fetchSteps_emptyStore_returnsEmpty() async throws {
        let store = InMemoryRunStore()
        let result = try await store.fetchSteps(for: UUID())
        XCTAssertTrue(result.isEmpty)
    }

    func test_fetchSteps_orderedByStepIndex() async throws {
        let store = InMemoryRunStore()
        let runID = UUID()
        let step2 = RunStep(runID: runID, stepIndex: 2, turnInput: nil)
        let step0 = RunStep(runID: runID, stepIndex: 0, turnInput: nil)
        let step1 = RunStep(runID: runID, stepIndex: 1, turnInput: nil)
        try await store.insertStep(step2)
        try await store.insertStep(step0)
        try await store.insertStep(step1)

        let steps = try await store.fetchSteps(for: runID)
        XCTAssertEqual(steps.map(\.stepIndex), [0, 1, 2])
    }

    func test_updateStep_persistsCompletion() async throws {
        let store = InMemoryRunStore()
        let runID = UUID()
        var step = RunStep(runID: runID, stepIndex: 0, turnInput: nil)
        try await store.insertStep(step)

        step.isCompleted = true
        step.messageID = UUID()
        step.updatedAt = Date()
        try await store.updateStep(step)

        let steps = try await store.fetchSteps(for: runID)
        let updated = try XCTUnwrap(steps.first)
        XCTAssertTrue(updated.isCompleted)
        XCTAssertNotNil(updated.messageID)
    }

    func test_updateStep_unknownID_throwsStepNotFound() async throws {
        let store = InMemoryRunStore()
        let step = RunStep(runID: UUID(), stepIndex: 0, turnInput: nil)
        do {
            try await store.updateStep(step)
            XCTFail("Expected RunStoreError.stepNotFound")
        } catch RunStoreError.stepNotFound(let id) {
            XCTAssertEqual(id, step.id)
        } catch {
            XCTFail("Expected RunStoreError.stepNotFound, got \(error)")
        }
    }

    // MARK: - Error description coverage

    func test_runStoreError_runNotFound_description() {
        let id = UUID()
        let error = RunStoreError.runNotFound(id)
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains(id.uuidString))
    }

    func test_runStoreError_stepNotFound_description() {
        let id = UUID()
        let error = RunStoreError.stepNotFound(id)
        let desc = error.errorDescription ?? ""
        XCTAssertTrue(desc.contains(id.uuidString))
    }

    // MARK: - Equatable

    func test_runStoreError_equatable() {
        let id = UUID()
        XCTAssertEqual(RunStoreError.runNotFound(id), RunStoreError.runNotFound(id))
        XCTAssertNotEqual(RunStoreError.runNotFound(id), RunStoreError.runNotFound(UUID()))
        XCTAssertEqual(RunStoreError.stepNotFound(id), RunStoreError.stepNotFound(id))
        XCTAssertNotEqual(RunStoreError.stepNotFound(id), RunStoreError.runNotFound(id))
    }
}
