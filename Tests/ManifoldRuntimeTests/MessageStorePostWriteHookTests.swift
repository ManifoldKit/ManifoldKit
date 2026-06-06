@preconcurrency import XCTest
import Foundation
@testable import ManifoldInference
@testable import ManifoldRuntime

/// Phase 1.2.1 — protocol-level coverage for ``MessageStorePostWriteHook``
/// against an in-memory ``MessageStore`` fake.
///
/// The hook is a low-level primitive: it fires post-commit, in registration
/// order, must not throw, and a hook that does throw an `Error` (only via
/// `try? await` inside the impl since the protocol declares no `throws`)
/// cannot roll back the write. These tests pin those semantics so the
/// SwiftData adapter and any future custom store enforce the same contract.
@MainActor
final class MessageStorePostWriteHookTests: XCTestCase {

    // MARK: - In-memory MessageStore fake
    //
    // Real `async throws` impl, no SwiftData. Hooks fire after the in-memory
    // dictionary commit and in registration order. Used here to assert the
    // protocol contract; the SwiftData equivalent is exercised in
    // `SwiftDataPersistenceProviderTests` in ManifoldCoreTests.

    @MainActor
    final class InMemoryMessageStore: MessageStore {
        private(set) var messages: [UUID: ChatMessage] = [:]
        private var hooks: [any MessageStorePostWriteHook] = []

        func insertMessage(_ message: ChatMessage) async throws {
            messages[message.id] = message
            for hook in hooks {
                await hook.messageDidWrite(message, in: message.sessionID)
            }
        }

        func updateMessage(_ message: ChatMessage) async throws {
            guard messages[message.id] != nil else {
                throw ChatPersistenceError.messageNotFound(message.id)
            }
            messages[message.id] = message
            for hook in hooks {
                await hook.messageDidWrite(message, in: message.sessionID)
            }
        }

        func deleteMessage(_ messageID: UUID) async throws {
            guard messages.removeValue(forKey: messageID) != nil else {
                throw ChatPersistenceError.messageNotFound(messageID)
            }
        }

        func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] {
            messages.values
                .filter { $0.sessionID == sessionID }
                .sorted { $0.timestamp < $1.timestamp }
        }

        func deleteMessages(for sessionID: UUID) async throws {
            messages = messages.filter { $0.value.sessionID != sessionID }
        }

        func addPostWriteHook(_ hook: any MessageStorePostWriteHook) {
            hooks.append(hook)
        }
    }

    final class RecordingHook: MessageStorePostWriteHook, @unchecked Sendable {
        private let queue = DispatchQueue(label: "RecordingHook.lock")
        private var _records: [(messageID: UUID, sessionID: UUID, label: String)] = []
        let label: String

        init(label: String = "default") {
            self.label = label
        }

        func messageDidWrite(_ record: ChatMessage, in sessionID: ChatSession.ID) async {
            queue.sync {
                _records.append((record.id, sessionID, label))
            }
        }

        var records: [(messageID: UUID, sessionID: UUID, label: String)] {
            queue.sync { _records }
        }
    }

    // MARK: - Tests

    func test_singleHook_firesAfterInsert() async throws {
        let store = InMemoryMessageStore()
        let hook = RecordingHook()
        store.addPostWriteHook(hook)

        let sessionID = UUID()
        let record = ChatMessage(role: .user, content: "hi", sessionID: sessionID)
        try await store.insertMessage(record)

        XCTAssertEqual(hook.records.count, 1)
        XCTAssertEqual(hook.records.first?.messageID, record.id)
        XCTAssertEqual(hook.records.first?.sessionID, sessionID)
    }

    func test_singleHook_firesAfterUpdate() async throws {
        let store = InMemoryMessageStore()
        let hook = RecordingHook()
        store.addPostWriteHook(hook)

        let sessionID = UUID()
        var record = ChatMessage(role: .user, content: "hi", sessionID: sessionID)
        try await store.insertMessage(record)
        record.contentParts = [.text("updated")]
        try await store.updateMessage(record)

        XCTAssertEqual(hook.records.count, 2, "Both insert and update should fire the hook")
    }

    func test_multipleHooks_fireInRegistrationOrder() async throws {
        let store = InMemoryMessageStore()
        let first = RecordingHook(label: "first")
        let second = RecordingHook(label: "second")
        let third = RecordingHook(label: "third")
        store.addPostWriteHook(first)
        store.addPostWriteHook(second)
        store.addPostWriteHook(third)

        // Use a single shared collector to verify cross-hook ordering.
        let order = OrderRecorder()
        store.addPostWriteHook(OrderingHook(label: "first-shared", order: order))
        store.addPostWriteHook(OrderingHook(label: "second-shared", order: order))
        store.addPostWriteHook(OrderingHook(label: "third-shared", order: order))

        let sessionID = UUID()
        let record = ChatMessage(role: .user, content: "hi", sessionID: sessionID)
        try await store.insertMessage(record)

        XCTAssertEqual(first.records.count, 1)
        XCTAssertEqual(second.records.count, 1)
        XCTAssertEqual(third.records.count, 1)

        // Cross-hook ordering: the shared recorder must observe the labels in
        // exactly the order they were registered.
        XCTAssertEqual(
            order.snapshot(),
            ["first-shared", "second-shared", "third-shared"],
            "Hooks must fire in registration order"
        )
    }

    func test_hookFiresPostCommit_seesWrittenRecord() async throws {
        // The hook must observe a state where the write has already
        // committed — querying the store from inside the hook returns the
        // freshly-written record.
        let store = InMemoryMessageStore()
        let sessionID = UUID()
        let observation = HookObservation()
        store.addPostWriteHook(QueryingHook(store: store, observation: observation))

        let record = ChatMessage(role: .user, content: "hi", sessionID: sessionID)
        try await store.insertMessage(record)

        XCTAssertEqual(observation.observedCount, 1,
                       "Hook must see the committed write when fetching during messageDidWrite")
    }

    func test_hookRegisteredAfterWrite_doesNotReplay() async throws {
        let store = InMemoryMessageStore()
        let sessionID = UUID()
        try await store.insertMessage(ChatMessage(role: .user, content: "early", sessionID: sessionID))

        // Hook registered after the first write — the contract is no replay.
        let hook = RecordingHook()
        store.addPostWriteHook(hook)
        XCTAssertEqual(hook.records.count, 0, "No replay of writes that happened before registration")

        try await store.insertMessage(ChatMessage(role: .user, content: "later", sessionID: sessionID))
        XCTAssertEqual(hook.records.count, 1, "Subsequent writes still fire")
    }

    func test_hookProtocolHasNoThrows() {
        // Compile-time pin: `messageDidWrite` is `async`, not `async throws`.
        // The protocol forbids hooks from rolling back a committed write,
        // so the signature must not be `throws`. This test is a guard
        // against the protocol surface drifting in code review.
        // The assertion is the existence of this code path — if the protocol
        // ever becomes `async throws`, this `try?`-free line stops compiling.
        let _: (any MessageStorePostWriteHook) -> Void = { hook in
            Task {
                let dummy = ChatMessage(role: .user, content: "x", sessionID: UUID())
                await hook.messageDidWrite(dummy, in: dummy.sessionID)
            }
        }
    }

    // MARK: - Default no-op behaviour

    func test_defaultAddPostWriteHook_isNoOp_onMinimalStore() async throws {
        // A store that doesn't implement `addPostWriteHook` inherits the
        // default no-op extension. Registering a hook should not crash, and
        // subsequent writes should not fire it.
        let store = MinimalMessageStore()
        let hook = RecordingHook()
        store.addPostWriteHook(hook)

        try await store.insertMessage(ChatMessage(role: .user, content: "hi", sessionID: UUID()))
        XCTAssertEqual(hook.records.count, 0, "Default no-op must not invoke the hook")
    }
}

// MARK: - Helper types (file-private)

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

private struct OrderingHook: MessageStorePostWriteHook {
    let label: String
    let order: OrderRecorder

    func messageDidWrite(_ record: ChatMessage, in sessionID: ChatSession.ID) async {
        order.append(label)
    }
}

private final class HookObservation: @unchecked Sendable {
    private let queue = DispatchQueue(label: "HookObservation.lock")
    private var _observedCount = 0

    func record(_ count: Int) {
        queue.sync { _observedCount = count }
    }

    var observedCount: Int {
        queue.sync { _observedCount }
    }
}

private struct QueryingHook: MessageStorePostWriteHook {
    let store: MessageStorePostWriteHookTests.InMemoryMessageStore
    let observation: HookObservation

    @MainActor
    func messageDidWrite(_ record: ChatMessage, in sessionID: ChatSession.ID) async {
        // Query the store from inside the hook — the write must already be
        // visible.
        let messages = (try? await store.fetchMessages(for: sessionID)) ?? []
        observation.record(messages.count)
    }
}

/// Minimal store that does NOT override `addPostWriteHook`, so it inherits
/// the protocol-extension no-op. Verifies the default doesn't trap.
@MainActor
private final class MinimalMessageStore: MessageStore {
    private(set) var messages: [UUID: ChatMessage] = [:]

    func insertMessage(_ message: ChatMessage) async throws {
        messages[message.id] = message
    }

    func updateMessage(_ message: ChatMessage) async throws {
        messages[message.id] = message
    }

    func deleteMessage(_ messageID: UUID) async throws {
        messages.removeValue(forKey: messageID)
    }

    func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] {
        Array(messages.values)
    }

    func deleteMessages(for sessionID: UUID) async throws {
        messages.removeAll()
    }
}
