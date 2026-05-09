import XCTest
import SwiftUI
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldUI

@MainActor
final class ChatViewModelScrollToMessageTests: XCTestCase {

    func test_requestScrollToMessage_recordsMessageIDAndAnchor() {
        let vm = makeViewModel()
        let messageID = UUID()

        vm.requestScrollToMessage(id: messageID, anchor: .center)

        XCTAssertEqual(vm.scrollToMessageRequest?.messageID, messageID)
        XCTAssertEqual(vm.scrollToMessageRequest?.anchor, .center)
    }

    func test_requestScrollToMessage_reissuesDistinctRequestsForSameMessage() {
        let vm = makeViewModel()
        let messageID = UUID()

        vm.requestScrollToMessage(id: messageID, anchor: .top)
        let first = vm.scrollToMessageRequest
        vm.requestScrollToMessage(id: messageID, anchor: .top)
        let second = vm.scrollToMessageRequest

        XCTAssertEqual(first?.messageID, second?.messageID)
        XCTAssertNotEqual(first?.requestID, second?.requestID)
    }

    func test_consumeScrollToMessageRequest_clearsMatchingRequest() throws {
        let vm = makeViewModel()
        vm.requestScrollToMessage(id: UUID(), anchor: .bottom)
        let request = try XCTUnwrap(vm.scrollToMessageRequest)

        vm.consumeScrollToMessageRequest(request)

        XCTAssertNil(vm.scrollToMessageRequest)
    }

    func test_consumeScrollToMessageRequest_doesNotClearNewerRequest() throws {
        let vm = makeViewModel()
        vm.requestScrollToMessage(id: UUID(), anchor: .top)
        let stale = try XCTUnwrap(vm.scrollToMessageRequest)
        let newerMessageID = UUID()
        vm.requestScrollToMessage(id: newerMessageID, anchor: .bottom)

        vm.consumeScrollToMessageRequest(stale)

        XCTAssertEqual(vm.scrollToMessageRequest?.messageID, newerMessageID)
        XCTAssertEqual(vm.scrollToMessageRequest?.anchor, .bottom)
    }

    func test_chatViewConsumesOnlyWhenRequestedMessageIsLoaded() {
        let sessionID = UUID()
        let requested = ChatMessageRecord(role: .user, content: "target", sessionID: sessionID)
        let other = ChatMessageRecord(role: .assistant, content: "other", sessionID: sessionID)
        let request = ChatScrollToMessageRequest(messageID: requested.id, anchor: .top)

        XCTAssertTrue(
            ChatView<EmptyView>.canConsumeScrollToMessageRequest(request, in: [other, requested]),
            "ChatView should consume a request once its target row exists."
        )
        XCTAssertFalse(
            ChatView<EmptyView>.canConsumeScrollToMessageRequest(request, in: [other]),
            "ChatView should leave missing-message requests pending so later pagination/load can satisfy them."
        )
    }

    private func makeViewModel() -> ChatViewModel {
        let mock = MockInferenceBackend()
        let service = InferenceService(backend: mock, name: "MockScrollToMessage")
        return ChatViewModel(inferenceService: service)
    }
}
