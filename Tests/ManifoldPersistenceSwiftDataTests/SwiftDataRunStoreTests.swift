import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldRuntime
import ManifoldTestSupport

/// Integration tests for ``SwiftDataRunStore`` (P3b #1784) and the V9→V10
/// additive schema migration. In-memory SwiftData throughout — the
/// persistence layer is never mocked.
@MainActor
final class SwiftDataRunStoreTests: XCTestCase {

    private var tempStoreDirectory: URL?

    override func tearDown() async throws {
        if let tempStoreDirectory {
            try? FileManager.default.removeItem(at: tempStoreDirectory)
        }
        tempStoreDirectory = nil
        try await super.tearDown()
    }

    private func makeStoreDirectory(named prefix: String) throws -> URL {
        let storeDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        tempStoreDirectory = storeDirectory
        return storeDirectory
    }

    private func makeRun(
        sessionID: UUID = UUID(),
        status: RunStatus = .running,
        stepCount: Int = 0,
        maxSteps: Int? = 8
    ) -> ConversationRun {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return ConversationRun(
            id: UUID(),
            sessionID: sessionID,
            goal: "Plan the launch",
            status: status,
            stepCount: stepCount,
            maxSteps: maxSteps,
            createdAt: now,
            updatedAt: now
        )
    }

    private func makeStep(
        runID: UUID,
        index: Int,
        turnInput: TurnInput?,
        isCompleted: Bool = false
    ) -> RunStep {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return RunStep(
            id: UUID(),
            runID: runID,
            stepIndex: index,
            turnInput: turnInput,
            messageID: nil,
            isCompleted: isCompleted,
            isFailed: false,
            failureReason: nil,
            createdAt: now,
            updatedAt: now
        )
    }

    // MARK: - 1. CRUD round-trip

    func test_insertThenFetchRun_roundTripsGuaranteedFields() async throws {
        let container = try makeInMemoryContainer()
        let store = SwiftDataRunStore(modelContext: ModelContext(container))

        let run = makeRun(status: .paused, stepCount: 3, maxSteps: 10)
        try await store.insertRun(run)

        let fetched = try await store.fetchRun(run.id)
        let unwrapped = try XCTUnwrap(fetched)
        XCTAssertEqual(unwrapped.id, run.id)
        XCTAssertEqual(unwrapped.sessionID, run.sessionID)
        XCTAssertEqual(unwrapped.goal, "Plan the launch")
        XCTAssertEqual(unwrapped.status, .paused)
        XCTAssertEqual(unwrapped.stepCount, 3)
        XCTAssertEqual(unwrapped.maxSteps, 10)
        XCTAssertEqual(unwrapped.createdAt, run.createdAt)
    }

    func test_updateRun_persistsStatusAndStepCount() async throws {
        let container = try makeInMemoryContainer()
        let store = SwiftDataRunStore(modelContext: ModelContext(container))

        var run = makeRun(status: .running, stepCount: 0)
        try await store.insertRun(run)

        run.status = .completed
        run.stepCount = 5
        run.updatedAt = Date(timeIntervalSince1970: 1_700_000_500)
        try await store.updateRun(run)

        let fetchedRun = try await store.fetchRun(run.id)
        let fetched = try XCTUnwrap(fetchedRun)
        XCTAssertEqual(fetched.status, .completed)
        XCTAssertEqual(fetched.stepCount, 5)
        XCTAssertEqual(fetched.updatedAt, Date(timeIntervalSince1970: 1_700_000_500))
    }

    func test_updateRun_unknownID_throwsRunNotFound() async throws {
        let container = try makeInMemoryContainer()
        let store = SwiftDataRunStore(modelContext: ModelContext(container))
        let phantom = makeRun()
        do {
            try await store.updateRun(phantom)
            XCTFail("Expected runNotFound for an un-inserted run")
        } catch let error as RunStoreError {
            XCTAssertEqual(error, .runNotFound(phantom.id))
        }
    }

    func test_deleteRun_removesRunAndItsSteps() async throws {
        let container = try makeInMemoryContainer()
        let store = SwiftDataRunStore(modelContext: ModelContext(container))

        let run = makeRun()
        try await store.insertRun(run)
        try await store.insertStep(makeStep(runID: run.id, index: 0, turnInput: nil))
        try await store.insertStep(makeStep(runID: run.id, index: 1, turnInput: nil))

        try await store.deleteRun(run.id)

        let deletedRun = try await store.fetchRun(run.id)
        XCTAssertNil(deletedRun)
        let steps = try await store.fetchSteps(for: run.id)
        XCTAssertTrue(steps.isEmpty, "Deleting a run must not strand its step rows")
    }

    func test_deleteRun_unknownID_throwsRunNotFound() async throws {
        let container = try makeInMemoryContainer()
        let store = SwiftDataRunStore(modelContext: ModelContext(container))
        let id = UUID()
        do {
            try await store.deleteRun(id)
            XCTFail("Expected runNotFound")
        } catch let error as RunStoreError {
            XCTAssertEqual(error, .runNotFound(id))
        }
    }

    func test_updateStep_persistsCompletionAndFailureFields() async throws {
        let container = try makeInMemoryContainer()
        let store = SwiftDataRunStore(modelContext: ModelContext(container))

        let run = makeRun()
        try await store.insertRun(run)
        var step = makeStep(runID: run.id, index: 0, turnInput: nil)
        try await store.insertStep(step)

        let producedMessage = UUID()
        step.isCompleted = true
        step.messageID = producedMessage
        try await store.updateStep(step)

        let fetched = try await store.fetchSteps(for: run.id)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertTrue(fetched[0].isCompleted)
        XCTAssertEqual(fetched[0].messageID, producedMessage)
    }

    func test_updateStep_unknownID_throwsStepNotFound() async throws {
        let container = try makeInMemoryContainer()
        let store = SwiftDataRunStore(modelContext: ModelContext(container))
        let step = makeStep(runID: UUID(), index: 0, turnInput: nil)
        do {
            try await store.updateStep(step)
            XCTFail("Expected stepNotFound")
        } catch let error as RunStoreError {
            XCTAssertEqual(error, .stepNotFound(step.id))
        }
    }

    // MARK: - 2. fetch-by-runID + ordering

    func test_fetchSteps_returnedOrderedByStepIndexAscending() async throws {
        let container = try makeInMemoryContainer()
        let store = SwiftDataRunStore(modelContext: ModelContext(container))

        let run = makeRun()
        try await store.insertRun(run)
        // Insert out of order to prove the sort, not insertion order.
        for index in [2, 0, 3, 1] {
            try await store.insertStep(makeStep(runID: run.id, index: index, turnInput: nil))
        }

        let steps = try await store.fetchSteps(for: run.id)
        XCTAssertEqual(steps.map(\.stepIndex), [0, 1, 2, 3])
    }

    func test_fetchSteps_isScopedToRunID() async throws {
        let container = try makeInMemoryContainer()
        let store = SwiftDataRunStore(modelContext: ModelContext(container))

        let runA = makeRun()
        let runB = makeRun()
        try await store.insertRun(runA)
        try await store.insertRun(runB)
        try await store.insertStep(makeStep(runID: runA.id, index: 0, turnInput: nil))
        try await store.insertStep(makeStep(runID: runB.id, index: 0, turnInput: nil))
        try await store.insertStep(makeStep(runID: runB.id, index: 1, turnInput: nil))

        let stepsA = try await store.fetchSteps(for: runA.id)
        let stepsB = try await store.fetchSteps(for: runB.id)
        XCTAssertEqual(stepsA.count, 1)
        XCTAssertEqual(stepsB.count, 2)
    }

    func test_fetchRuns_forSession_orderedMostRecentFirst() async throws {
        let container = try makeInMemoryContainer()
        let store = SwiftDataRunStore(modelContext: ModelContext(container))

        let session = UUID()
        let older = ConversationRun(
            id: UUID(), sessionID: session, goal: "older", status: .completed,
            stepCount: 0, maxSteps: nil,
            createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = ConversationRun(
            id: UUID(), sessionID: session, goal: "newer", status: .running,
            stepCount: 0, maxSteps: nil,
            createdAt: Date(timeIntervalSince1970: 2_000), updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        // Different session — must be excluded.
        let otherSession = makeRun(sessionID: UUID())

        try await store.insertRun(older)
        try await store.insertRun(newer)
        try await store.insertRun(otherSession)

        let runs = try await store.fetchRuns(for: session)
        XCTAssertEqual(runs.map(\.goal), ["newer", "older"])
    }

    // MARK: - TurnInput lossless round-trip (Codable synthesized cleanly)

    func test_turnInput_roundTripsLosslessly() async throws {
        let container = try makeInMemoryContainer()
        let store = SwiftDataRunStore(modelContext: ModelContext(container))

        let run = makeRun()
        try await store.insertRun(run)

        let sessionID = UUID()
        let config = TurnConfig(systemPrompt: "be terse", temperature: 0.3, maxOutputTokens: 512)
        let input = TurnInput(
            sessionID: sessionID,
            kind: .send(text: "hello"),
            config: config
        )
        try await store.insertStep(makeStep(runID: run.id, index: 0, turnInput: input))

        let steps = try await store.fetchSteps(for: run.id)
        let roundTripped = try XCTUnwrap(steps.first.flatMap(\.turnInput))
        XCTAssertEqual(roundTripped.sessionID, sessionID)
        XCTAssertEqual(roundTripped.config, config)
        guard case .send(let text, _) = roundTripped.kind else {
            return XCTFail("Expected .send kind, got \(roundTripped.kind)")
        }
        XCTAssertEqual(text, "hello")
    }

    func test_nilTurnInput_staysNil() async throws {
        let container = try makeInMemoryContainer()
        let store = SwiftDataRunStore(modelContext: ModelContext(container))
        let run = makeRun()
        try await store.insertRun(run)
        try await store.insertStep(makeStep(runID: run.id, index: 0, turnInput: nil))
        let steps = try await store.fetchSteps(for: run.id)
        XCTAssertNil(steps.first?.turnInput)
    }

    // MARK: - 3. Survives a fresh store instance over the same on-disk container

    func test_runsAndSteps_surviveFreshStoreInstance() async throws {
        let storeDirectory = try makeStoreDirectory(named: "RunStoreDurability")
        let storeURL = storeDirectory.appendingPathComponent("Manifold.sqlite")

        let runID: UUID
        let sessionID = UUID()

        do {
            let container = try ModelContainerFactory.makeContainer(
                configurations: [ModelConfiguration(url: storeURL)]
            )
            let store = SwiftDataRunStore(modelContext: ModelContext(container))
            let run = makeRun(sessionID: sessionID, status: .paused, stepCount: 2)
            try await store.insertRun(run)
            try await store.insertStep(makeStep(runID: run.id, index: 0, turnInput: nil, isCompleted: true))
            try await store.insertStep(makeStep(runID: run.id, index: 1, turnInput: nil))
            runID = run.id
        }

        // Brand-new container + store over the SAME on-disk file.
        let reopenedContainer = try ModelContainerFactory.makeContainer(
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let reopenedStore = SwiftDataRunStore(modelContext: ModelContext(reopenedContainer))

        let reopenedRun = try await reopenedStore.fetchRun(runID)
        let fetchedRun = try XCTUnwrap(reopenedRun)
        XCTAssertEqual(fetchedRun.status, .paused)
        XCTAssertEqual(fetchedRun.stepCount, 2)
        XCTAssertEqual(fetchedRun.sessionID, sessionID)

        let steps = try await reopenedStore.fetchSteps(for: runID)
        XCTAssertEqual(steps.map(\.stepIndex), [0, 1])
        XCTAssertTrue(steps[0].isCompleted)
        XCTAssertFalse(steps[1].isCompleted)
    }

    // MARK: - 4. V9 -> V10 migration (additive: two new run tables)

    /// Boots a store at V9, writes a session, then re-opens it through the full
    /// migration plan (which now runs the V9→V10 lightweight stage). The
    /// pre-existing V9 row must survive, and the two new V10 tables must be
    /// usable through ``SwiftDataRunStore`` against the migrated container.
    ///
    /// Sabotage-evidence: dropping the V9→V10 stage from
    /// ``ManifoldMigrationPlan/stages`` halts `makeContainer` with a
    /// schema-mismatch error before the asserts run; removing
    /// `ConversationRunModel` / `RunStepModel` from `ManifoldSchemaV10.models`
    /// makes the run-store fetch throw on the unknown entity.
    func test_migrationPlan_v9StoreMigratesToV10WithUsableRunTables() async throws {
        let storeDirectory = try makeStoreDirectory(named: "ManifoldSchemaV9ToV10")
        let storeURL = storeDirectory.appendingPathComponent("Manifold.sqlite")
        let sessionID: UUID

        do {
            let config = ModelConfiguration(url: storeURL)
            let container = try ModelContainer(
                for: Schema(versionedSchema: ManifoldSchemaV9.self),
                configurations: [config]
            )
            let context = ModelContext(container)
            let session = ManifoldSchemaV9.ChatSession(title: "Legacy V9 session")
            session.systemPrompt = "carry forward"
            context.insert(session)
            try context.save()
            sessionID = session.id
        }

        let migratedContainer = try ModelContainerFactory.makeContainer(
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let migratedContext = ModelContext(migratedContainer)

        // Pre-existing V9 data survived the additive migration.
        let sessions = try migratedContext.fetch(FetchDescriptor<ManifoldSchemaV9.ChatSession>(
            predicate: #Predicate { $0.id == sessionID }
        ))
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.title, "Legacy V9 session")
        XCTAssertEqual(sessions.first?.systemPrompt, "carry forward")

        // The new V10 tables are usable on the migrated store.
        let store = SwiftDataRunStore(modelContext: migratedContext)
        let run = makeRun(sessionID: sessionID, status: .running)
        try await store.insertRun(run)
        try await store.insertStep(makeStep(runID: run.id, index: 0, turnInput: nil))

        let migratedRun = try await store.fetchRun(run.id)
        let fetchedRun = try XCTUnwrap(migratedRun)
        XCTAssertEqual(fetchedRun.status, .running)
        let migratedSteps = try await store.fetchSteps(for: run.id)
        XCTAssertEqual(migratedSteps.count, 1)
    }

    func test_schemaV10_versionIdentifierAndModelCount() {
        XCTAssertEqual(ManifoldSchemaV10.versionIdentifier, Schema.Version(10, 0, 0))
        // V9's 8 models carried forward + 2 new run tables.
        XCTAssertEqual(ManifoldSchemaV10.models.count, 10)
    }
}
