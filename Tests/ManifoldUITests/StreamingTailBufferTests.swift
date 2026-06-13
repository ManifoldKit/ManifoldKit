import XCTest
import ManifoldInference
import ManifoldRuntime
@testable import ManifoldUI
import ManifoldTestSupport

/// Pins the O(n²)-elimination fixes for the UI streaming path (issue #1786):
///   * `ChatGenerationCoordinator` accumulates streamed tokens into a tail
///     buffer and writes the whole buffer each batch, so `contentParts` always
///     holds exactly one trailing `.text` part equal to the running total.
///   * The accumulator resets when a sibling part (tool result) opens a new
///     trailing text run, so the second run is a separate `.text` part.
///   * `ChatViewModel.mutateMessage` takes the O(1) tail fast path when the id
///     is the last message, and the O(N) scan fallback otherwise.
@MainActor
final class StreamingTailBufferTests: XCTestCase {

    // MARK: - Backing store + coordinator harness

    /// Mutable message store shared with the coordinator via its closure seams.
    private final class MessageBox {
        var messages: [ChatMessage] = []
    }

    private func makeInMemoryRuntime() -> ConversationRuntime {
        ConversationRuntime(
            messageStore: NoopMessageStore(),
            inferenceService: InferenceService()
        )
    }

    /// Builds a coordinator whose message-mutation seams read/write `box`.
    private func makeCoordinator(box: MessageBox, sessionID: UUID) -> ChatGenerationCoordinator {
        let coord = ChatGenerationCoordinator(
            conversationRuntime: makeInMemoryRuntime(),
            ownsDefaultRuntime: true
        )
        coord.onTransitionPhase = { _ in true }
        coord.onSetLastTurnState = { _ in }
        coord.onSetBackgroundTaskError = { _ in }
        coord.onSetMessageIDsWithStreamingThinking = { _ in }
        coord.currentActiveSessionID = { sessionID }
        coord.currentActiveSession = { ChatSession(id: sessionID, title: "Test") }
        coord.currentMessages = { box.messages }
        coord.currentPostGenerationTasks = { [] }
        coord.appendMessage = { box.messages.append($0) }
        coord.removeMessages = { predicate in box.messages.removeAll(where: predicate) }
        coord.updateContextEstimate = {}
        coord.surfaceError = { _, _ in }
        coord.setErrorMessage = { _ in }
        coord.setShowUpgradeHint = { _ in }
        // Mirror ChatViewModel.mutateMessage including its tail fast path so the
        // coordinator behaves exactly as in production.
        coord.mutateMessage = { id, body in
            if let lastIdx = box.messages.indices.last, box.messages[lastIdx].id == id {
                body(&box.messages[lastIdx])
                return true
            }
            guard let idx = box.messages.firstIndex(where: { $0.id == id }) else { return false }
            body(&box.messages[idx])
            return true
        }
        return coord
    }

    private func trailingTextParts(_ msg: ChatMessage) -> [String] {
        msg.contentParts.compactMap { part in
            if case .text(let t) = part { return t } else { return nil }
        }
    }

    // MARK: - 1. K batches concatenate; one trailing .text always equals the buffer

    func test_streamingTokens_accumulateIntoSingleTrailingTextPart() async {
        let box = MessageBox()
        let sessionID = UUID()
        let coord = makeCoordinator(box: box, sessionID: sessionID)

        let msgID = UUID()
        await coord.handle(runtimeEvent: .streamStarted(messageID: msgID))

        let batches = ["Hel", "lo, ", "wor", "ld", "!"]
        var running = ""
        for batch in batches {
            await coord.handle(runtimeEvent: .tokenEmitted(messageID: msgID, delta: batch))
            running += batch

            // Invariant: after every batch the message ends in exactly one
            // trailing `.text` part equal to the running concatenation.
            let msg = box.messages.first(where: { $0.id == msgID })!
            guard case .text(let trailing)? = msg.contentParts.last else {
                return XCTFail("Trailing part must be .text after a token batch")
            }
            XCTAssertEqual(trailing, running, "Trailing text must equal the running buffer")
            XCTAssertEqual(
                msg.contentParts.filter { $0.textContent != nil }.count, 1,
                "There must be exactly one text part during a contiguous text run"
            )
        }

        let final = box.messages.first(where: { $0.id == msgID })!
        XCTAssertEqual(final.content, batches.joined())
    }

    // MARK: - 2. Buffer resets when a tool result opens a new trailing text run

    func test_streamingTokens_resetBufferAcrossInterleavedToolResult() async {
        let box = MessageBox()
        let sessionID = UUID()
        let coord = makeCoordinator(box: box, sessionID: sessionID)

        let msgID = UUID()
        await coord.handle(runtimeEvent: .streamStarted(messageID: msgID))
        coord.activeConversationMessageID = msgID

        // First text run.
        await coord.handle(runtimeEvent: .tokenEmitted(messageID: msgID, delta: "before"))

        // A tool result lands, ending the trailing text run.
        let result = ToolResult(callId: "c1", content: "done")
        await coord.handle(runtimeEvent: .toolCallCompleted("c1", result))

        // Second text run.
        await coord.handle(runtimeEvent: .tokenEmitted(messageID: msgID, delta: "after"))

        let msg = box.messages.first(where: { $0.id == msgID })!
        let textParts = trailingTextParts(msg)
        XCTAssertEqual(textParts, ["before", "after"],
                       "Second text run must be a separate .text part; first run untouched")

        // Tool result must sit between the two text runs.
        XCTAssertTrue(msg.contentParts.contains(where: { $0.toolResultContent != nil }),
                      "Tool result part must be preserved between the text runs")
    }

    // MARK: - 3. mutateMessage fast path correctness

    func test_mutateMessage_fastPath_mutatesLastMessage() throws {
        let harness = try makeTestChatViewModel()
        defer { harness.cleanup() }
        let vm = harness.vm

        let sessionID = UUID()
        let first = ChatMessage(role: .assistant, content: "first", sessionID: sessionID)
        let last = ChatMessage(role: .assistant, content: "last", sessionID: sessionID)
        vm.messages = [first, last]

        let mutated = vm.mutateMessage(id: last.id) { $0.content = "last-edited" }

        XCTAssertTrue(mutated)
        XCTAssertEqual(vm.messages.last?.content, "last-edited")
        XCTAssertEqual(vm.messages.first?.content, "first", "Non-tail message must be untouched")
    }

    func test_mutateMessage_fallbackScan_mutatesNonTailMessage() throws {
        let harness = try makeTestChatViewModel()
        defer { harness.cleanup() }
        let vm = harness.vm

        let sessionID = UUID()
        let first = ChatMessage(role: .assistant, content: "first", sessionID: sessionID)
        let last = ChatMessage(role: .assistant, content: "last", sessionID: sessionID)
        vm.messages = [first, last]

        // Mutating the NON-tail message must hit the firstIndex fallback.
        let mutated = vm.mutateMessage(id: first.id) { $0.content = "first-edited" }

        XCTAssertTrue(mutated)
        XCTAssertEqual(vm.messages.first?.content, "first-edited")
        XCTAssertEqual(vm.messages.last?.content, "last", "Tail message must be untouched")
    }

    func test_mutateMessage_unknownID_returnsFalse() throws {
        let harness = try makeTestChatViewModel()
        defer { harness.cleanup() }
        let vm = harness.vm

        vm.messages = [ChatMessage(role: .assistant, content: "only", sessionID: UUID())]

        XCTAssertFalse(vm.mutateMessage(id: UUID()) { $0.content = "nope" })
    }
}

/// Minimal in-memory MessageStore so these coordinator unit tests don't depend
/// on SwiftData. The coordinator's text-accumulation path never touches the
/// store — it exists only to construct a `ConversationRuntime`.
private final class NoopMessageStore: MessageStore, @unchecked Sendable {
    private var messages: [UUID: ChatMessage] = [:]
    private var hooks: [any MessageStorePostWriteHook] = []

    func insertMessage(_ message: ChatMessage) async throws {
        messages[message.id] = message
        for hook in hooks { await hook.messageDidWrite(message, in: message.sessionID) }
    }
    func updateMessage(_ message: ChatMessage) async throws {
        messages[message.id] = message
        for hook in hooks { await hook.messageDidWrite(message, in: message.sessionID) }
    }
    func deleteMessage(_ messageID: UUID) async throws { messages.removeValue(forKey: messageID) }
    func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] {
        messages.values.filter { $0.sessionID == sessionID }.sorted { $0.timestamp < $1.timestamp }
    }
    func deleteMessages(for sessionID: UUID) async throws {
        messages = messages.filter { $0.value.sessionID != sessionID }
    }
    func addPostWriteHook(_ hook: any MessageStorePostWriteHook) { hooks.append(hook) }
}
