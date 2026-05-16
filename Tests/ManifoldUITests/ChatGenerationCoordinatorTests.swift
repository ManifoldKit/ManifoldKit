import XCTest
import ManifoldInference
import ManifoldRuntime
@testable import ManifoldUI
import ManifoldTestSupport

/// Isolation tests for ``ChatGenerationCoordinator`` — drives the coordinator
/// directly without a ``ChatViewModel``, using spy closures to capture output.
///
/// These tests confirm the extraction keeps the coordinator decoupled from its
/// collaborators (phase 2 of #1221).
@MainActor
final class ChatGenerationCoordinatorTests: XCTestCase {

    // MARK: - Helpers

    private func makeInMemoryRuntime() -> ConversationRuntime {
        let store = InMemoryMessageStoreForTests()
        return ConversationRuntime(
            messageStore: store,
            inferenceService: InferenceService()
        )
    }

    /// Builds a coordinator with no-op closures pre-installed, then configures
    /// spy closures for the properties each test cares about.
    private func makeSilentCoordinator() -> ChatGenerationCoordinator {
        let runtime = makeInMemoryRuntime()
        let coord = ChatGenerationCoordinator(
            conversationRuntime: runtime,
            ownsDefaultRuntime: true
        )
        // Install no-op defaults for all seams so tests only override what they
        // need — prevents unexpected nil-closure crashes in unrelated paths.
        coord.onTransitionPhase = { _ in false }
        coord.onSetLastTurnState = { _ in }
        coord.onSetBackgroundTaskError = { _ in }
        coord.onSetMessageIDsWithStreamingThinking = { _ in }
        coord.currentActiveSessionID = { nil }
        coord.currentActiveSession = { nil }
        coord.currentMessages = { [] }
        coord.currentPostGenerationTasks = { [] }
        coord.mutateMessage = { _, _ in false }
        coord.appendMessage = { _ in }
        coord.removeMessages = { _ in }
        coord.updateContextEstimate = {}
        coord.surfaceError = { _, _ in }
        coord.setErrorMessage = { _ in }
        coord.setShowUpgradeHint = { _ in }
        return coord
    }

    // MARK: - 1. transitionPhase calls onTransitionPhase callback

    func test_transitionPhase_callsOnTransitionPhaseCallback() {
        let coord = makeSilentCoordinator()
        var received: [BackendActivityPhase] = []
        coord.onTransitionPhase = { phase in received.append(phase); return true }

        coord.transitionPhase(to: .waitingForFirstToken)

        XCTAssertEqual(received, [.waitingForFirstToken])
    }

    // MARK: - 2. transitionPhase rejects illegal transition

    func test_transitionPhase_rejectIllegalTransition_doesNotCallCallback() {
        let coord = makeSilentCoordinator()
        // Machine starts at .idle; streaming → idle is fine but idle → streaming
        // is not legal (must go through waitingForFirstToken first).
        // Actually idle → streaming is a state machine rejected path.
        var callbackCount = 0
        coord.onTransitionPhase = { _ in callbackCount += 1; return true }

        // streaming → idle would be valid but streaming is not the current state.
        // idle → streaming is illegal per the state machine.
        coord.transitionPhase(to: .streaming)

        XCTAssertEqual(callbackCount, 0, "Illegal transition must not invoke onTransitionPhase")
    }

    // MARK: - 3. streamStarted sets lastTurnState to .generating

    func test_handleStreamStarted_setsLastTurnStateGenerating() async {
        let coord = makeSilentCoordinator()
        var lastState: ChatViewModel.TurnState?
        coord.onSetLastTurnState = { lastState = $0 }
        coord.onTransitionPhase = { _ in true }

        let msgID = UUID()
        await coord.handle(runtimeEvent: .streamStarted(messageID: msgID))

        guard case .generating = lastState else {
            return XCTFail("Expected .generating, got \(String(describing: lastState))")
        }
    }

    // MARK: - 4. streamFinished(.stop) calls onSetLastTurnState(.completed)

    func test_handleStreamFinished_stop_callsOnSetLastTurnStateCompleted() async {
        let coord = makeSilentCoordinator()
        let sessionID = UUID()
        let msgID = UUID()

        var states: [ChatViewModel.TurnState] = []
        coord.onSetLastTurnState = { states.append($0) }
        coord.onTransitionPhase = { _ in true }
        coord.currentActiveSessionID = { sessionID }

        // Build a message with visible content so the completion branch fires.
        var msg = ChatMessageRecord(id: msgID, role: .assistant, content: "Hello", sessionID: sessionID)
        msg.contentParts = [.text("Hello")]
        let session = ChatSessionRecord(id: sessionID, title: "Test")

        coord.currentMessages = { [msg] }
        coord.currentActiveSession = { session }
        coord.currentPostGenerationTasks = { [] }

        // Simulate: streamStarted → streamFinished(.stop)
        coord.activeConversationMessageID = msgID
        coord.activeConversationStreamHandle = ConversationStreamHandle(id: UUID())

        await coord.handle(runtimeEvent: .streamFinished(messageID: msgID, reason: .stop))

        XCTAssertTrue(states.contains(where: { if case .completed = $0 { return true }; return false }),
                      "Expected .completed in states, got \(states)")
    }

    // MARK: - 5. streamFinished(.cancelled) calls onSetLastTurnState(.idle)

    func test_handleStreamFinished_cancelled_callsOnSetLastTurnStateIdle() async {
        let coord = makeSilentCoordinator()
        let msgID = UUID()
        let sessionID = UUID()

        var states: [ChatViewModel.TurnState] = []
        coord.onSetLastTurnState = { states.append($0) }
        coord.onTransitionPhase = { _ in true }
        coord.currentActiveSessionID = { sessionID }
        coord.currentMessages = {
            [ChatMessageRecord(id: msgID, role: .assistant, content: "", sessionID: sessionID)]
        }
        coord.currentActiveSession = { ChatSessionRecord(id: sessionID, title: "Test") }

        coord.activeConversationMessageID = msgID
        coord.activeConversationStreamHandle = ConversationStreamHandle(id: UUID())

        await coord.handle(runtimeEvent: .streamFinished(messageID: msgID, reason: .cancelled))

        XCTAssertTrue(states.contains(where: { if case .idle = $0 { return true }; return false }),
                      "Expected .idle in states after cancellation")
    }

    // MARK: - 6. errorRaised(.cancelled) does not surface an error

    func test_handleErrorRaised_cancelled_doesNotSurfaceError() async {
        let coord = makeSilentCoordinator()
        var surfacedErrors: [any Error] = []
        coord.surfaceError = { error, _ in surfacedErrors.append(error) }
        coord.onTransitionPhase = { _ in true }
        coord.onSetLastTurnState = { _ in }

        await coord.handle(runtimeEvent: .errorRaised(.cancelled))

        XCTAssertTrue(surfacedErrors.isEmpty, "Cancelled error must not surface to the UI")
    }

    // MARK: - 7. thinkingStarted inserts a placeholder

    func test_handleThinkingStarted_insertsPlaceholder() async {
        let coord = makeSilentCoordinator()
        let msgID = UUID()
        let sessionID = UUID()

        // Use a real message so we can observe the mutation.
        var msg = ChatMessageRecord(id: msgID, role: .assistant, content: "", sessionID: sessionID)
        coord.mutateMessage = { id, body in
            guard id == msgID else { return false }
            body(&msg)
            return true
        }
        coord.onSetMessageIDsWithStreamingThinking = { _ in }

        await coord.handle(runtimeEvent: .thinkingStarted(messageID: msgID))

        XCTAssertTrue(msg.contentParts.contains(where: { $0.thinkingContent != nil }),
                      "thinkingStarted must insert a .thinking placeholder into the message")
    }

    // MARK: - 8. thinkingFinalized clears the streaming flag

    func test_handleThinkingFinalized_clearsStreamingFlag() async {
        let coord = makeSilentCoordinator()
        let msgID = UUID()

        var capturedSets: [Set<UUID>] = []
        coord.onSetMessageIDsWithStreamingThinking = { capturedSets.append($0) }
        coord.mutateMessage = { _, _ in true }

        // Simulate: thinkingStarted (inserts into streamingThinkingIDs)
        // then thinkingFinalized (removes from it)
        await coord.handle(runtimeEvent: .thinkingStarted(messageID: msgID))
        await coord.handle(runtimeEvent: .thinkingFinalized(messageID: msgID, text: "answer", signature: nil))

        // The last set emitted must not contain msgID
        guard let last = capturedSets.last else {
            return XCTFail("Expected at least one call to onSetMessageIDsWithStreamingThinking")
        }
        XCTAssertFalse(last.contains(msgID), "Streaming flag must be cleared after thinkingFinalized")
    }

    // MARK: - 9. runPostGenerationTasks runs in order

    func test_runPostGenerationTasks_runsInOrder() async {
        let coord = makeSilentCoordinator()

        let order = ActorBox<[Int]>([])
        let tasks: [any PostGenerationTask] = [
            IndexCapturingTask(index: 1, box: order),
            IndexCapturingTask(index: 2, box: order),
            IndexCapturingTask(index: 3, box: order),
        ]
        coord.currentPostGenerationTasks = { tasks }
        coord.onSetBackgroundTaskError = { _ in }

        let msg = ChatMessageRecord(role: .assistant, content: "hi", sessionID: UUID())
        let session = ChatSessionRecord(title: "Test")

        coord.runPostGenerationTasks(message: msg, session: session)
        await coord.backgroundTask?.value

        let result = await order.value
        XCTAssertEqual(result, [1, 2, 3], "Tasks must run in registration order")
    }

    // MARK: - 10. cancelBackgroundTask stops running task

    func test_cancelBackgroundTask_stopsRunningTask() async {
        let coord = makeSilentCoordinator()

        let reached = ActorBox<Bool>(false)
        let slowTask = SlowPostTask(delay: .seconds(10), reached: reached)
        coord.currentPostGenerationTasks = { [slowTask] }
        coord.onSetBackgroundTaskError = { _ in }

        let msg = ChatMessageRecord(role: .assistant, content: "hi", sessionID: UUID())
        let session = ChatSessionRecord(title: "Test")

        coord.runPostGenerationTasks(message: msg, session: session)
        let inflight = coord.backgroundTask
        coord.cancelBackgroundTask()
        await inflight?.value

        XCTAssertNil(coord.backgroundTask, "backgroundTask must be nil after cancelBackgroundTask")
    }

    // MARK: - 11. awaitStreamCompletion resumes when handle clears

    func test_awaitStreamCompletion_resumesWhenHandleClears() async {
        let coord = makeSilentCoordinator()

        coord.activeConversationStreamHandle = ConversationStreamHandle(id: UUID())

        let awaiter = Task {
            await coord.awaitStreamCompletion()
        }

        // Clear the handle asynchronously.
        Task {
            await Task.yield()
            coord.activeConversationStreamHandle = nil
        }

        // If this hangs, the test times out (XCTest default timeout).
        await awaiter.value
        XCTAssertNil(coord.activeConversationStreamHandle)
    }

    // MARK: - 12. coordinator does not retain ChatViewModel

    func test_coordinatorDoesNotRetainChatViewModel() {
        // Construct a full VM and immediately release it — the coordinator's
        // closures must hold only `weak` references so the VM can deallocate.
        weak var weakVM: ChatViewModel?
        autoreleasepool {
            let vm = ChatViewModel()
            weakVM = vm
            // Access coordinator to ensure it's initialized.
            _ = vm.generationCoordinator
        }
        XCTAssertNil(weakVM, "ChatViewModel must deallocate when all strong references are dropped")
    }
}

// MARK: - Test Support

private actor ActorBox<T: Sendable> {
    var value: T
    init(_ initial: T) { value = initial }
    func append(_ element: Int) where T == [Int] { value.append(element) }
    func set(_ newValue: Bool) where T == Bool { value = newValue }
}

private final class IndexCapturingTask: PostGenerationTask, Sendable {
    let index: Int
    let box: ActorBox<[Int]>
    init(index: Int, box: ActorBox<[Int]>) { self.index = index; self.box = box }
    func run(message: ChatMessageRecord, session: ChatSessionRecord) async throws {
        await box.append(index)
    }
}

private final class SlowPostTask: PostGenerationTask, Sendable {
    let delay: Duration
    let reached: ActorBox<Bool>
    init(delay: Duration, reached: ActorBox<Bool>) { self.delay = delay; self.reached = reached }
    func run(message: ChatMessageRecord, session: ChatSessionRecord) async throws {
        try await Task.sleep(for: delay)
        await reached.set(true)
    }
}

/// Minimal in-memory store used to construct runtimes in these tests.
private final class InMemoryMessageStoreForTests: MessageStore, @unchecked Sendable {
    private var messages: [UUID: ChatMessageRecord] = [:]
    private var hooks: [any MessageStorePostWriteHook] = []

    func insertMessage(_ message: ChatMessageRecord) async throws {
        messages[message.id] = message
        for hook in hooks { await hook.messageDidWrite(message, in: message.sessionID) }
    }
    func updateMessage(_ message: ChatMessageRecord) async throws {
        messages[message.id] = message
        for hook in hooks { await hook.messageDidWrite(message, in: message.sessionID) }
    }
    func deleteMessage(_ messageID: UUID) async throws { messages.removeValue(forKey: messageID) }
    func fetchMessages(for sessionID: UUID) async throws -> [ChatMessageRecord] {
        messages.values.filter { $0.sessionID == sessionID }.sorted { $0.timestamp < $1.timestamp }
    }
    func deleteMessages(for sessionID: UUID) async throws {
        messages = messages.filter { $0.value.sessionID != sessionID }
    }
    func addPostWriteHook(_ hook: any MessageStorePostWriteHook) { hooks.append(hook) }
}
