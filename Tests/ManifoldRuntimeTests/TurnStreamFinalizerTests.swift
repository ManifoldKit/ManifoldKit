@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference

// MARK: - Fakes

/// In-memory ``TurnPersistencePort`` for finalizer unit tests — no SwiftData,
/// no ConversationRuntime. The acceptance criterion for #1957 Priority 3 is
/// that a finalization edge case is testable with a struct literal + narrow
/// fakes instead of the full runtime stack.
actor FakeTurnPersistence: TurnPersistencePort {
    private(set) var inserted: [ChatMessage] = []
    var insertError: Error?
    private(set) var touchCount = 0

    func insertMessage(_ message: ChatMessage) async throws {
        if let insertError { throw insertError }
        inserted.append(message)
    }

    func fetchHealedMessages(sessionID: UUID) async throws -> [ChatMessage] { [] }
    func fetchSession(sessionID: UUID) async -> ChatSession? { nil }
    func setActiveAgent(sessionID: UUID, agentID: UUID?) async -> Bool { true }

    // Optional gate so a test can suspend `touchSession` mid-flight and
    // observe runtime state while a post-turn effect is still running (#2329
    // ordering tripwire). Off by default — unrelated tests are unaffected.
    private var gateArmed = false
    private var entered = false
    private var parkContinuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?

    func armTouchGate() { gateArmed = true }

    /// Resumes once `touchSession` has been entered (and, when armed, parked).
    func awaitTouchEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    /// Releases a parked `touchSession` so `finalize` can proceed.
    func releaseTouch() {
        parkContinuation?.resume()
        parkContinuation = nil
    }

    func touchSession(sessionID: UUID) async -> Bool {
        touchCount += 1
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        if gateArmed {
            await withCheckedContinuation { parkContinuation = $0 }
        }
        return true
    }

    func snapshotInserted() -> [ChatMessage] { inserted }
    func snapshotTouchCount() -> Int { touchCount }
    func setInsertError(_ error: Error?) { insertError = error }
}

enum FakePersistError: Error, LocalizedError {
    case boom
    var errorDescription: String? { "boom" }
}

/// Minimal ``MessageStore`` so ``TurnCompressionCoordinator`` can be
/// constructed. Compression policies are nil in these tests, so the store is
/// never exercised on the happy path beyond construction.
@MainActor
private final class NoopMessageStore: MessageStore {
    func insertMessage(_ message: ChatMessage) async throws { throw FakePersistError.boom }
    func updateMessage(_ message: ChatMessage) async throws { throw FakePersistError.boom }
    func deleteMessage(_ messageID: UUID) async throws { throw FakePersistError.boom }
    func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] { [] }
    func deleteMessages(for sessionID: UUID) async throws {}
}

// MARK: - Tests

/// Direct unit coverage of ``TurnStreamFinalizer/finalize(_:)`` — the single
/// path that replaced the three hand-rolled branches (stream-failed /
/// cancelled / happy-path). No mock backend, no ConversationRuntime.
@MainActor
final class TurnStreamFinalizerTests: XCTestCase {

    private var persistence: FakeTurnPersistence!
    private var eventsBox: EventBox!
    private var emptyBox: DiagnosticBox!
    private var finalizer: TurnStreamFinalizer!

    /// Thread-safe event collector (finalizer emits off the test's actor).
    final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ConversationEvent] = []
        func append(_ e: ConversationEvent) {
            lock.lock(); defer { lock.unlock() }
            items.append(e)
        }
        var snapshot: [ConversationEvent] {
            lock.lock(); defer { lock.unlock() }
            return items
        }
    }

    final class DiagnosticBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ConversationRuntime.EmptyResponseDiagnostic] = []
        func append(_ d: ConversationRuntime.EmptyResponseDiagnostic) {
            lock.lock(); defer { lock.unlock() }
            items.append(d)
        }
        var snapshot: [ConversationRuntime.EmptyResponseDiagnostic] {
            lock.lock(); defer { lock.unlock() }
            return items
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        persistence = FakeTurnPersistence()
        eventsBox = EventBox()
        emptyBox = DiagnosticBox()
        let inference = InferenceService()
        let registry = InFlightStreamRegistry()
        let eventsBox = self.eventsBox!
        let emptyBox = self.emptyBox!
        let eventsEmitter = TurnEventEmitter { event in
            eventsBox.append(event)
        }
        let compression = TurnCompressionCoordinator(
            persistence: ConversationPersistencePort(
                messageStore: NoopMessageStore(),
                sessionStore: nil
            ),
            inferenceService: inference,
            events: eventsEmitter,
            preTurnPolicy: nil,
            postTurnPolicy: nil
        )
        finalizer = TurnStreamFinalizer(
            persistence: persistence,
            inferenceService: inference,
            registry: registry,
            events: eventsEmitter,
            emptyResponseObserver: { d in emptyBox.append(d) },
            generationHooks: [],
            compression: compression,
            usageStore: nil,
            hookTimeout: .seconds(1),
            toolDispatch: SessionToolDispatchBinder(inferenceService: inference)
        )
    }

    override func tearDown() async throws {
        finalizer = nil
        persistence = nil
        eventsBox = nil
        emptyBox = nil
        try await super.tearDown()
    }

    // MARK: Helpers

    private func makeInput(
        kind: TurnStreamFinalizer.TerminalKind,
        visibleText: String = "hello",
        hasToolContent: Bool = false,
        hasThinkingContent: Bool = false,
        contentParts: [MessagePart] = [],
        outcomeCompletion: ConversationTurnOutcomeCompletion? = nil
    ) -> TurnStreamFinalizer.FinalizeInput {
        let sessionID = UUID()
        var message = ChatMessage(role: .assistant, content: "", sessionID: sessionID)
        if !contentParts.isEmpty {
            message.contentParts = contentParts
        }
        return TurnStreamFinalizer.FinalizeInput(
            sessionID: sessionID,
            handle: ConversationStreamHandle(),
            assistantMessage: message,
            visibleText: visibleText,
            hasToolContent: hasToolContent,
            hasThinkingContent: hasThinkingContent,
            usage: (10, 5, nil, nil),
            kind: kind,
            turnContext: TurnContext(sessionID: sessionID, messageCount: 1),
            outcomeCompletion: outcomeCompletion
        )
    }

    private func finalizeAndCaptureOutcome(
        _ input: TurnStreamFinalizer.FinalizeInput
    ) async -> (TurnStreamFinalizer.FinalizeResult, ConversationTurnOutcome) {
        let completion = input.outcomeCompletion ?? ConversationTurnOutcomeCompletion()
        var pinned = input
        pinned.outcomeCompletion = completion
        let result = await finalizer.finalize(pinned)
        let outcome = await completion.value()
        return (result, outcome)
    }

    private func finishReasons() -> [FinishReason] {
        eventsBox.snapshot.compactMap {
            if case .streamFinished(_, let reason) = $0 { return reason }
            return nil
        }
    }

    private func hasAfterGeneration() -> Bool {
        eventsBox.snapshot.contains {
            if case .afterGeneration = $0 { return true }
            return false
        }
    }

    private func raisedErrors() -> [ConversationError] {
        eventsBox.snapshot.compactMap {
            if case .errorRaised(let err) = $0 { return err }
            return nil
        }
    }

    // MARK: Happy path

    func test_finalize_completed_persists_emitsAfterGeneration_touchesSession() async throws {
        let input = makeInput(kind: .completed, visibleText: "hi there")
        let result = await finalizer.finalize(input)

        XCTAssertEqual(result.reason, .stop)
        XCTAssertTrue(result.didPersist)
        XCTAssertNil(result.persistenceError)
        XCTAssertEqual(result.assistantMessage?.contentParts.compactMap(\.textContent).joined(), "hi there")

        let inserted = await persistence.snapshotInserted()
        XCTAssertEqual(inserted.count, 1)
        let touchCount = await persistence.snapshotTouchCount()
        XCTAssertEqual(touchCount, 1)

        XCTAssertEqual(finishReasons(), [.stop])
        XCTAssertTrue(hasAfterGeneration(), "happy path must emit afterGeneration")
        XCTAssertTrue(raisedErrors().isEmpty)
    }

    /// #2329 tripwire: `finalize` must run post-turn effects (touchSession,
    /// which fetches the SwiftData store) to completion *before* it resolves
    /// the awaited `handle.outcome`. Otherwise a caller that awaits the outcome
    /// and then releases its `ModelContainer` — exactly what the runtime's
    /// in-memory integration tests do at teardown — leaves touchSession racing
    /// the store's dealloc (SIGTRAP in fetchSwiftDataSession vs NSSQLCore
    /// dealloc, only under `swift test --parallel`).
    ///
    /// Falsifiability: with the pre-fix order (completeOutcome before
    /// post-turn effects) the outcome is already resolved by the time
    /// touchSession is even entered, so `isCompleted` below is `true` while
    /// touch is parked and the assertion fails.
    func test_finalize_completed_settlesPostTurnEffectsBeforeResolvingOutcome() async throws {
        let completion = ConversationTurnOutcomeCompletion()
        await persistence.armTouchGate()

        let input = makeInput(kind: .completed, outcomeCompletion: completion)
        let task = Task { await finalizer.finalize(input) }

        // touchSession has been entered and is now parked inside runPostTurnEffects.
        await persistence.awaitTouchEntered()

        let resolvedWhilePostEffectsRunning = await completion.isCompleted
        XCTAssertFalse(
            resolvedWhilePostEffectsRunning,
            "outcome resolved before post-turn effects finished — a caller releasing its store on `await outcome` would race touchSession (#2329)"
        )

        await persistence.releaseTouch()
        _ = await task.value

        let resolvedAfterSettle = await completion.isCompleted
        XCTAssertTrue(resolvedAfterSettle, "outcome must resolve once the turn is settled")
        let finalTouchCount = await persistence.snapshotTouchCount()
        XCTAssertEqual(finalTouchCount, 1)
    }

    // MARK: Empty path

    func test_finalize_empty_dropsMessage_emitsAfterGeneration_noTouch() async {
        let input = makeInput(kind: .empty, visibleText: "")
        let result = await finalizer.finalize(input)

        XCTAssertEqual(result.reason, .empty)
        XCTAssertFalse(result.didPersist)
        XCTAssertNil(result.assistantMessage)

        let inserted = await persistence.snapshotInserted()
        XCTAssertTrue(inserted.isEmpty)
        let touchCount = await persistence.snapshotTouchCount()
        XCTAssertEqual(touchCount, 0)

        XCTAssertEqual(finishReasons(), [.empty])
        XCTAssertTrue(hasAfterGeneration(), "empty path emits afterGeneration(\"\")")
        XCTAssertEqual(emptyBox.snapshot.count, 1)
        XCTAssertEqual(emptyBox.snapshot[0].sessionID, input.sessionID)
    }

    // MARK: Cancelled path

    func test_finalize_cancelled_withContent_persists_noAfterGeneration() async {
        let input = makeInput(kind: .cancelled, visibleText: "partial")
        let result = await finalizer.finalize(input)

        XCTAssertEqual(result.reason, .cancelled)
        XCTAssertTrue(result.didPersist)
        let touchCount = await persistence.snapshotTouchCount()
        XCTAssertEqual(touchCount, 0, "cancel must not run post-turn effects")
        XCTAssertEqual(finishReasons(), [.cancelled])
        XCTAssertFalse(hasAfterGeneration(), "cancel must not emit afterGeneration")
    }

    func test_finalize_cancelled_empty_doesNotPersist() async {
        let input = makeInput(kind: .cancelled, visibleText: "")
        let result = await finalizer.finalize(input)

        XCTAssertEqual(result.reason, .cancelled)
        XCTAssertFalse(result.didPersist)
        let inserted = await persistence.snapshotInserted()
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertEqual(finishReasons(), [.cancelled])
    }

    func test_finalize_cancelled_persistFailure_stillEmitsStreamFinished() async {
        await persistence.setInsertError(FakePersistError.boom)
        let input = makeInput(kind: .cancelled, visibleText: "partial")
        let result = await finalizer.finalize(input)

        XCTAssertEqual(result.reason, .cancelled)
        XCTAssertFalse(result.didPersist)
        XCTAssertNotNil(result.persistenceError)
        // Cancel falls through: streamFinished still fires even when the
        // partial save failed (parity with the pre-split branch).
        XCTAssertEqual(finishReasons(), [.cancelled])
        XCTAssertFalse(hasAfterGeneration())
        XCTAssertEqual(raisedErrors().count, 1)
        if case .persistence = raisedErrors()[0] {
            // expected
        } else {
            XCTFail("expected persistence error, got \(raisedErrors()[0])")
        }
    }

    /// Cancel + content + insert failure must still surface the in-memory
    /// assistant message on the outcome (pre-split parity). `didPersist`
    /// stays false; classification stays `.cancelled`, not `.cancelledEmpty`.
    func test_finalize_cancelled_persistFailure_stillPassesAssistantMessageOnOutcome() async {
        await persistence.setInsertError(FakePersistError.boom)
        let input = makeInput(kind: .cancelled, visibleText: "partial")
        let (result, outcome) = await finalizeAndCaptureOutcome(input)

        XCTAssertEqual(result.reason, .cancelled)
        XCTAssertFalse(result.didPersist, "insert failed — didPersist must stay false")
        XCTAssertNotNil(result.persistenceError)
        XCTAssertNotNil(result.assistantMessage, "in-memory message must still be returned")
        XCTAssertEqual(
            result.assistantMessage?.contentParts.compactMap(\.textContent).joined(),
            "partial"
        )

        XCTAssertEqual(outcome.reason, .cancelled)
        XCTAssertNil(outcome.error, "cancel outcome error stays nil even when partial save failed")
        XCTAssertEqual(outcome.finalText, "partial")
        XCTAssertNotNil(outcome.assistantMessage, "outcome must carry in-memory message for coordinator/driver fallbacks")
        XCTAssertEqual(outcome.assistantMessage?.id, input.assistantMessage.id)
        XCTAssertEqual(outcome.classification, .cancelled)
    }

    /// Tool-only cancel with empty visible text + persist failure: without the
    /// in-memory assistantMessage, classification would flip to cancelledEmpty
    /// because finalText is empty.
    func test_finalize_cancelled_toolOnly_persistFailure_notCancelledEmpty() async {
        await persistence.setInsertError(FakePersistError.boom)
        let call = ToolCall(id: "c1", toolName: "search", arguments: "{}")
        let input = makeInput(
            kind: .cancelled,
            visibleText: "",
            hasToolContent: true,
            contentParts: [.toolCall(call)]
        )
        let (result, outcome) = await finalizeAndCaptureOutcome(input)

        XCTAssertFalse(result.didPersist)
        XCTAssertNotNil(result.assistantMessage)
        XCTAssertEqual(outcome.finalText, "")
        XCTAssertNotNil(outcome.assistantMessage)
        XCTAssertEqual(
            outcome.classification,
            .cancelled,
            "tool-only cancel + persist fail must not classify as cancelledEmpty"
        )
        XCTAssertTrue(outcome.assistantMessage?.contentParts.contains {
            if case .toolCall = $0 { return true }
            return false
        } ?? false)
    }

    /// Thinking-only cancel + persist fail: same cancelledEmpty trap via
    /// empty finalText when assistantMessage is dropped.
    func test_finalize_cancelled_thinkingOnly_persistFailure_notCancelledEmpty() async {
        await persistence.setInsertError(FakePersistError.boom)
        let input = makeInput(
            kind: .cancelled,
            visibleText: "",
            hasThinkingContent: true,
            contentParts: [.thinking("hmm", signature: nil)]
        )
        let (result, outcome) = await finalizeAndCaptureOutcome(input)

        XCTAssertFalse(result.didPersist)
        XCTAssertNotNil(outcome.assistantMessage)
        XCTAssertEqual(outcome.classification, .cancelled)
    }

    // MARK: Outcome completion matrix

    /// Pins reason / error / assistantMessage presence for each terminal kind
    /// through ``outcomeCompletion`` — the surface consumers actually read.
    func test_finalize_outcomeCompletion_matrix() async {
        let streamError = ConversationError.inference(FakePersistError.boom)

        // completed → stop, no error, message present
        do {
            let (_, outcome) = await finalizeAndCaptureOutcome(
                makeInput(kind: .completed, visibleText: "done")
            )
            XCTAssertEqual(outcome.reason, .stop)
            XCTAssertNil(outcome.error)
            XCTAssertNotNil(outcome.assistantMessage)
            XCTAssertEqual(outcome.finalText, "done")
            XCTAssertEqual(outcome.classification, .completed)
        }

        // empty → empty, no error, no message
        do {
            eventsBox = EventBox()
            emptyBox = DiagnosticBox()
            // Rebuild finalizer so empty observer still works after box swap
            // is unnecessary — empty path only needs outcome. Fresh boxes
            // avoid cross-case pollution of event assertions elsewhere.
            let (_, outcome) = await finalizeAndCaptureOutcome(
                makeInput(kind: .empty, visibleText: "")
            )
            XCTAssertEqual(outcome.reason, .empty)
            XCTAssertNil(outcome.error)
            XCTAssertNil(outcome.assistantMessage)
            XCTAssertEqual(outcome.finalText, "")
            XCTAssertEqual(outcome.classification, .completed)
        }

        // failed (content) → stop + stream error + message
        do {
            let (_, outcome) = await finalizeAndCaptureOutcome(
                makeInput(
                    kind: .failed(error: streamError, timedOut: false),
                    visibleText: "partial"
                )
            )
            XCTAssertEqual(outcome.reason, .stop)
            XCTAssertNotNil(outcome.error)
            XCTAssertNotNil(outcome.assistantMessage)
            XCTAssertEqual(outcome.classification, .failed)
        }

        // timedOut → timedOut + error + message
        do {
            let timedOut = ConversationError.inference(InferenceError.idleTimeout(.seconds(5)))
            let (_, outcome) = await finalizeAndCaptureOutcome(
                makeInput(
                    kind: .failed(error: timedOut, timedOut: true),
                    visibleText: "stalled"
                )
            )
            XCTAssertEqual(outcome.reason, .timedOut)
            XCTAssertNotNil(outcome.error)
            XCTAssertNotNil(outcome.assistantMessage)
            XCTAssertEqual(outcome.classification, .timedOut)
        }

        // cancel + content → cancelled, no error, message present
        do {
            let (_, outcome) = await finalizeAndCaptureOutcome(
                makeInput(kind: .cancelled, visibleText: "partial")
            )
            XCTAssertEqual(outcome.reason, .cancelled)
            XCTAssertNil(outcome.error)
            XCTAssertNotNil(outcome.assistantMessage)
            XCTAssertEqual(outcome.classification, .cancelled)
        }

        // cancel + no content → cancelled, no error, no message → cancelledEmpty
        do {
            let (_, outcome) = await finalizeAndCaptureOutcome(
                makeInput(kind: .cancelled, visibleText: "")
            )
            XCTAssertEqual(outcome.reason, .cancelled)
            XCTAssertNil(outcome.error)
            XCTAssertNil(outcome.assistantMessage)
            XCTAssertEqual(outcome.finalText, "")
            XCTAssertEqual(outcome.classification, .cancelledEmpty)
        }

        // cancel + content + persist fail → cancelled, no error, in-memory message
        do {
            await persistence.setInsertError(FakePersistError.boom)
            let (result, outcome) = await finalizeAndCaptureOutcome(
                makeInput(kind: .cancelled, visibleText: "partial")
            )
            await persistence.setInsertError(nil)
            XCTAssertFalse(result.didPersist)
            XCTAssertEqual(outcome.reason, .cancelled)
            XCTAssertNil(outcome.error)
            XCTAssertNotNil(outcome.assistantMessage)
            XCTAssertEqual(outcome.classification, .cancelled)
        }
    }

    // MARK: Failed path

    func test_finalize_failed_withContent_persists_emitsError_noAfterGeneration() async {
        let streamError = ConversationError.inference(FakePersistError.boom)
        let input = makeInput(
            kind: .failed(error: streamError, timedOut: false),
            visibleText: "partial answer"
        )
        let result = await finalizer.finalize(input)

        XCTAssertEqual(result.reason, .stop)
        XCTAssertTrue(result.didPersist)
        let touchCount = await persistence.snapshotTouchCount()
        XCTAssertEqual(touchCount, 0)
        XCTAssertEqual(finishReasons(), [.stop])
        XCTAssertFalse(hasAfterGeneration())

        let errors = raisedErrors()
        XCTAssertEqual(errors.count, 1)
        if case .inference = errors[0] {
            // expected
        } else {
            XCTFail("expected inference error, got \(errors[0])")
        }
    }

    func test_finalize_failed_timedOut_reportsTimedOutReason() async {
        let streamError = ConversationError.inference(InferenceError.idleTimeout(.seconds(5)))
        let input = makeInput(
            kind: .failed(error: streamError, timedOut: true),
            visibleText: "stalled"
        )
        let result = await finalizer.finalize(input)

        XCTAssertEqual(result.reason, .timedOut)
        XCTAssertTrue(result.didPersist)
        XCTAssertEqual(finishReasons(), [.timedOut])
    }

    func test_finalize_failed_persistFailure_isFatal_emitsBothErrors() async {
        await persistence.setInsertError(FakePersistError.boom)
        let streamError = ConversationError.inference(FakePersistError.boom)
        let input = makeInput(
            kind: .failed(error: streamError, timedOut: false),
            visibleText: "partial"
        )
        let result = await finalizer.finalize(input)

        XCTAssertEqual(result.reason, .stop)
        XCTAssertFalse(result.didPersist)
        XCTAssertNotNil(result.persistenceError)
        XCTAssertEqual(finishReasons(), [.stop])
        XCTAssertFalse(hasAfterGeneration())

        // Fatal persist failure emits persistence error THEN stream error.
        let errors = raisedErrors()
        XCTAssertEqual(errors.count, 2)
        if case .persistence = errors[0] {} else {
            XCTFail("first error should be persistence, got \(errors[0])")
        }
        if case .inference = errors[1] {} else {
            XCTFail("second error should be stream inference, got \(errors[1])")
        }
    }

    func test_finalize_failed_noContent_skipsPersist_stillEmitsError() async {
        let streamError = ConversationError.inference(FakePersistError.boom)
        let input = makeInput(
            kind: .failed(error: streamError, timedOut: false),
            visibleText: ""
        )
        let result = await finalizer.finalize(input)

        XCTAssertFalse(result.didPersist)
        let inserted = await persistence.snapshotInserted()
        XCTAssertTrue(inserted.isEmpty)
        XCTAssertEqual(finishReasons(), [.stop])
        XCTAssertEqual(raisedErrors().count, 1)
    }

    // MARK: Tool-only / thinking-only content gates

    func test_finalize_cancelled_toolOnly_persists() async {
        let call = ToolCall(id: "c1", toolName: "search", arguments: "{}")
        let input = makeInput(
            kind: .cancelled,
            visibleText: "",
            hasToolContent: true,
            contentParts: [.toolCall(call)]
        )
        let result = await finalizer.finalize(input)

        XCTAssertTrue(result.didPersist)
        let inserted = await persistence.snapshotInserted()
        XCTAssertEqual(inserted.count, 1)
        XCTAssertTrue(inserted[0].contentParts.contains {
            if case .toolCall = $0 { return true }
            return false
        })
    }

    func test_finalize_failed_thinkingOnly_persists() async {
        let streamError = ConversationError.inference(FakePersistError.boom)
        let input = makeInput(
            kind: .failed(error: streamError, timedOut: false),
            visibleText: "",
            hasThinkingContent: true,
            contentParts: [.thinking("hmm", signature: nil)]
        )
        let result = await finalizer.finalize(input)

        XCTAssertTrue(result.didPersist)
        let inserted = await persistence.snapshotInserted()
        XCTAssertEqual(inserted.count, 1)
    }

    // MARK: TerminalKind taxonomy

    func test_terminalKind_finishReasons() {
        let err = ConversationError.inference(FakePersistError.boom)
        XCTAssertEqual(TurnStreamFinalizer.TerminalKind.completed.finishReason, .stop)
        XCTAssertEqual(TurnStreamFinalizer.TerminalKind.cancelled.finishReason, .cancelled)
        XCTAssertEqual(TurnStreamFinalizer.TerminalKind.empty.finishReason, .empty)
        XCTAssertEqual(TurnStreamFinalizer.TerminalKind.failed(error: err, timedOut: false).finishReason, .stop)
        XCTAssertEqual(TurnStreamFinalizer.TerminalKind.failed(error: err, timedOut: true).finishReason, .timedOut)
    }

    func test_terminalKind_postTurnEffectsOnlyOnCompleted() {
        let err = ConversationError.inference(FakePersistError.boom)
        XCTAssertTrue(TurnStreamFinalizer.TerminalKind.completed.runsPostTurnEffects)
        XCTAssertFalse(TurnStreamFinalizer.TerminalKind.cancelled.runsPostTurnEffects)
        XCTAssertFalse(TurnStreamFinalizer.TerminalKind.empty.runsPostTurnEffects)
        XCTAssertFalse(TurnStreamFinalizer.TerminalKind.failed(error: err, timedOut: false).runsPostTurnEffects)
    }

    func test_terminalKind_persistFailureFatalOnlyOnFailedAndCompleted() {
        let err = ConversationError.inference(FakePersistError.boom)
        XCTAssertTrue(TurnStreamFinalizer.TerminalKind.completed.persistFailureIsFatal)
        XCTAssertTrue(TurnStreamFinalizer.TerminalKind.failed(error: err, timedOut: false).persistFailureIsFatal)
        XCTAssertFalse(TurnStreamFinalizer.TerminalKind.cancelled.persistFailureIsFatal)
        XCTAssertFalse(TurnStreamFinalizer.TerminalKind.empty.persistFailureIsFatal)
    }
}
