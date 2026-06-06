import XCTest
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldUI

@MainActor
final class ChatViewModelIntentDispatchTests: XCTestCase {

    // MARK: - Forwarding

    func test_dispatch_forwardsActionAndSessionID_toHandler() async throws {
        let vm = await makeViewModel()
        let handler = MockChatSessionIntentHandler()
        vm.intentHandler = handler

        let session = ManifoldInference.ChatSession(title: "Routing")
        vm.activeSession = session

        try await vm.dispatch(.continueSession)

        XCTAssertEqual(handler.invocations.count, 1)
        XCTAssertEqual(handler.invocations.first?.action, .continueSession)
        XCTAssertEqual(handler.invocations.first?.sessionID, session.id)
    }

    func test_dispatch_forwardsNilSessionID_whenNoActiveSession() async throws {
        let vm = await makeViewModel()
        let handler = MockChatSessionIntentHandler()
        vm.intentHandler = handler

        XCTAssertNil(vm.activeSession)

        try await vm.dispatch(.startNewSession)

        XCTAssertEqual(handler.invocations.count, 1)
        XCTAssertEqual(handler.invocations.first?.action, .startNewSession)
        XCTAssertNil(handler.invocations.first?.sessionID)
    }

    func test_dispatch_forwardsEveryActionVerbatim() async throws {
        let vm = await makeViewModel()
        let handler = MockChatSessionIntentHandler()
        vm.intentHandler = handler

        let actions: [ChatIntentAction] = [
            .continueSession,
            .startNewSession,
            .readLastMessage,
            .summariseSession,
        ]
        for action in actions {
            try await vm.dispatch(action)
        }

        XCTAssertEqual(handler.invocations.map(\.action), actions)
    }

    // MARK: - No-op when handler is absent

    func test_dispatch_isNoOp_whenHandlerIsNil() async throws {
        let vm = await makeViewModel()
        XCTAssertNil(vm.intentHandler)

        // Must not throw and must complete without observable effect.
        try await vm.dispatch(.readLastMessage)
        try await vm.dispatch(.summariseSession)
    }

    // MARK: - Error propagation

    func test_dispatch_propagatesErrorFromHandler() async {
        let vm = await makeViewModel()
        let handler = MockChatSessionIntentHandler()
        handler.errorToThrow = TestError.boom
        vm.intentHandler = handler

        do {
            try await vm.dispatch(.summariseSession)
            XCTFail("Expected dispatch to rethrow the handler's error")
        } catch let error as TestError {
            XCTAssertEqual(error, .boom)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Helpers

    private func makeViewModel() -> ChatViewModel {
        let mock = MockInferenceBackend()
        let service = InferenceService(backend: mock, name: "MockIntentDispatch")
        return ChatViewModel(inferenceService: service)
    }

    private enum TestError: Error, Equatable {
        case boom
    }
}
