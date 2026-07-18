@preconcurrency import XCTest
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport

/// ViewModel integration tests for the data that drives the pin indicator in MessageBubbleView.
///
/// Each test targets `isMessagePinned`, `pinMessage`, and `unpinMessage` to confirm that
/// the Boolean value powering the visual indicator is correct across all relevant state
/// transitions, and that pin state is persisted to the active PersistedChatSession.
@MainActor
final class PinnedMessageIndicatorTests: XCTestCase {

    private var harness: TestChatViewModelHarness!
    private var context: ModelContext { harness.container!.mainContext }
    private var vm: ChatViewModel { harness.vm }
    private var mock: MockInferenceBackend { harness.mock! }

    // MARK: - Setup / Teardown

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

    // MARK: - Helpers

    @discardableResult
    private func createSession(title: String = "Pin Test") async -> PersistedChatSession {
        let session = PersistedChatSession(title: title)
        context.insert(session)
        try? context.save()
        await vm.switchToSession(session.toRecord())
        return session
    }

    private func makeMessage() -> ManifoldSchemaV9.ChatMessage {
        let sessionID = vm.activeSession!.id
        let message = ManifoldSchemaV9.ChatMessage(role: .user, content: "Test message", sessionID: sessionID)
        vm.messages.append(message.toRecord())
        return message
    }

    // MARK: - Tests

    func test_isMessagePinned_falseBeforePin() async {
        await createSession()
        let message = makeMessage()

        XCTAssertFalse(vm.isMessagePinned(id: message.id),
                       "A newly created message should not be pinned")
    }

    func test_isMessagePinned_trueAfterPin() async {
        await createSession()
        let message = makeMessage()

        await vm.pinMessage(id: message.id)

        XCTAssertTrue(vm.isMessagePinned(id: message.id),
                      "isMessagePinned should return true after pinMessage")
    }

    func test_isMessagePinned_falseAfterUnpin() async {
        await createSession()
        let message = makeMessage()

        await vm.pinMessage(id: message.id)
        XCTAssertTrue(vm.isMessagePinned(id: message.id), "Precondition: message should be pinned")

        await vm.unpinMessage(id: message.id)

        XCTAssertFalse(vm.isMessagePinned(id: message.id),
                       "isMessagePinned should return false after unpinMessage")
    }

    func test_pinnedMessageIDs_persistedToSession() async {
        let session = await createSession()
        let message = makeMessage()

        await vm.pinMessage(id: message.id)

        XCTAssertTrue(session.toRecord().pinnedMessageIDs.contains(message.id),
                      "After pinMessage, the session's pinnedMessageIDs should contain the message's id")
    }

    func test_unpinnedMessage_removedFromSession() async {
        let session = await createSession()
        let message = makeMessage()

        await vm.pinMessage(id: message.id)
        XCTAssertTrue(session.toRecord().pinnedMessageIDs.contains(message.id),
                      "Precondition: session should contain the pinned id")

        await vm.unpinMessage(id: message.id)

        XCTAssertFalse(session.toRecord().pinnedMessageIDs.contains(message.id),
                       "After unpinMessage, the session's pinnedMessageIDs should no longer contain the id")
    }
}
