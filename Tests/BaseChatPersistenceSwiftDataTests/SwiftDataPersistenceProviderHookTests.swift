import XCTest
import SwiftData
@testable import BaseChatPersistenceSwiftData
import BaseChatInference
import BaseChatRuntime
import BaseChatTestSupport

/// Phase 1.2.1 — `MessageStorePostWriteHook` integration coverage for the
/// SwiftData adapter. Same contract as the protocol-level tests in
/// `BaseChatRuntimeTests/MessageStorePostWriteHookTests.swift`, but
/// exercising the real `SwiftDataPersistenceProvider` against an in-memory
/// SwiftData container so the post-commit ordering and the
/// `addPostWriteHook` registration path are covered against the production
/// adapter, not just an in-memory fake.
///
/// The hook is a low-level primitive — these tests assert post-commit
/// firing, registration order, and the symmetry of the session-write hook;
/// they do **not** position the hook as the canonical attachment point for
/// any specific consumer.
@MainActor
final class SwiftDataPersistenceProviderHookTests: XCTestCase {

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

    // MARK: - MessageStorePostWriteHook

    func test_messageHook_firesAfterInsertCommit() async throws {
        let session = ChatSessionRecord(title: "S")
        try await provider.insertSession(session)

        let hook = RecordingMessageHook()
        provider.addPostWriteHook(hook)

        let record = ChatMessageRecord(role: .user, content: "hi", sessionID: session.id)
        try await provider.insertMessage(record)

        XCTAssertEqual(hook.records.count, 1)
        XCTAssertEqual(hook.records.first?.messageID, record.id)
        XCTAssertEqual(hook.records.first?.sessionID, session.id)

        // Post-commit visibility: fetching from the store immediately after
        // returns the freshly written message.
        let fetched = try await provider.fetchMessages(for: session.id)
        XCTAssertEqual(fetched.map(\.id), [record.id])
    }

    func test_messageHook_firesAfterUpdate() async throws {
        let session = ChatSessionRecord(title: "S")
        try await provider.insertSession(session)
        var record = ChatMessageRecord(role: .user, content: "hi", sessionID: session.id)
        try await provider.insertMessage(record)

        let hook = RecordingMessageHook()
        provider.addPostWriteHook(hook)

        record.contentParts = [.text("hello")]
        try await provider.updateMessage(record)

        XCTAssertEqual(hook.records.count, 1, "Only the update should fire — insert pre-dated registration")
    }

    func test_messageHook_multipleHooks_fireInRegistrationOrder() async throws {
        let session = ChatSessionRecord(title: "S")
        try await provider.insertSession(session)

        let order = OrderRecorder()
        provider.addPostWriteHook(OrderingMessageHook(label: "first", order: order))
        provider.addPostWriteHook(OrderingMessageHook(label: "second", order: order))
        provider.addPostWriteHook(OrderingMessageHook(label: "third", order: order))

        let record = ChatMessageRecord(role: .user, content: "x", sessionID: session.id)
        try await provider.insertMessage(record)

        XCTAssertEqual(order.snapshot(), ["first", "second", "third"])
    }

    func test_messageHook_doesNotFireOnDelete() async throws {
        // Delete intentionally does not fire the post-write hook — the hook
        // contract is "after a write commits"; the consumer's primary use
        // case (audit/index a fresh record) needs the record's content,
        // which is gone post-delete. Phase 1.2.1 ships the post-write
        // contract; a hypothetical post-delete hook is a separate primitive.
        let session = ChatSessionRecord(title: "S")
        try await provider.insertSession(session)
        let record = ChatMessageRecord(role: .user, content: "doomed", sessionID: session.id)
        try await provider.insertMessage(record)

        let hook = RecordingMessageHook()
        provider.addPostWriteHook(hook)

        try await provider.deleteMessage(record.id)
        XCTAssertEqual(hook.records.count, 0,
                       "Post-write hook fires on insert/update, not on delete")
    }

    // MARK: - SessionStorePostWriteHook

    func test_sessionHook_firesAfterInsertCommit() async throws {
        let hook = RecordingSessionHook()
        provider.addPostWriteHook(hook)

        let session = ChatSessionRecord(title: "S")
        try await provider.insertSession(session)

        XCTAssertEqual(hook.records.count, 1)
        XCTAssertEqual(hook.records.first?.id, session.id)
    }

    func test_sessionHook_firesAfterUpdate() async throws {
        var session = ChatSessionRecord(title: "S")
        try await provider.insertSession(session)

        let hook = RecordingSessionHook()
        provider.addPostWriteHook(hook)

        session.title = "Renamed"
        try await provider.updateSession(session)

        XCTAssertEqual(hook.records.count, 1)
        XCTAssertEqual(hook.records.first?.title, "Renamed")
    }
}

// MARK: - Helpers

private final class RecordingMessageHook: MessageStorePostWriteHook, @unchecked Sendable {
    private let queue = DispatchQueue(label: "RecordingMessageHook.lock")
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

private final class RecordingSessionHook: SessionStorePostWriteHook, @unchecked Sendable {
    private let queue = DispatchQueue(label: "RecordingSessionHook.lock")
    private var _records: [ChatSessionRecord] = []

    func sessionDidWrite(_ record: ChatSessionRecord) async {
        queue.sync { _records.append(record) }
    }

    var records: [ChatSessionRecord] {
        queue.sync { _records }
    }
}

private final class OrderRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "OrderRecorder.lock")
    private var entries: [String] = []

    func append(_ label: String) {
        queue.sync { entries.append(label) }
    }

    func snapshot() -> [String] {
        queue.sync { entries }
    }
}

private struct OrderingMessageHook: MessageStorePostWriteHook {
    let label: String
    let order: OrderRecorder

    func messageDidWrite(_ record: ChatMessageRecord, in sessionID: ChatSessionRecord.ID) async {
        order.append(label)
    }
}
