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
        // Machine starts at .idle; idle → streaming is illegal (must go
        // through .waitingForFirstToken first), so the callback must not fire.
        var callbackCount = 0
        coord.onTransitionPhase = { _ in callbackCount += 1; return true }

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
        var msg = ChatMessage(id: msgID, role: .assistant, content: "Hello", sessionID: sessionID)
        msg.contentParts = [.text("Hello")]
        let session = ChatSession(id: sessionID, title: "Test")

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

    // MARK: - 4b. streamFinished(.stop) on a thinking-only message still completes

    /// A thinking-only turn (reasoning tokens, no visible text, no tool
    /// calls) must still reach `.completed` — the coordinator's own empty
    /// gate must not re-drop a message the runtime already decided was worth
    /// persisting. Regression coverage for the gap #2282 left open: the
    /// runtime's `ConversationTurnExecutor` gate was fixed to count thinking
    /// content, but this coordinator had its own duplicate
    /// `hasVisibleContent`-only gate at the `.streamFinished` completion path.
    func test_handleStreamFinished_stop_thinkingOnly_callsOnSetLastTurnStateCompleted() async {
        let coord = makeSilentCoordinator()
        let sessionID = UUID()
        let msgID = UUID()

        var states: [ChatViewModel.TurnState] = []
        coord.onSetLastTurnState = { states.append($0) }
        coord.onTransitionPhase = { _ in true }
        coord.currentActiveSessionID = { sessionID }

        // No visible text at all — only a finalized `.thinking` part.
        var msg = ChatMessage(id: msgID, role: .assistant, content: "", sessionID: sessionID)
        msg.contentParts = [.thinking("Let me consider this carefully.", signature: nil)]
        let session = ChatSession(id: sessionID, title: "Test")

        coord.currentMessages = { [msg] }
        coord.currentActiveSession = { session }
        coord.currentPostGenerationTasks = { [] }

        coord.activeConversationMessageID = msgID
        coord.activeConversationStreamHandle = ConversationStreamHandle(id: UUID())

        await coord.handle(runtimeEvent: .streamFinished(messageID: msgID, reason: .stop))

        XCTAssertTrue(
            states.contains(where: { if case .completed = $0 { return true }; return false }),
            "A thinking-only .stop must still complete the turn, got \(states)"
        )
        XCTAssertFalse(
            states.contains(where: { if case .idle = $0 { return true }; return false }),
            "A thinking-only .stop must not fall back to .idle, got \(states)"
        )
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
            [ChatMessage(id: msgID, role: .assistant, content: "", sessionID: sessionID)]
        }
        coord.currentActiveSession = { ChatSession(id: sessionID, title: "Test") }

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
        var msg = ChatMessage(id: msgID, role: .assistant, content: "", sessionID: sessionID)
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

        let msg = ChatMessage(role: .assistant, content: "hi", sessionID: UUID())
        let session = ChatSession(title: "Test")

        coord.runPostGenerationTasks(message: msg, session: session)
        await coord.backgroundTask?.value

        let result = await order.value
        XCTAssertEqual(result, [1, 2, 3], "Tasks must run in registration order")
    }

    // MARK: - 10. cancelBackgroundTask stops running task

    func test_cancelBackgroundTask_stopsRunningTask() async throws {
        let coord = makeSilentCoordinator()

        let reached = ActorBox<Bool>(false)
        let slowTask = SlowPostTask(delay: .seconds(10), reached: reached)
        coord.currentPostGenerationTasks = { [slowTask] }
        coord.onSetBackgroundTaskError = { _ in }

        let msg = ChatMessage(role: .assistant, content: "hi", sessionID: UUID())
        let session = ChatSession(title: "Test")

        coord.runPostGenerationTasks(message: msg, session: session)
        let inflight = coord.backgroundTask
        coord.cancelBackgroundTask()

        // Give cancellation time to propagate before awaiting the task — without
        // this yield the await can race with the CancellationError delivery.
        await Task.yield()

        // Bound the wait: if cancellation doesn't propagate the test fails rather
        // than hanging for the full 10-second SlowPostTask delay.
        let cancelExp = expectation(description: "inflight task completes after cancellation")
        Task {
            await inflight?.value
            cancelExp.fulfill()
        }
        await fulfillment(of: [cancelExp], timeout: 3)

        XCTAssertNil(coord.backgroundTask, "backgroundTask must be nil after cancelBackgroundTask")
    }

    // MARK: - 11. awaitStreamCompletion resumes when handle clears

    func test_awaitStreamCompletion_resumesWhenHandleClears() async {
        let coord = makeSilentCoordinator()
        let sessionID = UUID()
        let msgID = UUID()
        coord.onTransitionPhase = { _ in true }
        coord.currentActiveSessionID = { sessionID }
        coord.currentActiveSession = { ChatSession(id: sessionID, title: "Test") }
        coord.currentMessages = {
            [ChatMessage(id: msgID, role: .assistant, content: "hi", sessionID: sessionID)]
        }

        coord.activeConversationMessageID = msgID
        coord.activeConversationStreamHandle = ConversationStreamHandle(id: UUID())

        // Bound the wait so a regression that drops the continuation fails fast
        // instead of hanging the entire CI run.
        let exp = expectation(description: "awaitStreamCompletion returns")
        let awaiter = Task { @MainActor in
            await coord.awaitStreamCompletion()
            exp.fulfill()
        }

        // Let the awaiter park on its continuation, then clear the handle via
        // the real terminal path so the continuation-resume seam is exercised.
        await Task.yield()
        await coord.handle(runtimeEvent: .streamFinished(messageID: msgID, reason: .stop))

        await fulfillment(of: [exp], timeout: 2)
        _ = awaiter  // keep the task alive until the expectation is met
        XCTAssertNil(coord.activeConversationStreamHandle)
    }

    // MARK: - 11b. awaitStreamCompletion resumes all concurrent callers

    func test_awaitStreamCompletion_resumesAllConcurrentCallers() async {
        let coord = makeSilentCoordinator()
        let sessionID = UUID()
        let msgID = UUID()
        coord.onTransitionPhase = { _ in true }
        coord.currentActiveSessionID = { sessionID }
        coord.currentActiveSession = { ChatSession(id: sessionID, title: "Test") }
        coord.currentMessages = {
            [ChatMessage(id: msgID, role: .assistant, content: "hi", sessionID: sessionID)]
        }

        coord.activeConversationMessageID = msgID
        coord.activeConversationStreamHandle = ConversationStreamHandle(id: UUID())

        // Two callers park on the same handle concurrently. Both must resume
        // from a single terminal event — proves the waiter array drains fully,
        // not just the first parked continuation.
        let bothDone = expectation(description: "both awaitStreamCompletion calls return")
        let waiters = Task { @MainActor in
            async let first: Void = coord.awaitStreamCompletion()
            async let second: Void = coord.awaitStreamCompletion()
            _ = await (first, second)
            bothDone.fulfill()
        }

        // Let both callers park before clearing the handle through the real path.
        await Task.yield()
        await Task.yield()
        await coord.handle(runtimeEvent: .streamFinished(messageID: msgID, reason: .stop))

        await fulfillment(of: [bothDone], timeout: 2)
        _ = waiters
        XCTAssertNil(coord.activeConversationStreamHandle)
    }

    // MARK: - 12. streamFinished(.length) triggers upgrade hint

    func test_handleStreamFinished_length_triggersUpgradeHint() async {
        let coord = makeSilentCoordinator()
        let sessionID = UUID()
        let msgID = UUID()

        ManifoldConfiguration.shared.features = ManifoldConfiguration.Features(showUpgradeHint: true)
        defer { ManifoldConfiguration.shared.features = ManifoldConfiguration.Features() }

        var hintFired = false
        coord.setShowUpgradeHint = { if $0 { hintFired = true } }
        coord.onTransitionPhase = { _ in true }
        coord.currentActiveSessionID = { sessionID }

        var msg = ChatMessage(id: msgID, role: .assistant, content: "Truncated", sessionID: sessionID)
        msg.contentParts = [.text("Truncated")]
        coord.currentMessages = { [msg] }
        coord.currentActiveSession = { ChatSession(id: sessionID, title: "Test") }

        coord.activeConversationMessageID = msgID
        coord.activeConversationStreamHandle = ConversationStreamHandle(id: UUID())

        await coord.handle(runtimeEvent: .streamFinished(messageID: msgID, reason: .length))

        XCTAssertTrue(hintFired, "upgrade hint must fire when the backend hits its length cap")
    }

    func test_handleStreamFinished_stop_doesNotTriggerUpgradeHint() async {
        let coord = makeSilentCoordinator()
        let sessionID = UUID()
        let msgID = UUID()

        ManifoldConfiguration.shared.features = ManifoldConfiguration.Features(showUpgradeHint: true)
        defer { ManifoldConfiguration.shared.features = ManifoldConfiguration.Features() }

        var hintFired = false
        coord.setShowUpgradeHint = { if $0 { hintFired = true } }
        coord.onTransitionPhase = { _ in true }
        coord.currentActiveSessionID = { sessionID }

        var msg = ChatMessage(id: msgID, role: .assistant, content: "Done", sessionID: sessionID)
        msg.contentParts = [.text("Done")]
        coord.currentMessages = { [msg] }
        coord.currentActiveSession = { ChatSession(id: sessionID, title: "Test") }
        coord.currentPostGenerationTasks = { [] }

        coord.activeConversationMessageID = msgID
        coord.activeConversationStreamHandle = ConversationStreamHandle(id: UUID())

        await coord.handle(runtimeEvent: .streamFinished(messageID: msgID, reason: .stop))

        XCTAssertFalse(hintFired, "upgrade hint must NOT fire on a normal .stop completion")
    }

    // MARK: - 12b. AccessibilityAnnouncer wiring

    /// Records every `(text, priority)` posted through the injected
    /// `AccessibilityAnnouncer.post` seam — mirrors `AccessibilityAnnouncerTests`'s
    /// recorder so this suite can assert on the coordinator's real wiring
    /// rather than the announcer in isolation.
    private final class AnnouncementRecorder {
        private(set) var posts: [(text: String, priority: AccessibilityAnnouncer.Priority)] = []
        func record(_ text: String, _ priority: AccessibilityAnnouncer.Priority) {
            posts.append((text, priority))
        }
    }

    func test_tokenEmitted_thenStreamFinishedStop_postsAnnouncementOnCompletion() async {
        let coord = makeSilentCoordinator()
        let sessionID = UUID()
        let msgID = UUID()
        let recorder = AnnouncementRecorder()
        coord.accessibilityAnnouncer = AccessibilityAnnouncer(
            minimumInterval: .milliseconds(1),
            post: { recorder.record($0, $1) }
        )

        coord.onTransitionPhase = { _ in true }
        coord.currentActiveSessionID = { sessionID }
        var msg = ChatMessage(id: msgID, role: .assistant, content: "", sessionID: sessionID)
        coord.currentMessages = { [msg] }
        coord.mutateMessage = { id, mutation in
            guard id == msgID else { return false }
            mutation(&msg)
            return true
        }
        coord.currentActiveSession = { ChatSession(id: sessionID, title: "Test") }
        coord.currentPostGenerationTasks = { [] }

        await coord.handle(runtimeEvent: .streamStarted(messageID: msgID))
        await coord.handle(runtimeEvent: .tokenEmitted(messageID: msgID, delta: "Trailing partial with no boundary"))

        // Streaming path only queues completed sentences — with no sentence
        // boundary yet, nothing should have posted before the turn finishes.
        XCTAssertTrue(recorder.posts.isEmpty, "Partial sentence must not announce before finish")

        await coord.handle(runtimeEvent: .streamFinished(messageID: msgID, reason: .stop))

        XCTAssertEqual(recorder.posts.count, 1, "finish() must flush the trailing partial exactly once")
        XCTAssertEqual(recorder.posts.first?.priority, .high, "the terminal announcement must post at high priority")
        XCTAssertTrue(
            recorder.posts.first?.text.contains("Trailing partial") ?? false,
            "Got: \(recorder.posts.first?.text ?? "<nil>")"
        )
    }

    func test_tokenEmitted_rateLimitCoalescesBurstIntoSinglePost() async {
        let coord = makeSilentCoordinator()
        let sessionID = UUID()
        let msgID = UUID()
        let recorder = AnnouncementRecorder()
        // A long window so every sentence completed inside it coalesces into
        // one post instead of one-per-sentence.
        coord.accessibilityAnnouncer = AccessibilityAnnouncer(
            minimumInterval: .seconds(10),
            post: { recorder.record($0, $1) }
        )

        coord.onTransitionPhase = { _ in true }
        coord.currentActiveSessionID = { sessionID }
        var msg = ChatMessage(id: msgID, role: .assistant, content: "", sessionID: sessionID)
        coord.currentMessages = { [msg] }
        coord.mutateMessage = { id, mutation in
            guard id == msgID else { return false }
            mutation(&msg)
            return true
        }
        coord.currentActiveSession = { ChatSession(id: sessionID, title: "Test") }
        coord.currentPostGenerationTasks = { [] }

        await coord.handle(runtimeEvent: .streamStarted(messageID: msgID))
        // "One." confirms complete once "Two" starts — the first drain post
        // fires immediately, opening the 10s rate-limit window.
        await coord.handle(runtimeEvent: .tokenEmitted(messageID: msgID, delta: "One. Two"))

        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while recorder.posts.count < 1, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(recorder.posts.count, 1)

        // A burst of further completed sentences must coalesce into a single
        // follow-up post at finish(), not one per sentence.
        await coord.handle(runtimeEvent: .tokenEmitted(messageID: msgID, delta: ". Three. Four. five"))
        await coord.handle(runtimeEvent: .streamFinished(messageID: msgID, reason: .stop))

        XCTAssertEqual(recorder.posts.count, 2, "burst held by the open rate-limit window must coalesce into one post")
        guard recorder.posts.count >= 2 else { return }
        XCTAssertTrue(recorder.posts[1].text.contains("Two"), "Got: \(recorder.posts[1].text)")
        XCTAssertTrue(recorder.posts[1].text.contains("Three"), "Got: \(recorder.posts[1].text)")
    }

    func test_fallbackTerminalPath_awaitTurnCompletion_postsAnnouncement() async {
        // Covers the coordinator's SECOND terminal path: when the event drain
        // is delayed past awaitTurnCompletion's 250ms window (here: no drain
        // running at all), applyTerminalOutcome is the only terminal handler —
        // it must flush the announcer, or the final announcement is silently
        // lost in that race.
        let coord = makeSilentCoordinator()
        let sessionID = UUID()
        let msgID = UUID()
        let recorder = AnnouncementRecorder()
        coord.accessibilityAnnouncer = AccessibilityAnnouncer(
            minimumInterval: .milliseconds(1),
            post: { recorder.record($0, $1) }
        )

        coord.onTransitionPhase = { _ in true }
        coord.currentActiveSessionID = { sessionID }
        var msg = ChatMessage(id: msgID, role: .assistant, content: "", sessionID: sessionID)
        coord.currentMessages = { [msg] }
        coord.mutateMessage = { id, mutation in
            guard id == msgID else { return false }
            mutation(&msg)
            return true
        }
        coord.currentActiveSession = { ChatSession(id: sessionID, title: "Test") }
        coord.currentPostGenerationTasks = { [] }

        await coord.handle(runtimeEvent: .streamStarted(messageID: msgID))
        await coord.handle(runtimeEvent: .tokenEmitted(messageID: msgID, delta: "Fallback partial with no boundary"))
        XCTAssertTrue(recorder.posts.isEmpty, "Partial sentence must not announce before the terminal outcome")

        // Deliver the terminal outcome ONLY through applyTerminalOutcome — no
        // .streamFinished event ever reaches handle(runtimeEvent:), exactly
        // the delayed-drain race the fallback exists for. (Driven directly
        // rather than through awaitTurnCompletion because a test cannot mint
        // a ConversationTurnHandle — its completion actor's initializer is
        // internal to ManifoldRuntime.)
        let streamHandle = ConversationStreamHandle(id: UUID())
        coord.activeConversationStreamHandle = streamHandle
        coord.applyTerminalOutcome(ConversationTurnOutcome(
            sessionID: sessionID,
            streamHandle: streamHandle,
            assistantMessageID: msgID,
            assistantMessage: msg,
            reason: .stop,
            error: nil,
            finalText: "Fallback partial with no boundary",
            promptTokens: nil,
            completionTokens: nil
        ))

        XCTAssertEqual(recorder.posts.count, 1, "the fallback terminal path must flush the trailing partial")
        XCTAssertEqual(recorder.posts.first?.priority, .high)
        XCTAssertTrue(
            recorder.posts.first?.text.contains("Fallback partial") ?? false,
            "Got: \(recorder.posts.first?.text ?? "<nil>")"
        )
    }

    // MARK: - 12c. applyTerminalOutcome (non-streaming/fallback path) on a thinking-only message

    /// Same regression as 4b, but for the coordinator's SECOND completion
    /// gate — `applyTerminalOutcome`, the non-streaming outcome path shared
    /// by the fallback-drain race (see test 12b) and by regenerate/edit/
    /// branch turns that terminate via `ConversationTurnOutcome` rather than
    /// a drained `.streamFinished` event. Before this fix this path also
    /// only checked `hasVisibleContent`, so a thinking-only outcome would
    /// fall back to `.idle` even though the message was already persisted.
    func test_applyTerminalOutcome_thinkingOnly_setsLastTurnStateCompleted() {
        let coord = makeSilentCoordinator()
        let sessionID = UUID()
        let msgID = UUID()

        var states: [ChatViewModel.TurnState] = []
        coord.onSetLastTurnState = { states.append($0) }
        coord.currentActiveSessionID = { sessionID }
        coord.currentActiveSession = { ChatSession(id: sessionID, title: "Test") }
        coord.currentPostGenerationTasks = { [] }

        var msg = ChatMessage(id: msgID, role: .assistant, content: "", sessionID: sessionID)
        msg.contentParts = [.thinking("Let me consider this carefully.", signature: nil)]
        coord.currentMessages = { [msg] }

        let streamHandle = ConversationStreamHandle(id: UUID())
        coord.activeConversationStreamHandle = streamHandle
        coord.applyTerminalOutcome(ConversationTurnOutcome(
            sessionID: sessionID,
            streamHandle: streamHandle,
            assistantMessageID: msgID,
            assistantMessage: msg,
            reason: .stop,
            error: nil,
            finalText: "",
            promptTokens: nil,
            completionTokens: nil
        ))

        XCTAssertTrue(
            states.contains(where: { if case .completed = $0 { return true }; return false }),
            "A thinking-only outcome must still complete the turn, got \(states)"
        )
        XCTAssertFalse(
            states.contains(where: { if case .idle = $0 { return true }; return false }),
            "A thinking-only outcome must not fall back to .idle, got \(states)"
        )
    }

    func test_streamFinished_cancelled_suppressesAnnouncement() async {
        let coord = makeSilentCoordinator()
        let sessionID = UUID()
        let msgID = UUID()
        let recorder = AnnouncementRecorder()
        coord.accessibilityAnnouncer = AccessibilityAnnouncer(
            minimumInterval: .milliseconds(1),
            post: { recorder.record($0, $1) }
        )

        coord.onTransitionPhase = { _ in true }
        coord.currentActiveSessionID = { sessionID }
        var msg = ChatMessage(id: msgID, role: .assistant, content: "", sessionID: sessionID)
        coord.currentMessages = { [msg] }
        coord.mutateMessage = { id, mutation in
            guard id == msgID else { return false }
            mutation(&msg)
            return true
        }
        coord.currentActiveSession = { ChatSession(id: sessionID, title: "Test") }

        await coord.handle(runtimeEvent: .streamStarted(messageID: msgID))
        await coord.handle(runtimeEvent: .tokenEmitted(messageID: msgID, delta: "Buffered text with no boundary"))
        await coord.handle(runtimeEvent: .streamFinished(messageID: msgID, reason: .cancelled))

        XCTAssertTrue(recorder.posts.isEmpty, "a cancelled turn must not announce buffered text")
    }

    // MARK: - 13. coordinator does not retain ChatViewModel

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
    func run(message: ChatMessage, session: ChatSession) async throws {
        await box.append(index)
    }
}

private final class SlowPostTask: PostGenerationTask, Sendable {
    let delay: Duration
    let reached: ActorBox<Bool>
    init(delay: Duration, reached: ActorBox<Bool>) { self.delay = delay; self.reached = reached }
    func run(message: ChatMessage, session: ChatSession) async throws {
        try await Task.sleep(for: delay)
        await reached.set(true)
    }
}

/// Minimal in-memory store used to construct runtimes in these tests.
private final class InMemoryMessageStoreForTests: MessageStore, @unchecked Sendable {
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
