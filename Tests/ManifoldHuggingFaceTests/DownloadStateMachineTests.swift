import XCTest
@testable import ManifoldHuggingFace
@testable import ManifoldInference

/// Unit tests for `DownloadStateMachine.reconcileSnapshotTasks` — the fix for
/// finding 27 (2026-07 inert-code audit): sibling-task cancellation on a failed
/// multi-file snapshot download only worked for downloads started fresh in the
/// current process. `restoreSnapshotDownload(modelID:model:files:stagingDirectory:)`
/// (the relaunch path, driven by `BackgroundDownloadManager.restorePendingDownloads`)
/// has no live `URLSessionTask` objects to register, so `failSnapshotDownload`'s
/// sibling-cancellation found an empty `taskIDs` set for any snapshot resumed
/// across a relaunch — a single file failure never cancelled the still-downloading
/// siblings. `reconcileSnapshotTasks` closes that gap by decoding each live
/// task's persisted `taskDescription` back into its owning `modelID`.
final class DownloadStateMachineTests: XCTestCase {

    // MARK: - Helpers

    private func makeSnapshotFiles() -> [SnapshotFileMetadata] {
        [
            SnapshotFileMetadata(relativePath: "config.json", sizeBytes: 100, expectedChecksum: nil),
            SnapshotFileMetadata(relativePath: "weights/model.safetensors", sizeBytes: 900, expectedChecksum: nil),
        ]
    }

    private func makeModel(repoID: String, fileName: String) -> DownloadableModel {
        DownloadableModel(
            repoID: repoID,
            fileName: fileName,
            displayName: fileName,
            modelType: .mlx,
            sizeBytes: 1_000
        )
    }

    /// Encodes a `TaskContext` the same way `startSnapshotDownload` does when it
    /// sets `URLSessionDownloadTask.taskDescription` at creation time — the value
    /// this test stands in for the OS preserving across a relaunch.
    private func encodedDescription(
        machine: DownloadStateMachine,
        modelID: String,
        relativePath: String
    ) -> String {
        machine.encodeTaskDescription(
            DownloadStateMachine.TaskContext(
                modelID: modelID,
                relativePath: relativePath,
                expectedBytes: 100,
                expectedChecksum: nil
            )
        )
    }

    // MARK: - reconcileSnapshotTasks

    func test_reconcileSnapshotTasks_registersTaskIDs_forSnapshotRestoredAfterRelaunch() {
        var machine = DownloadStateMachine()
        let model = makeModel(repoID: "mlx-community/Test-4bit", fileName: "Test-4bit")

        // Simulate the relaunch path: restoreSnapshotDownload has metadata but no
        // task IDs — mirrors BackgroundDownloadManager.restorePendingDownloads().
        machine.restoreSnapshotDownload(
            modelID: model.id,
            model: model,
            files: makeSnapshotFiles(),
            stagingDirectory: URL(fileURLWithPath: "/tmp/staging-a")
        )
        XCTAssertTrue(
            machine.snapshotTaskIDs(modelID: model.id).isEmpty,
            "A snapshot restored from persisted metadata alone must start with no registered tasks"
        )

        // Simulate getAllTasks returning the two still-live download tasks, each
        // carrying the taskDescription the OS persisted from before the relaunch.
        let liveTasks: [(taskID: Int, taskDescription: String?)] = [
            (taskID: 10, taskDescription: encodedDescription(machine: machine, modelID: model.id, relativePath: "config.json")),
            (taskID: 11, taskDescription: encodedDescription(machine: machine, modelID: model.id, relativePath: "weights/model.safetensors")),
        ]

        machine.reconcileSnapshotTasks(liveTasks: liveTasks)

        XCTAssertEqual(
            machine.snapshotTaskIDs(modelID: model.id), [10, 11],
            "reconcileSnapshotTasks should register every live task whose decoded modelID matches the restored snapshot"
        )
        // Sabotage-evidence: deleting the `reconcileSnapshotTasks` call in
        // `BackgroundDownloadManager.restoreSnapshotTaskRegistrations()` (or
        // stubbing this method to a no-op) leaves `snapshotTaskIDs` empty here,
        // reproducing finding 27 exactly — a sibling failure after relaunch
        // would then cancel nothing.
    }

    func test_reconcileSnapshotTasks_ignoresTasksWithUnrelatedDescription() {
        var machine = DownloadStateMachine()
        let model = makeModel(repoID: "mlx-community/Test-4bit", fileName: "Test-4bit")
        machine.restoreSnapshotDownload(
            modelID: model.id,
            model: model,
            files: makeSnapshotFiles(),
            stagingDirectory: URL(fileURLWithPath: "/tmp/staging-b")
        )

        // A bare non-JSON description decodes (via taskContext(for:taskDescription:))
        // to a synthetic TaskContext whose modelID is the raw string itself — it
        // won't match any registered snapshot, so it must be dropped rather than
        // creating a bogus registration.
        machine.reconcileSnapshotTasks(liveTasks: [(taskID: 99, taskDescription: "unrelated-task-id")])

        XCTAssertTrue(machine.snapshotTaskIDs(modelID: model.id).isEmpty)
        XCTAssertTrue(machine.snapshotTaskIDs(modelID: "unrelated-task-id").isEmpty)
    }

    func test_reconcileSnapshotTasks_groupsMultipleModelsIndependently() {
        var machine = DownloadStateMachine()
        let modelA = makeModel(repoID: "mlx-community/A", fileName: "A")
        let modelB = makeModel(repoID: "mlx-community/B", fileName: "B")

        machine.restoreSnapshotDownload(
            modelID: modelA.id, model: modelA, files: makeSnapshotFiles(),
            stagingDirectory: URL(fileURLWithPath: "/tmp/staging-a2")
        )
        machine.restoreSnapshotDownload(
            modelID: modelB.id, model: modelB, files: makeSnapshotFiles(),
            stagingDirectory: URL(fileURLWithPath: "/tmp/staging-b2")
        )

        let liveTasks: [(taskID: Int, taskDescription: String?)] = [
            (taskID: 1, taskDescription: encodedDescription(machine: machine, modelID: modelA.id, relativePath: "config.json")),
            (taskID: 2, taskDescription: encodedDescription(machine: machine, modelID: modelB.id, relativePath: "config.json")),
        ]
        machine.reconcileSnapshotTasks(liveTasks: liveTasks)

        XCTAssertEqual(machine.snapshotTaskIDs(modelID: modelA.id), [1])
        XCTAssertEqual(machine.snapshotTaskIDs(modelID: modelB.id), [2])
    }

    // MARK: - snapshotTaskIDsToCancel (self-sufficient sibling cancel)

    /// Review round 1, blocking finding: the eager reconciliation lands two async
    /// hops after `reconnectBackgroundSession()`, but a sibling that failed while
    /// the app was suspended has its `didCompleteWithError` delivered the instant
    /// the delegate re-attaches — possibly BEFORE reconciliation writes any task
    /// IDs. This simulates exactly that ordering: metadata restored, reconciliation
    /// NOT yet run (registered set empty — what `snapshotTaskIDs` returns in that
    /// window), failure callback computing the cancel set. The decode-based path
    /// must still identify both siblings.
    func test_snapshotTaskIDsToCancel_failureBeforeReconciliation_stillFindsSiblings() {
        var machine = DownloadStateMachine()
        let model = makeModel(repoID: "mlx-community/Race", fileName: "Race")
        machine.restoreSnapshotDownload(
            modelID: model.id,
            model: model,
            files: makeSnapshotFiles(),
            stagingDirectory: URL(fileURLWithPath: "/tmp/staging-race")
        )
        // Deliberately NO reconcileSnapshotTasks call — the failure raced ahead.
        XCTAssertTrue(
            machine.snapshotTaskIDs(modelID: model.id).isEmpty,
            "Precondition: reconciliation has not run, registered set is empty"
        )

        let liveSiblings: [(taskID: Int, taskDescription: String?)] = [
            (taskID: 20, taskDescription: encodedDescription(machine: machine, modelID: model.id, relativePath: "config.json")),
            (taskID: 21, taskDescription: encodedDescription(machine: machine, modelID: model.id, relativePath: "weights/model.safetensors")),
        ]

        let toCancel = machine.snapshotTaskIDsToCancel(
            modelID: model.id,
            registeredTaskIDs: machine.snapshotTaskIDs(modelID: model.id),
            liveTasks: liveSiblings
        )

        XCTAssertEqual(
            toCancel, [20, 21],
            "The cancel path must be self-sufficient: siblings are identified by decoding their persisted taskDescription, not by trusting the (possibly still-empty) registered set"
        )
        // Sabotage-evidence: making snapshotTaskIDsToCancel return only
        // `registeredTaskIDs` (dropping the decode loop) returns [] here — the
        // failure-raced-reconciliation window where sibling-cancel silently
        // no-ops, i.e. finding 27 reintroduced one async hop later.
    }

    func test_snapshotTaskIDsToCancel_excludesOtherModelsTasks_andUnionsRegisteredIDs() {
        var machine = DownloadStateMachine()
        let target = makeModel(repoID: "mlx-community/Target", fileName: "Target")
        let other = makeModel(repoID: "mlx-community/Other", fileName: "Other")
        machine.restoreSnapshotDownload(
            modelID: target.id, model: target, files: makeSnapshotFiles(),
            stagingDirectory: URL(fileURLWithPath: "/tmp/staging-target")
        )

        let liveTasks: [(taskID: Int, taskDescription: String?)] = [
            (taskID: 30, taskDescription: encodedDescription(machine: machine, modelID: target.id, relativePath: "config.json")),
            (taskID: 31, taskDescription: encodedDescription(machine: machine, modelID: other.id, relativePath: "config.json")),
            (taskID: 32, taskDescription: nil),
        ]

        // A registered ID with no decodable live description must survive via the union.
        let toCancel = machine.snapshotTaskIDsToCancel(
            modelID: target.id,
            registeredTaskIDs: [99],
            liveTasks: liveTasks
        )

        XCTAssertEqual(
            toCancel, [30, 99],
            "Only the target model's decoded tasks plus the pre-captured registered IDs should be cancelled — never another model's tasks"
        )
    }

    /// Confirms the fresh-start path (`startSnapshotDownload` calling
    /// `registerSnapshotTasks` directly) still behaves as before — this fix only
    /// adds a second call site (`reconcileSnapshotTasks`) for the relaunch path.
    func test_registerSnapshotTasks_stillWorksForFreshStartPath() {
        var machine = DownloadStateMachine()
        let model = makeModel(repoID: "mlx-community/Fresh", fileName: "Fresh")
        machine.prepareSnapshotDownload(
            model: model,
            files: [
                ModelDownloadFile(
                    relativePath: "config.json",
                    url: URL(string: "https://example.com/config.json")!,
                    sizeBytes: 100
                ),
            ],
            stagingDirectory: URL(fileURLWithPath: "/tmp/staging-fresh")
        )

        machine.registerSnapshotTasks(modelID: model.id, taskIDs: [5, 6])

        XCTAssertEqual(machine.snapshotTaskIDs(modelID: model.id), [5, 6])
    }
}
