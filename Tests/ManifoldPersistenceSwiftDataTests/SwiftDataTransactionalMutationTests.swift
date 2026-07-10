import XCTest
@testable import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldRuntime
import ManifoldTestSupport
import ManifoldPersistenceTestSupport

@MainActor
final class SwiftDataTransactionalMutationTests: XCTestCase {

    private var stack: InMemoryPersistenceHarness.Stack!

    override func setUp() async throws {
        try await super.setUp()
        stack = try InMemoryPersistenceHarness.make()
    }

    override func tearDown() async throws {
        stack = nil
        try await super.tearDown()
    }

    private var provider: SwiftDataPersistenceProvider { stack.provider }

    /// Deterministic, strictly-increasing timestamp for ordered inserts.
    ///
    /// `ChatMessage` defaults `timestamp` to `Date()`, so two messages built in
    /// quick succession can land on the same clock tick. `fetchMessages` sorts
    /// by timestamp, so equal stamps order arbitrarily — an ordering flake that
    /// surfaced only under the parallel all-traits run. Tests that assert a
    /// multi-element order stamp each message via `at(_:)` instead of relying on
    /// wall-clock spacing.
    private func at(_ offset: Int) -> Date {
        Date(timeIntervalSince1970: 1_000_000 + Double(offset))
    }

    func test_performMessageMutations_commitsBatchAndFiresHooksAfterCommit() async throws {
        let session = ManifoldInference.ChatSession(title: "Transactional")
        try await provider.insertSession(session)

        var existing = ManifoldInference.ChatMessage(role: .user, content: "before", timestamp: at(0), sessionID: session.id)
        try await provider.insertMessage(existing)
        let inserted = ManifoldInference.ChatMessage(role: .assistant, content: "new", timestamp: at(1), sessionID: session.id)

        let hook = RecordingMessageHook()
        provider.addPostWriteHook(hook)

        existing.content = "after"
        try await provider.performMessageMutations([
            .update(existing),
            .insert(inserted),
        ])

        let messages = try await provider.fetchMessages(for: session.id)
        XCTAssertEqual(messages.map(\.content), ["after", "new"])
        XCTAssertEqual(hook.records.map(\.messageID), [existing.id, inserted.id])
    }

    func test_performMessageMutations_rollsBackStagedUpdateWhenLaterMutationFails() async throws {
        let session = ManifoldInference.ChatSession(title: "Rollback")
        try await provider.insertSession(session)

        var first = ManifoldInference.ChatMessage(role: .user, content: "before", timestamp: at(0), sessionID: session.id)
        let second = ManifoldInference.ChatMessage(role: .assistant, content: "keep", timestamp: at(1), sessionID: session.id)
        try await provider.insertMessage(first)
        try await provider.insertMessage(second)

        let missingID = UUID()
        first.content = "after"

        do {
            try await provider.performMessageMutations([
                .update(first),
                .delete(missingID),
            ])
            XCTFail("Expected batch to fail on missing delete target")
        } catch {
            XCTAssertEqual(error as? ChatPersistenceError, .messageNotFound(missingID))
        }

        let messages = try await provider.fetchMessages(for: session.id)
        XCTAssertEqual(messages.map(\.content), ["before", "keep"])
    }

    func test_performMessageMutations_doesNotFireHooksWhenBatchRollsBack() async throws {
        let session = ManifoldInference.ChatSession(title: "Hook Rollback")
        try await provider.insertSession(session)

        var record = ManifoldInference.ChatMessage(role: .user, content: "before", sessionID: session.id)
        try await provider.insertMessage(record)

        let hook = RecordingMessageHook()
        provider.addPostWriteHook(hook)

        record.content = "after"
        do {
            try await provider.performMessageMutations([
                .update(record),
                .delete(UUID()),
            ])
            XCTFail("Expected batch to fail")
        } catch {
            XCTAssertTrue(error is ChatPersistenceError)
        }

        XCTAssertEqual(hook.records.count, 0)
    }

    // MARK: - Flow-shaped batches
    //
    // These mirror the exact mutation batches the three ConversationTurnExecutor
    // flows now build (compression replace, edit, branch). They prove that on a
    // mid-sequence failure the whole batch rolls back against real SwiftData —
    // the data-loss the sequential paths used to risk.

    /// Compression replace: `deleteMessages(sessionID:)` + N inserts as one
    /// batch. A failure mid-reinsert must leave the original history intact, not
    /// wiped (the old path committed the delete before any insert).
    func test_compressionReplaceBatch_rollsBackPreservingOriginalHistoryOnInsertFailure() async throws {
        let session = ManifoldInference.ChatSession(title: "Compression Rollback")
        try await provider.insertSession(session)

        let original1 = ManifoldInference.ChatMessage(role: .user, content: "q1", timestamp: at(0), sessionID: session.id)
        let original2 = ManifoldInference.ChatMessage(role: .assistant, content: "a1", timestamp: at(1), sessionID: session.id)
        try await provider.insertMessage(original1)
        try await provider.insertMessage(original2)

        // A valid summary insert followed by an update of a record that does not
        // exist (no prior insert in this batch) forces a failure after the
        // delete + first insert have been staged.
        let summary = ManifoldInference.ChatMessage(role: .assistant, content: "summary", sessionID: session.id)
        let phantom = ManifoldInference.ChatMessage(role: .user, content: "never inserted", sessionID: session.id)

        do {
            try await provider.performMessageMutations([
                .deleteMessages(sessionID: session.id),
                .insert(summary),
                .update(phantom),
            ])
            XCTFail("Expected compression replace batch to fail on phantom update")
        } catch {
            XCTAssertEqual(error as? ChatPersistenceError, .messageNotFound(phantom.id))
        }

        let messages = try await provider.fetchMessages(for: session.id)
        XCTAssertEqual(messages.map(\.content), ["q1", "a1"])
    }

    /// Compression replace happy path: delete-all then reinsert commits together.
    func test_compressionReplaceBatch_commitsReplacementAtomically() async throws {
        let session = ManifoldInference.ChatSession(title: "Compression Commit")
        try await provider.insertSession(session)
        try await provider.insertMessage(ManifoldInference.ChatMessage(role: .user, content: "q1", sessionID: session.id))
        try await provider.insertMessage(ManifoldInference.ChatMessage(role: .assistant, content: "a1", sessionID: session.id))

        let summary = ManifoldInference.ChatMessage(role: .assistant, content: "summary", sessionID: session.id)
        try await provider.performMessageMutations([
            .deleteMessages(sessionID: session.id),
            .insert(summary),
        ])

        let messages = try await provider.fetchMessages(for: session.id)
        XCTAssertEqual(messages.map(\.content), ["summary"])
    }

    /// Edit: `update(edited)` + N trailing `delete`s. A trailing-delete failure
    /// must not leave the edit committed with a truncated tail.
    func test_editBatch_rollsBackEditWhenTrailingDeleteFails() async throws {
        let session = ManifoldInference.ChatSession(title: "Edit Rollback")
        try await provider.insertSession(session)

        var edited = ManifoldInference.ChatMessage(role: .user, content: "original", timestamp: at(0), sessionID: session.id)
        let trailing = ManifoldInference.ChatMessage(role: .assistant, content: "reply", timestamp: at(1), sessionID: session.id)
        try await provider.insertMessage(edited)
        try await provider.insertMessage(trailing)

        edited.content = "edited text"
        let missingTrailingID = UUID()

        do {
            try await provider.performMessageMutations([
                .update(edited),
                .delete(trailing.id),
                .delete(missingTrailingID),
            ])
            XCTFail("Expected edit batch to fail on missing trailing delete")
        } catch {
            XCTAssertEqual(error as? ChatPersistenceError, .messageNotFound(missingTrailingID))
        }

        // Edit must NOT be visible and the trailing message must still be there.
        let messages = try await provider.fetchMessages(for: session.id)
        XCTAssertEqual(messages.map(\.content), ["original", "reply"])
    }

    /// Edit happy path: update + trailing deletes commit together.
    func test_editBatch_commitsEditAndTrailingDeletesAtomically() async throws {
        let session = ManifoldInference.ChatSession(title: "Edit Commit")
        try await provider.insertSession(session)

        var edited = ManifoldInference.ChatMessage(role: .user, content: "original", sessionID: session.id)
        let trailing1 = ManifoldInference.ChatMessage(role: .assistant, content: "reply1", sessionID: session.id)
        let trailing2 = ManifoldInference.ChatMessage(role: .user, content: "reply2", sessionID: session.id)
        try await provider.insertMessage(edited)
        try await provider.insertMessage(trailing1)
        try await provider.insertMessage(trailing2)

        edited.content = "edited"
        try await provider.performMessageMutations([
            .update(edited),
            .delete(trailing1.id),
            .delete(trailing2.id),
        ])

        let messages = try await provider.fetchMessages(for: session.id)
        XCTAssertEqual(messages.map(\.content), ["edited"])
    }

    /// Branch: the message-copy batch into the new session rolls back fully on a
    /// mid-copy failure (the executor then deletes the orphaned session). Here
    /// we verify the message half: no partial prefix survives.
    func test_branchCopyBatch_rollsBackAllCopiesOnFailure() async throws {
        let source = ManifoldInference.ChatSession(title: "Branch Source")
        let target = ManifoldInference.ChatSession(title: "Branch Target")
        try await provider.insertSession(source)
        try await provider.insertSession(target)

        let copy1 = ManifoldInference.ChatMessage(role: .user, content: "copy1", sessionID: target.id)
        let copy2 = ManifoldInference.ChatMessage(role: .assistant, content: "copy2", sessionID: target.id)
        // A trailing update of a record never inserted forces failure after the
        // two inserts are staged.
        let phantom = ManifoldInference.ChatMessage(role: .user, content: "phantom", sessionID: target.id)

        do {
            try await provider.performMessageMutations([
                .insert(copy1),
                .insert(copy2),
                .update(phantom),
            ])
            XCTFail("Expected branch copy batch to fail")
        } catch {
            XCTAssertEqual(error as? ChatPersistenceError, .messageNotFound(phantom.id))
        }

        let messages = try await provider.fetchMessages(for: target.id)
        XCTAssertTrue(messages.isEmpty, "No partial message prefix should survive a failed branch copy")
    }

    /// Branch happy path: all copies land in the target session as one batch.
    func test_branchCopyBatch_commitsAllCopiesAtomically() async throws {
        let source = ManifoldInference.ChatSession(title: "Branch Source")
        let target = ManifoldInference.ChatSession(title: "Branch Target")
        try await provider.insertSession(source)
        try await provider.insertSession(target)

        try await provider.performMessageMutations([
            .insert(ManifoldInference.ChatMessage(role: .user, content: "c1", timestamp: at(0), sessionID: target.id)),
            .insert(ManifoldInference.ChatMessage(role: .assistant, content: "c2", timestamp: at(1), sessionID: target.id)),
        ])

        let messages = try await provider.fetchMessages(for: target.id)
        XCTAssertEqual(messages.map(\.content), ["c1", "c2"])
    }
}

private final class RecordingMessageHook: MessageStorePostWriteHook, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SwiftDataTransactionalMutationTests.RecordingMessageHook")
    private var _records: [(messageID: UUID, sessionID: UUID)] = []

    func messageDidWrite(_ record: ManifoldInference.ChatMessage, in sessionID: ManifoldInference.ChatSession.ID) async {
        queue.sync {
            _records.append((record.id, sessionID))
        }
    }

    var records: [(messageID: UUID, sessionID: UUID)] {
        queue.sync { _records }
    }
}
