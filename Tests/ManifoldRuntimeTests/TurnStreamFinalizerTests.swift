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

    func touchSession(sessionID: UUID) async -> Bool {
        touchCount += 1
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
        contentParts: [MessagePart] = []
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
            turnContext: TurnContext(sessionID: sessionID, messageCount: 1)
        )
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
