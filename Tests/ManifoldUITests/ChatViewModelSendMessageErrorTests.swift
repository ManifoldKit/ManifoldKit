@preconcurrency import XCTest
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport
import ManifoldPersistenceTestSupport

/// I6 replaces ``NoResponseError`` with the typed ``SendMessageError`` enum so
/// callers can pattern-match each upstream failure mode of the async
/// ``ChatViewModel/sendMessage(_:)`` overload. These tests pin one
/// representative case per arm of the enum.
@MainActor
final class ChatViewModelSendMessageErrorTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var sessionManager: SessionManagerViewModel!

    override func setUp() async throws {
        try await super.setUp()
        container = try makeInMemoryContainer()
        context = container.mainContext
        sessionManager = SessionManagerViewModel()
        sessionManager.configure(
            persistence: SwiftDataPersistenceProvider(modelContext: context),
            autoLoad: false
        )
    }

    override func tearDown() async throws {
        sessionManager = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeViewModel(backend: any InferenceBackend, name: String = "MockTest") -> ChatViewModel {
        let service = InferenceService(backend: backend, name: name)
        let vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))
        return vm
    }

    @discardableResult
    private func createAndActivateSession(vm: ChatViewModel, title: String = "Test Chat") async throws -> ManifoldInference.ChatSession {
        let session = try await sessionManager.createSession(title: title)
        sessionManager.activeSession = session
        await vm.switchToSession(session)
        return session
    }

    // MARK: - .noActiveSession

    func test_sendMessage_noActiveSession_throwsNoActiveSession() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        let vm = makeViewModel(backend: backend)
        // Skip session creation so activeSessionID stays nil.

        do {
            _ = try await vm.sendMessage("hello")
            XCTFail("Expected SendMessageError.noActiveSession to be thrown")
        } catch SendMessageError.noActiveSession {
            // Pass.
        } catch {
            XCTFail("Expected .noActiveSession, got \(error)")
        }
    }

    // MARK: - .noModelLoaded

    func test_sendMessage_noModelLoaded_throwsNoModelLoaded() async throws {
        // The lifecycle's `InferenceService(backend:name:)` constructor
        // force-flips `isModelLoaded` to true (it's a debug shortcut for
        // test fixtures). Construct InferenceService bare so the lifecycle
        // stays in the unloaded state — that's the path that triggers the
        // .noModelLoaded precondition.
        let service = InferenceService()
        let vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))
        try await createAndActivateSession(vm: vm)
        XCTAssertFalse(vm.isModelLoaded, "Precondition: model is not loaded")

        do {
            _ = try await vm.sendMessage("hello")
            XCTFail("Expected SendMessageError.noModelLoaded to be thrown")
        } catch SendMessageError.noModelLoaded {
            // Pass.
        } catch {
            XCTFail("Expected .noModelLoaded, got \(error)")
        }
    }

    // MARK: - .empty

    func test_sendMessage_emptyResponse_throwsEmpty() async throws {
        // The inner sendMessage() drops empty assistant turns silently —
        // lastTurnState stays in `.idle` after the runtime emits
        // FinishReason.empty. The outer sendMessage(_:) overload must
        // surface this as `SendMessageError.empty` so callers can
        // distinguish the no-output case from a real error.
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = []  // empty stream
        let vm = makeViewModel(backend: backend)
        try await createAndActivateSession(vm: vm)

        do {
            _ = try await vm.sendMessage("hello")
            XCTFail("Expected SendMessageError.empty to be thrown")
        } catch SendMessageError.empty {
            // Pass.
        } catch SendMessageError.runtime(let underlying) {
            XCTFail("Expected .empty, got .runtime(\(underlying))")
        } catch {
            XCTFail("Expected .empty, got \(error)")
        }
    }

    // MARK: - .runtime

    func test_sendMessage_streamFailure_throwsRuntime() async throws {
        // The MidStreamErrorBackend yields some tokens then throws — the
        // turn ends in lastTurnState == .failed(error), which the typed
        // overload must lift into SendMessageError.runtime.
        let backend = MidStreamErrorBackend(
            tokensBeforeError: ["partial"],
            errorToThrow: InferenceError.inferenceFailure("simulated stream failure")
        )
        let vm = makeViewModel(backend: backend)
        try await createAndActivateSession(vm: vm)

        do {
            _ = try await vm.sendMessage("hello")
            XCTFail("Expected SendMessageError.runtime to be thrown")
        } catch SendMessageError.runtime(let underlying) {
            // The underlying error type is implementation-detail (it can
            // be either the ConversationError wrapping or the raw
            // InferenceError depending on which surfacing path the runtime
            // used). What matters is that .runtime fired, not .empty or
            // a precondition case.
            let description = underlying.localizedDescription
            XCTAssertTrue(
                description.contains("simulated stream failure") || description.contains("Inference"),
                "Underlying error should reference the stream failure, got: \(description)"
            )
        } catch {
            XCTFail("Expected .runtime, got \(error)")
        }
    }

    // MARK: - .emptyInput (#A4)

    func test_sendMessage_whitespaceOnlyAfterCompletedTurn_throwsEmptyInputNotPriorReply() async throws {
        // Sabotage check (verified manually): removing the emptyInput
        // precondition guard from the throwing sendMessage(_:) overload
        // causes this test to fail — the call falls through to the no-arg
        // sendMessage() (which silently no-ops on blank input), then reads
        // the still-`.completed` lastTurnState from the FIRST turn and
        // returns that stale record as if it were the reply to "   ".
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["Hi", " there"]
        let vm = makeViewModel(backend: backend)
        try await createAndActivateSession(vm: vm)

        let firstReply = try await vm.sendMessage("hello")
        XCTAssertEqual(firstReply.content, "Hi there", "Precondition: first turn completed normally")

        do {
            _ = try await vm.sendMessage("   ")
            XCTFail("Expected SendMessageError.emptyInput to be thrown")
        } catch SendMessageError.emptyInput {
            // Pass.
        } catch {
            XCTFail("Expected .emptyInput, got \(error)")
        }
    }

    // MARK: - .audio attachment (gap A of the UI-honesty audit, #2356)
    //
    // No backend in this package can encode a `.audio` MessagePart today
    // (`MessagePart.textContent` is nil for it, `PromptRenderer` drops it
    // with only a log, `CloudMessageEncoder` has no `.audio` case). Before
    // this fix, `sendMessage()` cleared the draft and dispatched the turn
    // anyway — the user saw their voice note "sent" while the model never
    // received it. These tests pin the abort-and-surface behavior instead.

    func test_sendMessage_withAudioAttachment_abortsAndSurfacesError() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        let vm = makeViewModel(backend: backend)
        try await createAndActivateSession(vm: vm)

        let audioPart = MessagePart.audio(
            url: URL(fileURLWithPath: "/tmp/voice-note.m4a"),
            duration: 3.2,
            waveform: nil
        )
        vm.stageDraftAttachment(audioPart)
        XCTAssertNil(vm.activeError, "Precondition: no error yet")

        await vm.sendMessage()

        XCTAssertNotNil(vm.activeError, "sendMessage() must surface an error instead of silently dropping the audio attachment")
        XCTAssertEqual(vm.activeError?.kind, .configuration)
        XCTAssertEqual(
            vm.draftAttachments, [audioPart],
            "The draft must NOT be cleared — an aborted send must leave the user's attachment in place, not silently discard it"
        )
    }

    func test_sendMessage_throwingOverload_withAudioAttachment_throwsRuntimeError() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        let vm = makeViewModel(backend: backend)
        try await createAndActivateSession(vm: vm)

        vm.stageDraftAttachment(.audio(
            url: URL(fileURLWithPath: "/tmp/voice-note.m4a"),
            duration: 3.2,
            waveform: nil
        ))

        do {
            // Empty text with a staged attachment passes the emptyInput guard
            // (text OR attachments non-empty) — the audio guard inside the
            // inner sendMessage() must be what stops the turn.
            _ = try await vm.sendMessage("")
            XCTFail("Expected SendMessageError.runtime to be thrown for an undeliverable audio attachment")
        } catch SendMessageError.runtime(let underlying) {
            XCTAssertTrue(
                underlying.localizedDescription.contains("audio") || underlying.localizedDescription.contains("Voice"),
                "Underlying error should describe the undeliverable audio attachment, got: \(underlying.localizedDescription)"
            )
        } catch {
            XCTFail("Expected .runtime, got \(error)")
        }
    }

    /// Regression for a stale-record leak caught in review of #2356: the
    /// prior test above only exercises the audio guard while
    /// `lastTurnState == .idle` (no turn has run yet). But a *successful*
    /// prior call leaves `lastTurnState == .completed(record1)`
    /// (`ChatGenerationCoordinator.swift`). Before this fix, the throwing
    /// overload had no audio precheck of its own — it delegated to the
    /// no-arg `sendMessage()`, whose audio guard returns early WITHOUT
    /// touching `lastTurnState`, so the overload's `switch lastTurnState`
    /// then matched the stale `.completed(record1)` and returned the
    /// PREVIOUS turn's record as if it were the reply to the new,
    /// audio-attached call — the exact #A4 deception this file's other
    /// sabotage-verified test guards against for empty input.
    func test_sendMessage_throwingOverload_withAudioAttachment_afterSuccessfulPriorTurn_throwsNotStaleRecord() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["Hi", " there"]
        let vm = makeViewModel(backend: backend)
        try await createAndActivateSession(vm: vm)

        let firstReply = try await vm.sendMessage("hello")
        XCTAssertEqual(firstReply.content, "Hi there", "Precondition: first turn completed normally, leaving lastTurnState == .completed(record1)")

        vm.stageDraftAttachment(.audio(
            url: URL(fileURLWithPath: "/tmp/voice-note.m4a"),
            duration: 3.2,
            waveform: nil
        ))

        do {
            let result = try await vm.sendMessage("caption")
            XCTFail("Expected a throw for the undeliverable audio attachment, but got the stale prior record back: \(result)")
        } catch SendMessageError.runtime(let underlying) {
            XCTAssertTrue(
                underlying.localizedDescription.contains("audio") || underlying.localizedDescription.contains("Voice"),
                "Underlying error should describe the undeliverable audio attachment, got: \(underlying.localizedDescription)"
            )
        } catch {
            XCTFail("Expected .runtime, got \(error)")
        }
    }

    /// A text-only send alongside a *non*-audio attachment (image) must be
    /// unaffected by the new guard — only `.audio` aborts the send. Requires
    /// a vision-capable backend, otherwise a separate, pre-existing guard
    /// (unrelated to this fix) rejects the image for a different reason.
    func test_sendMessage_withImageAttachment_stillSendsNormally() async throws {
        let backend = MockInferenceBackend(capabilities: BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: false,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false,
            supportsVision: true
        ))
        backend.isModelLoaded = true
        backend.tokensToYield = ["ok"]
        let vm = makeViewModel(backend: backend)
        try await createAndActivateSession(vm: vm)

        vm.stageDraftAttachment(.image(data: Data([1, 2, 3, 4]), mimeType: "image/png"))

        let record = try await vm.sendMessage("describe this")
        XCTAssertEqual(record.content, "ok")
        XCTAssertNil(vm.activeError)
    }

    // MARK: - Happy path returns the assistant record (no throw)

    func test_sendMessage_happyPath_returnsAssistantRecord() async throws {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = ["Hi", " there"]
        let vm = makeViewModel(backend: backend)
        try await createAndActivateSession(vm: vm)

        let record = try await vm.sendMessage("hello")
        XCTAssertEqual(record.role, .assistant, "sendMessage(_:) must return the assistant record on success")
        XCTAssertEqual(record.content, "Hi there", "Assistant content should be the streamed tokens")
    }
}
