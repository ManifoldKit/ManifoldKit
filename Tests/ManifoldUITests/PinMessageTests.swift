@preconcurrency import XCTest
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport

@MainActor
final class PinMessageTests: XCTestCase {

    private var harness: TestChatViewModelHarness!
    private var context: ModelContext { harness.container!.mainContext }
    private var vm: ChatViewModel { harness.vm }
    private var mock: MockInferenceBackend { harness.mock! }

    override func setUp() async throws {
        try await super.setUp()
        let backend = MockInferenceBackend()
        backend.tokensToYield = ["Reply"]
        harness = try makeTestChatViewModel(mock: backend, configurePersistence: true)
    }

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    @discardableResult
    private func createSession(title: String = "Pin Test") async -> ChatSessionRecord {
        let session = ChatSession(title: title)
        context.insert(session)
        try? context.save()
        let record = session.toRecord()
        await vm.switchToSession(record)
        return record
    }

    private func makeMessageID(content: String = "Hello") -> UUID {
        let sessionID = vm.activeSession!.id
        let msg = ChatMessageRecord(role: .user, content: content, sessionID: sessionID)
        vm.messages.append(msg)
        return msg.id
    }

    // MARK: - Tests

    func test_pinMessage_addsToSet() async {
        await createSession()
        let id = makeMessageID()

        await vm.pinMessage(id: id)

        XCTAssertTrue(vm.isMessagePinned(id: id),
                      "isMessagePinned should return true after pinMessage")
    }

    func test_unpinMessage_removesFromSet() async {
        await createSession()
        let id = makeMessageID()

        await vm.pinMessage(id: id)
        XCTAssertTrue(vm.isMessagePinned(id: id), "Precondition: message should be pinned")

        await vm.unpinMessage(id: id)

        XCTAssertFalse(vm.isMessagePinned(id: id),
                       "isMessagePinned should return false after unpinMessage")
    }

    func test_pinMessage_idempotent() async {
        await createSession()
        let id = makeMessageID()

        await vm.pinMessage(id: id)
        await vm.pinMessage(id: id)

        XCTAssertEqual(vm.pinnedMessageIDs.count, 1,
                       "pinnedMessageIDs should contain exactly 1 entry after pinning the same message twice")
    }

    func test_unpin_unpinnedMessage_doesNotCrash() async {
        await createSession()
        let id = makeMessageID()

        await vm.unpinMessage(id: id)

        XCTAssertFalse(vm.isMessagePinned(id: id),
                       "Message should remain unpinned after unpinMessage on a non-pinned message")
    }

    func test_pinMultipleMessages_allPinned() async {
        await createSession()
        let id1 = makeMessageID(content: "First")
        let id2 = makeMessageID(content: "Second")
        let id3 = makeMessageID(content: "Third")

        await vm.pinMessage(id: id1)
        await vm.pinMessage(id: id2)
        await vm.pinMessage(id: id3)

        XCTAssertTrue(vm.isMessagePinned(id: id1), "msg1 should be pinned")
        XCTAssertTrue(vm.isMessagePinned(id: id2), "msg2 should be pinned")
        XCTAssertTrue(vm.isMessagePinned(id: id3), "msg3 should be pinned")
        XCTAssertEqual(vm.pinnedMessageIDs.count, 3,
                       "All 3 messages should appear in pinnedMessageIDs")
    }

    func test_pinnedState_clearedOnSessionSwitch() async {
        await createSession(title: "Session A")
        let idA = makeMessageID(content: "Message in A")
        await vm.pinMessage(id: idA)
        XCTAssertTrue(vm.isMessagePinned(id: idA), "Precondition: msgA should be pinned in session A")

        let sessionB = ChatSession(title: "Session B")
        context.insert(sessionB)
        try? context.save()
        await vm.switchToSession(sessionB.toRecord())

        XCTAssertFalse(vm.pinnedMessageIDs.contains(idA),
                       "Pins from session A should not be visible after switching to session B")
    }
}
