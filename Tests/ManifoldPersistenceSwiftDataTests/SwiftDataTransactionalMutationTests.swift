import XCTest
@testable import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldRuntime
import ManifoldTestSupport

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

    func test_performMessageMutations_commitsBatchAndFiresHooksAfterCommit() async throws {
        let session = ChatSessionRecord(title: "Transactional")
        try await provider.insertSession(session)

        var existing = ChatMessageRecord(role: .user, content: "before", sessionID: session.id)
        try await provider.insertMessage(existing)
        let inserted = ChatMessageRecord(role: .assistant, content: "new", sessionID: session.id)

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
        let session = ChatSessionRecord(title: "Rollback")
        try await provider.insertSession(session)

        var first = ChatMessageRecord(role: .user, content: "before", sessionID: session.id)
        let second = ChatMessageRecord(role: .assistant, content: "keep", sessionID: session.id)
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
        let session = ChatSessionRecord(title: "Hook Rollback")
        try await provider.insertSession(session)

        var record = ChatMessageRecord(role: .user, content: "before", sessionID: session.id)
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
}

private final class RecordingMessageHook: MessageStorePostWriteHook, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SwiftDataTransactionalMutationTests.RecordingMessageHook")
    private var _records: [(messageID: UUID, sessionID: UUID)] = []

    func messageDidWrite(_ record: ChatMessageRecord, in sessionID: ChatSessionRecord.ID) async {
        queue.sync {
            _records.append((record.id, sessionID))
        }
    }

    var records: [(messageID: UUID, sessionID: UUID)] {
        queue.sync { _records }
    }
}
