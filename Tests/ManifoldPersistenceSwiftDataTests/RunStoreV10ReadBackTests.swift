// Read-back integration test for the V9→V10 RunStore schema migration (#1795 /
// P3b #1784). SwiftDataRunStore shipped its resumable-run tables (ConversationRun /
// RunStep) without a read-back test exercising a *partially-completed* run — a run
// that was interrupted mid-step. Schema corruption (a dropped table, a renamed
// column, a botched migration stage) would silently break run resumption for anyone
// who started a run under v0.48 and upgraded.
//
// This mirrors SchemaMigrationReadBackTests' pattern: seed a fixture under the older
// schema (here, a V9 store), re-open it through the full ModelContainerFactory
// migration plan (which runs the lightweight V9→V10 stage), then write a
// dangling/incomplete run through SwiftDataRunStore and re-read it from a fresh store
// instance over the same on-disk container. We assert the run status, step ordering,
// and the incomplete-final-step flag all round-trip cleanly.
//
// In-memory / on-disk SwiftData throughout — the persistence layer is never mocked
// (CLAUDE.md rule). The on-disk file is required to prove the data survives a fresh
// container, not just an in-process context.

import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldRuntime

@MainActor
final class RunStoreV10ReadBackTests: XCTestCase {

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

    /// Seeds a V9 store with a legacy session, migrates it to V10 through the
    /// real `ModelContainerFactory`, writes a *partially-completed* run (two
    /// completed steps followed by a dangling, never-completed final step), then
    /// re-opens the same on-disk file with a brand-new container + store and
    /// asserts the whole shape round-trips:
    ///   - run status preserved (`.running` — the run was interrupted, not done),
    ///   - steps returned in ascending `stepIndex` order,
    ///   - the two leading steps marked completed,
    ///   - the dangling final step preserved as *incomplete* (the resumption point).
    ///
    /// Sabotage-evidence: if the V9→V10 stage were dropped, `makeContainer`
    /// halts with a schema-mismatch before any assert; if the final step's
    /// `isCompleted` flag were clobbered to `true` during round-trip, the
    /// incomplete-final-step assertion fails and resumable runs would silently
    /// skip the interrupted step.
    func test_v9StoreMigratesToV10_andPartialRunRoundTripsAcrossFreshStore() async throws {
        let storeDirectory = try makeStoreDirectory(named: "RunStoreV10ReadBack")
        let storeURL = storeDirectory.appendingPathComponent("Manifold.sqlite")

        let legacySessionID: UUID

        // --- Step 1: seed a V9 store (the v0.48-era on-disk shape) ---
        do {
            let v9Container = try ModelContainer(
                for: Schema(versionedSchema: ManifoldSchemaV9.self),
                configurations: [ModelConfiguration(url: storeURL)]
            )
            let ctx = ModelContext(v9Container)
            let session = ManifoldSchemaV9.ChatSession(title: "Pre-V10 run session")
            session.systemPrompt = "resume me"
            ctx.insert(session)
            legacySessionID = session.id
            try ctx.save()
            // Container released here — WAL lock freed before the V10 re-open.
        }

        // --- Step 2: migrate V9 -> V10 via the real factory, write a partial run ---
        let runID: UUID
        let completedStepIDs: [UUID]
        let danglingStepID: UUID
        do {
            let migratedContainer = try ModelContainerFactory.makeContainer(
                configurations: [ModelConfiguration(url: storeURL)]
            )
            let store = SwiftDataRunStore(modelContext: ModelContext(migratedContainer))

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            // `.running` — the run is interrupted mid-flight, not completed.
            let run = ConversationRun(
                id: UUID(),
                sessionID: legacySessionID,
                goal: "Draft, review, and ship the post",
                status: .running,
                stepCount: 2,
                maxSteps: 8,
                createdAt: now,
                updatedAt: now
            )
            try await store.insertRun(run)
            runID = run.id

            // Two completed steps...
            var ids: [UUID] = []
            for index in 0..<2 {
                let step = RunStep(
                    id: UUID(),
                    runID: run.id,
                    stepIndex: index,
                    turnInput: nil,
                    messageID: UUID(),
                    isCompleted: true,
                    isFailed: false,
                    failureReason: nil,
                    createdAt: now,
                    updatedAt: now
                )
                try await store.insertStep(step)
                ids.append(step.id)
            }
            completedStepIDs = ids

            // ...followed by a dangling, never-completed final step — the
            // resumption point. No messageID, isCompleted == false.
            let dangling = RunStep(
                id: UUID(),
                runID: run.id,
                stepIndex: 2,
                turnInput: nil,
                messageID: nil,
                isCompleted: false,
                isFailed: false,
                failureReason: nil,
                createdAt: now,
                updatedAt: now
            )
            try await store.insertStep(dangling)
            danglingStepID = dangling.id
            // Container released — forces the read-back below to go through a
            // genuinely fresh container over the same file.
        }

        // --- Step 3: re-open with a FRESH container + store, assert round-trip ---
        let reopenedContainer = try ModelContainerFactory.makeContainer(
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let reopenedStore = SwiftDataRunStore(modelContext: ModelContext(reopenedContainer))

        let reopenedRun = try await reopenedStore.fetchRun(runID)
        let run = try XCTUnwrap(reopenedRun, "Partial run vanished across the V10 migration + fresh store")
        XCTAssertEqual(run.status, .running, "Interrupted run must stay .running after round-trip")
        XCTAssertEqual(run.sessionID, legacySessionID, "Run must remain bound to its (migrated) session")
        XCTAssertEqual(run.stepCount, 2)
        XCTAssertEqual(run.maxSteps, 8)

        let steps = try await reopenedStore.fetchSteps(for: runID)
        XCTAssertEqual(steps.map(\.stepIndex), [0, 1, 2], "Steps must round-trip in ascending stepIndex order")
        XCTAssertEqual(steps.map(\.id), completedStepIDs + [danglingStepID], "Step identities must round-trip")

        // Leading steps completed; final step preserved as the incomplete
        // resumption point — the whole point of the fixture.
        XCTAssertTrue(steps[0].isCompleted)
        XCTAssertTrue(steps[1].isCompleted)
        XCTAssertNotNil(steps[0].messageID)
        XCTAssertNotNil(steps[1].messageID)

        let finalStep = steps[2]
        XCTAssertEqual(finalStep.id, danglingStepID)
        XCTAssertFalse(finalStep.isCompleted, "Dangling final step must round-trip as incomplete (resumption point)")
        XCTAssertFalse(finalStep.isFailed, "Dangling final step is incomplete, not failed")
        XCTAssertNil(finalStep.messageID, "Incomplete final step produced no assistant message")
        XCTAssertNil(finalStep.failureReason)
    }
}
