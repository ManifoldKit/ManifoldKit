import Foundation
import BaseChatInference

// MARK: - Legacy Send input
//
// I6 collapsed the four near-identical input structs into a single ``TurnInput``
// + ``TurnConfig`` + ``TurnKind`` triple (see ConversationRuntime+TurnInput.swift).
// `SendInput` / `RegenerateInput` / `EditInput` / `BranchInput` remain as
// deprecation shims for one minor so adopters can migrate without a hard break.
// New callers should construct ``TurnInput`` and call
// ``ConversationRuntime/processTurn(_:)``.

/// Input for ``ConversationRuntime/send(_:)``.
///
/// Carries the user-supplied text plus the generation knobs the runtime
/// forwards to ``InferenceService/enqueueAsync(...)``. The `sessionID` is
/// required — the runtime is session-scoped at the call site (Phase 1.2's
/// public stance), and turning a no-session call into a "generic" turn
/// would require a parallel error path consumers shouldn't have to
/// pattern-match.
@available(*, deprecated, renamed: "TurnInput", message: "Build a TurnInput with .send(text:attachments:) and call processTurn(_:). SendInput will be removed in a future release.")
public struct SendInput: Sendable {
    public let sessionID: UUID
    public let userText: String
    /// Optional non-text attachments (typically `MessagePart.image` cases) to
    /// include alongside `userText` on the user `ChatMessageRecord`. When
    /// non-empty the runtime builds the user record's `contentParts` as
    /// `[.text(userText), <attachments>...]` so vision-capable backends see
    /// the images and the persisted record preserves them. The runtime does
    /// only fills in missing image placeholder hashes; backends own the
    /// remaining on-wire shape.
    public let attachments: [MessagePart]
    public let systemPrompt: String?
    public let temperature: Float
    public let topP: Float
    public let repeatPenalty: Float
    public let maxOutputTokens: Int?
    public let maxThinkingTokens: Int?
    public let streamingUpdateInterval: Duration
    public let streamingBatchCharacterLimit: Int
    public let thinkingStreamingUpdateInterval: Duration
    public let thinkingStreamingBatchCharacterLimit: Int
    public let loopDetectionEnabled: Bool

    public init(
        sessionID: UUID,
        userText: String,
        attachments: [MessagePart] = [],
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        maxOutputTokens: Int? = 2048,
        maxThinkingTokens: Int? = nil,
        streamingUpdateInterval: Duration = .milliseconds(33),
        streamingBatchCharacterLimit: Int = 128,
        thinkingStreamingUpdateInterval: Duration = .milliseconds(33),
        thinkingStreamingBatchCharacterLimit: Int = 128,
        loopDetectionEnabled: Bool = true
    ) {
        self.sessionID = sessionID
        self.userText = userText
        self.attachments = attachments
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.repeatPenalty = repeatPenalty
        self.maxOutputTokens = maxOutputTokens
        self.maxThinkingTokens = maxThinkingTokens
        self.streamingUpdateInterval = streamingUpdateInterval
        self.streamingBatchCharacterLimit = streamingBatchCharacterLimit
        self.thinkingStreamingUpdateInterval = thinkingStreamingUpdateInterval
        self.thinkingStreamingBatchCharacterLimit = thinkingStreamingBatchCharacterLimit
        self.loopDetectionEnabled = loopDetectionEnabled
    }
}

@available(*, deprecated)
extension SendInput {
    /// Translates the legacy struct into the canonical ``TurnInput`` used by
    /// ``ConversationRuntime/processTurn(_:)``. Used by the deprecated
    /// ``ConversationRuntime/send(_:)`` overload to forward without
    /// duplicating the per-field plumbing.
    var asTurnInput: TurnInput {
        TurnInput(
            sessionID: sessionID,
            kind: .send(text: userText, attachments: attachments),
            config: TurnConfig(
                systemPrompt: systemPrompt,
                temperature: temperature,
                topP: topP,
                repeatPenalty: repeatPenalty,
                maxOutputTokens: maxOutputTokens,
                maxThinkingTokens: maxThinkingTokens,
                streamingUpdateInterval: streamingUpdateInterval,
                streamingBatchCharacterLimit: streamingBatchCharacterLimit,
                thinkingStreamingUpdateInterval: thinkingStreamingUpdateInterval,
                thinkingStreamingBatchCharacterLimit: thinkingStreamingBatchCharacterLimit,
                loopDetectionEnabled: loopDetectionEnabled
            )
        )
    }
}

// MARK: - Regenerate input

/// Input for ``ConversationRuntime/regenerate(_:)``.
///
/// No `userText` — regenerate re-runs the last user turn with no new input.
/// The runtime finds the last assistant message, deletes it, and streams a
/// fresh response into a new assistant record.
@available(*, deprecated, renamed: "TurnInput", message: "Build a TurnInput with .regenerate and call processTurn(_:). RegenerateInput will be removed in a future release.")
public struct RegenerateInput: Sendable {
    public let sessionID: UUID
    public let systemPrompt: String?
    public let temperature: Float
    public let topP: Float
    public let repeatPenalty: Float
    public let maxOutputTokens: Int?
    public let maxThinkingTokens: Int?
    public let streamingUpdateInterval: Duration
    public let streamingBatchCharacterLimit: Int
    public let thinkingStreamingUpdateInterval: Duration
    public let thinkingStreamingBatchCharacterLimit: Int
    public let loopDetectionEnabled: Bool

    public init(
        sessionID: UUID,
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        maxOutputTokens: Int? = 2048,
        maxThinkingTokens: Int? = nil,
        streamingUpdateInterval: Duration = .milliseconds(33),
        streamingBatchCharacterLimit: Int = 128,
        thinkingStreamingUpdateInterval: Duration = .milliseconds(33),
        thinkingStreamingBatchCharacterLimit: Int = 128,
        loopDetectionEnabled: Bool = true
    ) {
        self.sessionID = sessionID
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.repeatPenalty = repeatPenalty
        self.maxOutputTokens = maxOutputTokens
        self.maxThinkingTokens = maxThinkingTokens
        self.streamingUpdateInterval = streamingUpdateInterval
        self.streamingBatchCharacterLimit = streamingBatchCharacterLimit
        self.thinkingStreamingUpdateInterval = thinkingStreamingUpdateInterval
        self.thinkingStreamingBatchCharacterLimit = thinkingStreamingBatchCharacterLimit
        self.loopDetectionEnabled = loopDetectionEnabled
    }
}

@available(*, deprecated)
extension RegenerateInput {
    var asTurnInput: TurnInput {
        TurnInput(
            sessionID: sessionID,
            kind: .regenerate,
            config: TurnConfig(
                systemPrompt: systemPrompt,
                temperature: temperature,
                topP: topP,
                repeatPenalty: repeatPenalty,
                maxOutputTokens: maxOutputTokens,
                maxThinkingTokens: maxThinkingTokens,
                streamingUpdateInterval: streamingUpdateInterval,
                streamingBatchCharacterLimit: streamingBatchCharacterLimit,
                thinkingStreamingUpdateInterval: thinkingStreamingUpdateInterval,
                thinkingStreamingBatchCharacterLimit: thinkingStreamingBatchCharacterLimit,
                loopDetectionEnabled: loopDetectionEnabled
            )
        )
    }
}

// MARK: - Edit input

/// Input for ``ConversationRuntime/edit(_:)``.
///
/// Identifies the message to edit by ID, carries the replacement content,
/// and includes the same generation knobs as ``SendInput`` and
/// ``RegenerateInput`` for the subsequent generation turn (if any).
@available(*, deprecated, renamed: "TurnInput", message: "Build a TurnInput with .edit(messageID:text:) and call processTurn(_:). EditInput will be removed in a future release.")
public struct EditInput: Sendable {
    public let sessionID: UUID
    /// The ID of the message whose content will be replaced.
    public let messageID: UUID
    /// The replacement content for the edited message.
    public let newContent: String
    public let systemPrompt: String?
    public let temperature: Float
    public let topP: Float
    public let repeatPenalty: Float
    public let maxOutputTokens: Int?
    public let maxThinkingTokens: Int?
    public let streamingUpdateInterval: Duration
    public let streamingBatchCharacterLimit: Int
    public let thinkingStreamingUpdateInterval: Duration
    public let thinkingStreamingBatchCharacterLimit: Int
    public let loopDetectionEnabled: Bool

    public init(
        sessionID: UUID,
        messageID: UUID,
        newContent: String,
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        maxOutputTokens: Int? = 2048,
        maxThinkingTokens: Int? = nil,
        streamingUpdateInterval: Duration = .milliseconds(33),
        streamingBatchCharacterLimit: Int = 128,
        thinkingStreamingUpdateInterval: Duration = .milliseconds(33),
        thinkingStreamingBatchCharacterLimit: Int = 128,
        loopDetectionEnabled: Bool = true
    ) {
        self.sessionID = sessionID
        self.messageID = messageID
        self.newContent = newContent
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.repeatPenalty = repeatPenalty
        self.maxOutputTokens = maxOutputTokens
        self.maxThinkingTokens = maxThinkingTokens
        self.streamingUpdateInterval = streamingUpdateInterval
        self.streamingBatchCharacterLimit = streamingBatchCharacterLimit
        self.thinkingStreamingUpdateInterval = thinkingStreamingUpdateInterval
        self.thinkingStreamingBatchCharacterLimit = thinkingStreamingBatchCharacterLimit
        self.loopDetectionEnabled = loopDetectionEnabled
    }
}

@available(*, deprecated)
extension EditInput {
    var asTurnInput: TurnInput {
        TurnInput(
            sessionID: sessionID,
            kind: .edit(messageID: messageID, text: newContent),
            config: TurnConfig(
                systemPrompt: systemPrompt,
                temperature: temperature,
                topP: topP,
                repeatPenalty: repeatPenalty,
                maxOutputTokens: maxOutputTokens,
                maxThinkingTokens: maxThinkingTokens,
                streamingUpdateInterval: streamingUpdateInterval,
                streamingBatchCharacterLimit: streamingBatchCharacterLimit,
                thinkingStreamingUpdateInterval: thinkingStreamingUpdateInterval,
                thinkingStreamingBatchCharacterLimit: thinkingStreamingBatchCharacterLimit,
                loopDetectionEnabled: loopDetectionEnabled
            )
        )
    }
}

// MARK: - Branch input

/// Input for ``ConversationRuntime/branch(_:)``.
///
/// Forks a conversation at a chosen message. The runtime copies messages from
/// `sourceSessionID` up to and including `branchMessageID` into a new session
/// identified by `newSessionID`, then optionally triggers a generation turn on
/// the new session if the last copied message is a user message.
@available(*, deprecated, renamed: "TurnInput", message: "Build a TurnInput with .branch(messageID:newSessionID:newSessionTitle:generateAfter:) and call processTurn(_:). BranchInput will be removed in a future release.")
public struct BranchInput: Sendable {
    /// The session to fork from.
    public let sourceSessionID: UUID
    /// The message to branch at (inclusive — this message is copied into the
    /// new session).
    public let branchMessageID: UUID
    /// The caller-supplied ID for the new session.
    public let newSessionID: UUID
    /// Title for the new session. `nil` preserves the source session's title.
    public let newSessionTitle: String?
    /// When `true` and the last copied message is `.user`, the runtime
    /// triggers a generation turn on the new session after copying.
    public let generateAfterBranch: Bool
    // Generation knobs — only used when generateAfterBranch == true.
    public let systemPrompt: String?
    public let temperature: Float
    public let topP: Float
    public let repeatPenalty: Float
    public let maxOutputTokens: Int?
    public let maxThinkingTokens: Int?

    public init(
        sourceSessionID: UUID,
        branchMessageID: UUID,
        newSessionID: UUID = UUID(),
        newSessionTitle: String? = nil,
        generateAfterBranch: Bool = false,
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        maxOutputTokens: Int? = 2048,
        maxThinkingTokens: Int? = nil
    ) {
        self.sourceSessionID = sourceSessionID
        self.branchMessageID = branchMessageID
        self.newSessionID = newSessionID
        self.newSessionTitle = newSessionTitle
        self.generateAfterBranch = generateAfterBranch
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.repeatPenalty = repeatPenalty
        self.maxOutputTokens = maxOutputTokens
        self.maxThinkingTokens = maxThinkingTokens
    }
}

@available(*, deprecated)
extension BranchInput {
    var asTurnInput: TurnInput {
        TurnInput(
            sessionID: sourceSessionID,
            kind: .branch(
                messageID: branchMessageID,
                newSessionID: newSessionID,
                newSessionTitle: newSessionTitle,
                generateAfter: generateAfterBranch
            ),
            config: TurnConfig(
                systemPrompt: systemPrompt,
                temperature: temperature,
                topP: topP,
                repeatPenalty: repeatPenalty,
                maxOutputTokens: maxOutputTokens,
                maxThinkingTokens: maxThinkingTokens
            )
        )
    }
}

// MARK: - Stream handle

/// Identifier for an in-flight runtime stream.
///
/// Returned from ``ConversationRuntime/processTurn(_:)`` and passed back to
/// ``ConversationRuntime/cancel(_:)`` to cancel a specific in-flight turn.
/// Per-runtime unique; not stable across runtime instances.
public struct ConversationStreamHandle: Sendable, Hashable {
    public let id: UUID
    public init(id: UUID = UUID()) {
        self.id = id
    }
}

// MARK: - In-flight stream registry
//
// Holds the mutable state ConversationRuntime needs across actor hops: the
// set of in-flight stream handles and their underlying inference tokens, so
// `cancel(_:)` can target the right backend call and the send loop can
// detect cancellation.
//
// An actor (rather than a lock) because cancel is `async` already (it has
// to hop to @MainActor to call `cancelAsync`) and the bookkeeping reads
// cleanly with structured concurrency. Performance is a non-issue — this
// state is touched twice per turn.

actor InFlightStreamRegistry {
    private var entries: [UUID: InferenceService.GenerationRequestToken] = [:]
    private var cancelled: Set<UUID> = []

    func register(handle: ConversationStreamHandle, token: InferenceService.GenerationRequestToken) {
        entries[handle.id] = token
    }

    func unregister(handle: ConversationStreamHandle) {
        entries.removeValue(forKey: handle.id)
        cancelled.remove(handle.id)
    }

    /// Marks a handle cancelled and returns its inference token (if any) so
    /// the caller can issue ``InferenceService/cancelAsync(_:)`` against it.
    /// Returns `nil` when the handle has already been unregistered or was
    /// never registered (cancel races with stream completion are normal).
    func markCancelled(_ handle: ConversationStreamHandle) -> InferenceService.GenerationRequestToken? {
        cancelled.insert(handle.id)
        return entries[handle.id]
    }

    func isCancelled(_ handle: ConversationStreamHandle) -> Bool {
        cancelled.contains(handle.id)
    }
}

// MARK: - ConversationRuntime

/// Composes the runtime ports (`MessageStore`, `SessionStore`,
/// `InferenceService`, `PromptContextPipeline`) into a turn loop and
/// surfaces lifecycle as ``ConversationEvent`` values.
///
/// **Optional reference use case.** Demo and ChatbotUI-iOS adopt;
/// Fireside drives the ports directly (see the Phase 1.2 plan doc's
/// Stance section). Hosts that want a `ChatViewModel`-style adapter
/// continue to use that shape; hosts that want their own UI layer can
/// consume this class directly.
///
/// ## Concurrency
///
/// Plain `final class` — not `@Observable`, not `@MainActor`-pinned at
/// the type level. Methods that touch `@MainActor` ports hop on demand
/// using the nonisolated wrappers from `InferenceService+Nonisolated`.
/// In-flight state lives behind ``InFlightStreamRegistry`` (an actor),
/// not a lock; bookkeeping is touched at most twice per turn so the
/// extra hops are not a hot path.
///
/// ## Event delivery
///
/// The ``events`` stream is constructed once per runtime instance and is
/// single-consumer. Callers either iterate it directly (tests) or install
/// an adapter that drains it into observable state
/// (`ChatViewModel`-shaped consumers). The stream is unbounded — adapters
/// must drain it on a long-lived task or the buffer grows.
///
/// ## Turn entry points
///
/// ``processTurn(_:)`` is the canonical entry point for every turn flow.
/// Build a ``TurnInput`` with the appropriate ``TurnKind`` (`.send`,
/// `.regenerate`, `.edit`, or `.branch`) and a shared ``TurnConfig``.
/// The legacy per-flow methods (``send(_:)``, ``regenerate(_:)``,
/// ``edit(_:)``, ``branch(_:)``) and their `*Input` types are kept as
/// deprecation shims for one minor.
public final class ConversationRuntime: Sendable {

    // MARK: Ports

    private let messageStore: any MessageStore
    private let sessionStore: (any SessionStore)?
    private let inferenceService: InferenceService
    private let pipeline: PromptContextPipeline?

    // MARK: Event stream

    /// Lifecycle event stream. Single-consumer by design — see the type
    /// docs.
    public let events: AsyncStream<ConversationEvent>
    private let continuation: AsyncStream<ConversationEvent>.Continuation

    // MARK: In-flight state

    private let registry = InFlightStreamRegistry()

    // MARK: Diagnostics (test-injectable)

    /// Test-only observer fired when the turn loop drops an empty assistant
    /// response (i.e. `emptyResponse && !cancelled && streamFailed == nil`).
    /// Production callers pass `nil`; tests inject a closure to verify the
    /// silent-drop path is reachable. The observer fires from the same
    /// detached task that drives generation, so receivers must tolerate
    /// off-main delivery.
    package struct EmptyResponseDiagnostic: Sendable {
        public let sessionID: UUID
        public let backendName: String?
        public init(sessionID: UUID, backendName: String?) {
            self.sessionID = sessionID
            self.backendName = backendName
        }
    }

    private let emptyResponseObserver: (@Sendable (EmptyResponseDiagnostic) -> Void)?

    // MARK: Init

    /// Creates a runtime that composes the supplied ports.
    ///
    /// - Parameters:
    ///   - messageStore: Required. Persists user and assistant messages
    ///     across the turn loop. Hooks registered on this store fire for
    ///     every write the runtime makes.
    ///   - sessionStore: Optional. When provided, the runtime touches the
    ///     active session's `updatedAt` after a successful send so the
    ///     sidebar's "most recent" ordering reflects activity. PR-A keeps
    ///     this optional because callers using the runtime as a pure
    ///     message-stream surface may not own session metadata.
    ///   - inferenceService: Required. Used via the nonisolated wrappers
    ///     introduced by #893 (`enqueueAsync`, `cancelAsync`).
    ///   - pipeline: Optional. When `nil`, the runtime emits
    ///     `.beforeContextAssembly` and `.contextAssembled(slots: [])`
    ///     to keep the event sequence stable, then enqueues with no extra
    ///     slots. When present, the pipeline is queried before each turn
    ///     and the resulting slots are surfaced via `.contextAssembled`.
    public convenience init(
        messageStore: any MessageStore,
        sessionStore: (any SessionStore)? = nil,
        inferenceService: InferenceService,
        pipeline: PromptContextPipeline? = nil
    ) {
        self.init(
            messageStore: messageStore,
            sessionStore: sessionStore,
            inferenceService: inferenceService,
            pipeline: pipeline,
            emptyResponseObserver: nil
        )
    }

    /// Test-only init that lets the caller observe the empty-assistant drop
    /// path. Wrapped in `package` so test targets can reach it without
    /// widening the public surface.
    package init(
        messageStore: any MessageStore,
        sessionStore: (any SessionStore)? = nil,
        inferenceService: InferenceService,
        pipeline: PromptContextPipeline? = nil,
        emptyResponseObserver: (@Sendable (EmptyResponseDiagnostic) -> Void)?
    ) {
        self.messageStore = messageStore
        self.sessionStore = sessionStore
        self.inferenceService = inferenceService
        self.pipeline = pipeline
        self.emptyResponseObserver = emptyResponseObserver
        var cap: AsyncStream<ConversationEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { cap = $0 }
        self.continuation = cap
    }

    deinit {
        continuation.finish()
    }

    // MARK: Canonical entry point

    /// Processes one turn. Routes by ``TurnKind`` to the appropriate
    /// per-flow setup (synchronous persistence) and dispatches the
    /// generation portion (when applicable) onto a detached task.
    ///
    /// Returns:
    /// - A ``ConversationStreamHandle`` for any flow that drives generation.
    /// - `nil` for `.edit` of a non-user message (no regeneration) and for
    ///   `.branch` when the last copied message is not `.user` or
    ///   `generateAfter` is `false`.
    ///
    /// Cancellation: pass the returned handle to ``cancel(_:)``. The
    /// in-flight stream terminates with
    /// ``ConversationEvent/streamFinished(messageID:reason:)`` carrying
    /// ``FinishReason/cancelled``.
    @discardableResult
    public func processTurn(_ input: TurnInput) async throws -> ConversationStreamHandle? {
        switch input.kind {
        case let .send(text, attachments):
            return try await runSendFlow(
                sessionID: input.sessionID,
                text: text,
                attachments: attachments,
                config: input.config
            )
        case .regenerate:
            return try await runRegenerateFlow(
                sessionID: input.sessionID,
                config: input.config
            )
        case let .edit(messageID, text):
            return try await runEditFlow(
                sessionID: input.sessionID,
                messageID: messageID,
                text: text,
                config: input.config
            )
        case let .branch(messageID, newSessionID, newSessionTitle, generateAfter):
            return try await runBranchFlow(
                sourceSessionID: input.sessionID,
                branchMessageID: messageID,
                newSessionID: newSessionID,
                newSessionTitle: newSessionTitle,
                generateAfter: generateAfter,
                config: input.config
            )
        }
    }

    // MARK: Cancel

    /// Cancels an in-flight stream identified by `handle`.
    ///
    /// Idempotent — cancelling an already-cancelled or already-finished
    /// handle is a no-op. The stream fires its terminal
    /// ``ConversationEvent/streamFinished(messageID:reason:)`` with
    /// ``FinishReason/cancelled`` once the cancel propagates through the
    /// underlying inference layer.
    public func cancel(_ handle: ConversationStreamHandle) async {
        let token = await registry.markCancelled(handle)
        guard let token else { return }
        await inferenceService.cancelAsync(token)
    }

    // MARK: Legacy command surface (deprecated)

    /// Sends a user message and drives one generation turn.
    ///
    /// Returns immediately with a ``ConversationStreamHandle``; the
    /// generation work proceeds on a detached task and emits events on
    /// ``events``. The call is `async throws` so synchronous setup
    /// failures (no session, persistence misconfigured) surface to the
    /// caller before any task is launched; once the task is running,
    /// failures route to ``ConversationEvent/errorRaised(_:)``.
    ///
    /// Cancellation: pass the returned handle to ``cancel(_:)``. The
    /// in-flight stream terminates with
    /// ``ConversationEvent/streamFinished(messageID:reason:)`` carrying
    /// ``FinishReason/cancelled``.
    @discardableResult
    @available(*, deprecated, renamed: "processTurn(_:)", message: "Build a TurnInput with .send(text:attachments:) and call processTurn(_:).")
    public func send(_ input: SendInput) async throws -> ConversationStreamHandle {
        // The deprecated overloads forward through processTurn. `.send` always
        // produces a stream handle, so force-unwrap the optional return — the
        // underlying flow guarantees non-nil for `.send`.
        guard let handle = try await processTurn(input.asTurnInput) else {
            // Unreachable: runSendFlow always returns a non-nil handle.
            // Prefer Log + a synthetic handle over a trap so a stale flow
            // change can't take down the app.
            Log.inference.warning("ConversationRuntime.send: processTurn returned nil for .send — synthesising handle")
            return ConversationStreamHandle()
        }
        return handle
    }

    /// Deletes the last assistant message for `input.sessionID` and drives
    /// a fresh generation turn.
    ///
    /// Returns immediately with a ``ConversationStreamHandle``; deletion and
    /// generation work proceed on a detached task and emit events on
    /// ``events``. Setup failures (no assistant message to replace,
    /// persistence delete failure) surface to the caller as throws before
    /// any task is launched; once the task is running, failures route to
    /// ``ConversationEvent/errorRaised(_:)``.
    ///
    /// Cancellation: pass the returned handle to ``cancel(_:)``.
    @discardableResult
    @available(*, deprecated, renamed: "processTurn(_:)", message: "Build a TurnInput with .regenerate and call processTurn(_:).")
    public func regenerate(_ input: RegenerateInput) async throws -> ConversationStreamHandle {
        guard let handle = try await processTurn(input.asTurnInput) else {
            Log.inference.warning("ConversationRuntime.regenerate: processTurn returned nil for .regenerate — synthesising handle")
            return ConversationStreamHandle()
        }
        return handle
    }

    /// Edits a message's content, deletes all messages after it, then
    /// regenerates if the edited message was a user message.
    ///
    /// Returns a ``ConversationStreamHandle`` if generation was triggered
    /// (edited message was `.user`); returns `nil` if the edited message was
    /// `.assistant` and no generation is needed. The call is `async throws`
    /// for synchronous setup failures (message not found, persistence errors
    /// before the detached task fires); once the task is running, failures
    /// route to ``ConversationEvent/errorRaised(_:)``.
    ///
    /// Cancellation: pass the returned handle to ``cancel(_:)``.
    @discardableResult
    @available(*, deprecated, renamed: "processTurn(_:)", message: "Build a TurnInput with .edit(messageID:text:) and call processTurn(_:).")
    public func edit(_ input: EditInput) async throws -> ConversationStreamHandle? {
        try await processTurn(input.asTurnInput)
    }

    /// Forks a conversation at a chosen message, creating a new session with
    /// the messages up to and including the branch point copied in.
    ///
    /// Returns a ``ConversationStreamHandle`` when `generateAfterBranch` is
    /// `true` and the last copied message is `.user`; returns `nil` otherwise.
    /// Setup failures (branch point not found, persistence errors) throw
    /// synchronously before any task is launched; generation failures after
    /// the task is launched route to ``ConversationEvent/errorRaised(_:)``.
    @discardableResult
    @available(*, deprecated, renamed: "processTurn(_:)", message: "Build a TurnInput with .branch(messageID:...) and call processTurn(_:).")
    public func branch(_ input: BranchInput) async throws -> ConversationStreamHandle? {
        try await processTurn(input.asTurnInput)
    }

    // MARK: Send flow

    private func runSendFlow(
        sessionID: UUID,
        text: String,
        attachments rawAttachments: [MessagePart],
        config: TurnConfig
    ) async throws -> ConversationStreamHandle {
        let handle = ConversationStreamHandle()

        // Persist the user message synchronously so the caller observes
        // ordering (`messageInserted(user)` before `processTurn` returns) —
        // the stream task fires off after this point. Persistence failures
        // throw out so the caller can surface them; matching ChatViewModel's
        // current shape where a user-message persistence failure aborts the
        // turn before any assistant work runs.
        // Build user contentParts: when attachments are present, splice the
        // text part (if any) before the attachments so the persisted record
        // and the structured-history snapshot the runtime hands the backend
        // both carry `[.text, <attachments>...]`. Empty text + attachments
        // yields an attachment-only record (e.g. a "describe this image"
        // turn with no caption).
        let attachments = rawAttachments.map { $0.generatingImagePlaceholderIfNeeded() }
        let userContentParts: [MessagePart]
        if attachments.isEmpty {
            userContentParts = [.text(text)]
        } else if text.isEmpty {
            userContentParts = attachments
        } else {
            userContentParts = [.text(text)] + attachments
        }
        let userMessage = ChatMessageRecord(
            role: .user,
            contentParts: userContentParts,
            sessionID: sessionID
        )
        do {
            try await insertMessage(userMessage)
        } catch {
            throw ConversationError.persistence(error)
        }
        emit(.messageInserted(userMessage))

        // Touch session updatedAt — best-effort. Persistence errors here
        // are logged and continue; the runtime should not lose a turn over
        // a sidebar-ordering failure.
        if let sessionStore {
            await touchSession(sessionStore: sessionStore, sessionID: sessionID)
        }

        // Detach the streaming work onto an unstructured task so the
        // command returns the handle promptly. The task captures `self`
        // strongly for the duration of the turn — releases via the
        // registry when the turn ends.
        Task.detached { [self] in
            // Fetch history first — one store fetch covers both the
            // message count for context assembly and the structured
            // messages for enqueueAsync. By the time we get here, the
            // user message we just inserted is in the store
            // (insertMessage awaited above).
            let history: [ChatMessageRecord]
            do {
                history = try await fetchMessages(sessionID: sessionID)
            } catch {
                emit(.errorRaised(.persistence(error)))
                return
            }
            await runGenerationTurn(
                sessionID: sessionID,
                userPrompt: text,
                history: history,
                config: config,
                handle: handle
            )
        }

        return handle
    }

    // MARK: Regenerate flow

    private func runRegenerateFlow(
        sessionID: UUID,
        config: TurnConfig
    ) async throws -> ConversationStreamHandle {
        let handle = ConversationStreamHandle()

        // Fetch history synchronously so we can locate and delete the last
        // assistant message before returning the handle. Callers observe
        // ordering: `.messageRemoved` fires before `processTurn` returns.
        let history: [ChatMessageRecord]
        do {
            history = try await fetchMessages(sessionID: sessionID)
        } catch {
            throw ConversationError.persistence(error)
        }

        guard let lastAssistant = history.last(where: { $0.role == .assistant }) else {
            throw ConversationError.noAssistantMessageToRegenerate
        }

        do {
            try await deleteMessage(lastAssistant.id)
        } catch {
            throw ConversationError.persistence(error)
        }
        emit(.messageRemoved(messageID: lastAssistant.id))

        Task.detached { [self] in
            // Fetch history after deletion — the removed assistant message
            // is gone, so context assembly starts from the last user turn.
            let postHistory: [ChatMessageRecord]
            do {
                postHistory = try await fetchMessages(sessionID: sessionID)
            } catch {
                emit(.errorRaised(.persistence(error)))
                return
            }
            await runGenerationTurn(
                sessionID: sessionID,
                userPrompt: nil,
                history: postHistory,
                config: config,
                handle: handle
            )
        }

        return handle
    }

    // MARK: Edit flow

    private func runEditFlow(
        sessionID: UUID,
        messageID: UUID,
        text: String,
        config: TurnConfig
    ) async throws -> ConversationStreamHandle? {
        // Fetch history synchronously so we can locate the target message
        // and delete trailing messages before returning. Callers observe
        // ordering: `.messageUpdated` and `.messageRemoved` events fire
        // before `processTurn` returns so adapters can update their view-
        // state before the stream starts.
        let history: [ChatMessageRecord]
        do {
            history = try await fetchMessages(sessionID: sessionID)
        } catch {
            throw ConversationError.persistence(error)
        }

        guard let index = history.firstIndex(where: { $0.id == messageID }) else {
            throw ConversationError.messageNotFound(messageID)
        }

        // Update the edited message's content in the store.
        var updatedMessage = history[index]
        updatedMessage.content = text
        do {
            try await updateMessage(updatedMessage)
        } catch {
            throw ConversationError.persistence(error)
        }
        emit(.messageUpdated(updatedMessage))

        // Delete all messages after the edited one. On first failure stop
        // deleting and throw — callers reload from the store on failure;
        // the partial deletion is acknowledged, matching ChatViewModel's
        // behaviour.
        let trailing = Array(history[(index + 1)...])
        for msg in trailing {
            do {
                try await deleteMessage(msg.id)
            } catch {
                throw ConversationError.persistence(error)
            }
            emit(.messageRemoved(messageID: msg.id))
        }

        // If the edited message was from the user, regenerate. Assistant
        // edits persist the change but do not re-run generation.
        guard updatedMessage.role == .user else {
            return nil
        }

        let handle = ConversationStreamHandle()
        Task.detached { [self] in
            // Fetch history fresh after the synchronous edit + deletion —
            // the updated message and removed trailing messages are
            // already committed to the store before the detached task
            // runs.
            let postHistory: [ChatMessageRecord]
            do {
                postHistory = try await fetchMessages(sessionID: sessionID)
            } catch {
                emit(.errorRaised(.persistence(error)))
                return
            }
            await runGenerationTurn(
                sessionID: sessionID,
                userPrompt: nil,
                history: postHistory,
                config: config,
                handle: handle
            )
        }
        return handle
    }

    // MARK: Branch flow

    private func runBranchFlow(
        sourceSessionID: UUID,
        branchMessageID: UUID,
        newSessionID: UUID,
        newSessionTitle: String?,
        generateAfter: Bool,
        config: TurnConfig
    ) async throws -> ConversationStreamHandle? {
        // Fetch source history synchronously so callers observe ordering:
        // `.sessionBranched` fires before `processTurn` returns.
        let sourceHistory: [ChatMessageRecord]
        do {
            sourceHistory = try await fetchMessages(sessionID: sourceSessionID)
        } catch {
            throw ConversationError.persistence(error)
        }

        // Find the branch point and slice history up to and including it.
        guard let branchIndex = sourceHistory.firstIndex(where: { $0.id == branchMessageID }) else {
            throw ConversationError.messageNotFound(branchMessageID)
        }
        let slice = Array(sourceHistory[...branchIndex])

        // Derive the new session's title from the source session when the
        // caller didn't supply one. A title-fetch failure must not abort
        // the branch — the session insert below still runs with the
        // fallback — but the failure is logged so it isn't silently lost.
        let resolvedTitle: String
        if let supplied = newSessionTitle {
            resolvedTitle = supplied
        } else if let sessionStore {
            let sessions: [ChatSessionRecord]
            do {
                sessions = try await sessionStore.fetchSessions()
            } catch {
                Log.persistence.warning(
                    "ConversationRuntime.branch: title lookup failed: \(error.localizedDescription); using fallback title"
                )
                sessions = []
            }
            resolvedTitle = sessions.first(where: { $0.id == sourceSessionID })?.title ?? "New Chat"
        } else {
            resolvedTitle = "New Chat"
        }

        let newSession = ChatSessionRecord(id: newSessionID, title: resolvedTitle)
        if let sessionStore {
            do {
                try await insertSession(sessionStore: sessionStore, session: newSession)
            } catch {
                throw ConversationError.persistence(error)
            }
        }

        // Copy messages into the new session with fresh IDs and updated
        // sessionID.
        for original in slice {
            let copy = ChatMessageRecord(
                role: original.role,
                contentParts: original.contentParts,
                timestamp: original.timestamp,
                sessionID: newSessionID
            )
            do {
                try await insertMessage(copy)
            } catch {
                throw ConversationError.persistence(error)
            }
        }

        emit(.sessionBranched(newSessionID: newSessionID, copiedCount: slice.count))

        // Optionally trigger generation on the new session.
        guard generateAfter, slice.last?.role == .user else {
            return nil
        }

        let handle = ConversationStreamHandle()
        // BranchInput historically pinned the streaming/loop knobs to
        // hard-coded defaults regardless of caller config (see legacy
        // BranchInput, which only carried sampling knobs). Preserve that
        // by overriding those four fields when running the branch flow,
        // even though TurnConfig now carries them. If callers want
        // configurable streaming for branched generation, that's a
        // follow-up tuning knob.
        let branchConfig = TurnConfig(
            systemPrompt: config.systemPrompt,
            temperature: config.temperature,
            topP: config.topP,
            repeatPenalty: config.repeatPenalty,
            maxOutputTokens: config.maxOutputTokens,
            maxThinkingTokens: config.maxThinkingTokens,
            streamingUpdateInterval: .milliseconds(33),
            streamingBatchCharacterLimit: 128,
            thinkingStreamingUpdateInterval: .milliseconds(33),
            thinkingStreamingBatchCharacterLimit: 128,
            loopDetectionEnabled: true
        )
        Task.detached { [self] in
            // Re-fetch from the new session so the history reflects the
            // persisted copies with their new IDs and sessionID.
            let history: [ChatMessageRecord]
            do {
                history = try await fetchMessages(sessionID: newSessionID)
            } catch {
                emit(.errorRaised(.persistence(error)))
                return
            }
            await runGenerationTurn(
                sessionID: newSessionID,
                userPrompt: nil,
                history: history,
                config: branchConfig,
                handle: handle
            )
        }
        return handle
    }

    // MARK: Shared generation inner loop
    //
    // All four turn flows (send, regenerate, edit, branch) converge here
    // after their respective setup steps. The caller is responsible for
    // fetching a clean `history` slice; this method owns context assembly →
    // enqueue → drain → finalise.

    private func runGenerationTurn(
        sessionID: UUID,
        userPrompt: String?,
        history: [ChatMessageRecord],
        config: TurnConfig,
        handle: ConversationStreamHandle
    ) async {
        let messageCount = history.count

        // Context assembly hook. Always emit `.beforeContextAssembly` and
        // `.contextAssembled` so adapters that pin against these events
        // see them on every turn — even when no providers are registered
        // (slots = []). Stable event ordering matters more than skipping
        // a no-op emission.
        let request = PromptContextRequest(
            sessionID: sessionID,
            messageCount: messageCount,
            userInput: userPrompt
        )
        emit(.beforeContextAssembly(prompt: userPrompt, request: request))

        let slots: [PromptSlot]
        if let pipeline {
            do {
                slots = try await pipeline.assemble(messageCount: messageCount)
            } catch {
                emit(.errorRaised(.contextAssembly(error)))
                return
            }
        } else {
            slots = []
        }
        emit(.contextAssembled(slots: slots))

        // Build the assistant message slot up front so token deltas can
        // reference its id from the first emitted token.
        var assistantMessage = ChatMessageRecord(
            role: .assistant,
            content: "",
            sessionID: sessionID
        )
        let assistantID = assistantMessage.id

        let composedSystemPrompt = composeSystemPrompt(config.systemPrompt, slots: slots)

        let structuredHistory: [StructuredMessage] = history.map { record in
            StructuredMessage(role: record.role.rawValue, parts: record.contentParts)
        }

        // Forward the registered tool surface so the backend's GenerationConfig
        // gets `tools = registry.advertisedDefinitions` (legacy parity with
        // GenerationQueue.enqueueGeneration). `advertisedDefinitions`
        // already honours `advertisedToolNames` filtering — registering a
        // tool but limiting which names go on the wire works without
        // unregistering the executor. Fetched on the main actor because the
        // registry and InferenceService accessors are both MainActor-isolated.
        let advertisedTools: [ToolDefinition] = await readAdvertisedToolDefinitions()

        let token: InferenceService.GenerationRequestToken
        let stream: GenerationStream
        do {
            (token, stream) = try await inferenceService.enqueueAsync(
                structuredMessages: structuredHistory,
                systemPrompt: composedSystemPrompt,
                temperature: config.temperature,
                topP: config.topP,
                repeatPenalty: config.repeatPenalty,
                maxOutputTokens: config.maxOutputTokens,
                maxThinkingTokens: config.maxThinkingTokens,
                tools: advertisedTools,
                priority: .userInitiated,
                sessionID: sessionID
            )
        } catch {
            emit(.errorRaised(.inference(error)))
            return
        }

        await registry.register(handle: handle, token: token)

        // If cancel(_:) raced ahead of register — i.e., the caller cancelled
        // between the command returning and this point — the markCancelled
        // call returned nil (nothing to cancel at that time). Issue
        // cancelAsync now so backend work doesn't continue running while
        // the runtime has stopped consuming the stream.
        if await registry.isCancelled(handle) {
            await inferenceService.cancelAsync(token)
        }

        emit(.streamStarted(messageID: assistantID))

        // Drain the stream, mirroring GenerationQueue's four features:
        //   (a) token batcher — coalesce per-token events into UI-cadenced batches
        //   (b) thinking-block disclosure — track/batch reasoning tokens and emit
        //       thinkingStarted / thinkingUpdated / thinkingFinalized events
        //   (c) tool dispatch — persist toolCall + toolResult content parts and
        //       emit toolCallRequested / toolCallCompleted events
        //   (d) loop detection — stop the stream when RepetitionDetector fires
        var accumulated = ""
        var emptyResponse = true
        var streamFailed: ConversationError?
        var tokenUsage: (promptTokens: Int, completionTokens: Int)?

        var consumer = GenerationStreamConsumer(loopDetectionEnabled: config.loopDetectionEnabled)
        var batcher = StreamingTokenBatcher(
            interval: config.streamingUpdateInterval,
            maxBufferedCharacters: config.streamingBatchCharacterLimit
        )
        var thinkingBatcher = StreamingTokenBatcher(
            interval: config.thinkingStreamingUpdateInterval,
            maxBufferedCharacters: config.thinkingStreamingBatchCharacterLimit
        )
        var thinkingAccumulator = ""
        var thinkingDisplayed = ""
        var pendingThinkingSignature: String?

        do {
            eventLoop: for try await event in stream.events {
                let cancelled = await isCancelled(handle: handle)
                if cancelled { break }

                switch consumer.handle(event) {
                case .appendText(let text):
                    emptyResponse = false
                    if let batch = batcher.append(text, now: ContinuousClock.now) {
                        accumulated += batch
                        emit(.tokenEmitted(messageID: assistantID, delta: batch))
                        if consumer.shouldStopForLoop(content: accumulated) {
                            await inferenceService.cancelAsync(token)
                            emit(.loopDetected(messageID: assistantID))
                            break eventLoop
                        }
                    }

                case .appendThinkingText(let text):
                    let isFirst = thinkingAccumulator.isEmpty
                    thinkingAccumulator += text
                    if isFirst {
                        emit(.thinkingStarted(messageID: assistantID))
                    }
                    if let batch = thinkingBatcher.append(text, now: ContinuousClock.now) {
                        thinkingDisplayed += batch
                        emit(.thinkingUpdated(messageID: assistantID, partialText: thinkingDisplayed))
                        if consumer.shouldStopForLoop(content: thinkingAccumulator) {
                            await inferenceService.cancelAsync(token)
                            emit(.loopDetected(messageID: assistantID))
                            break eventLoop
                        }
                    }

                case .recordThinkingSignature(let signature):
                    pendingThinkingSignature = signature

                case .finalizeThinking:
                    if let batch = thinkingBatcher.flush(now: ContinuousClock.now) {
                        thinkingDisplayed += batch
                    }
                    let block = thinkingAccumulator
                    let signature = pendingThinkingSignature
                    thinkingAccumulator = ""
                    thinkingDisplayed = ""
                    pendingThinkingSignature = nil
                    guard !block.isEmpty else { break }
                    emit(.thinkingFinalized(messageID: assistantID, text: block, signature: signature))

                case .dispatchToolCall(let call):
                    emit(.toolCallRequested(call))

                case .appendToolResult(let result):
                    emit(.toolCallCompleted(result.callId, result))

                case .toolLoopLimitReached(let iterations):
                    emit(.errorRaised(.inference(
                        InferenceError.inferenceFailure("Tool-call loop stopped after \(iterations) iterations.")
                    )))

                case .recordUsage(let prompt, let completion):
                    tokenUsage = (prompt, completion)

                case .ignore:
                    break
                }
            }
        } catch {
            // Map CancellationError to `.cancelled` even when the registry has
            // not yet observed `markCancelled` for this handle. `stopGeneration`
            // schedules `runtime.cancel(_:)` on a separate Task, which can race
            // the backend's CancellationError back here ahead of the registry
            // flip; without this guard the adapter surfaces an error UI for a
            // user-initiated cancel.
            let cancelled = await isCancelled(handle: handle) || error is CancellationError
            if cancelled {
                streamFailed = .cancelled
            } else {
                streamFailed = .inference(error)
            }
        }

        // Flush remaining buffered tokens (normal end, error, or cancellation).
        if let batch = batcher.flush(now: ContinuousClock.now) {
            accumulated += batch
            emit(.tokenEmitted(messageID: assistantID, delta: batch))
        }

        // Finalize an unclosed thinking block — the model may not emit a closing
        // event if generation is cut short.
        if !thinkingAccumulator.isEmpty {
            _ = thinkingBatcher.flush(now: ContinuousClock.now)
            let block = thinkingAccumulator
            let signature = pendingThinkingSignature
            thinkingAccumulator = ""
            pendingThinkingSignature = nil
            emit(.thinkingFinalized(messageID: assistantID, text: block, signature: signature))
        }

        // Finalise the assistant message. If the stream produced no visible
        // content and was not cancelled, drop it — matches the
        // `ChatViewModel`/`GenerationQueue` rule that keeps the
        // transcript clean of empty turns.
        //
        // Unregister before emitting terminal events so that any cancel(_:)
        // called after this point is a documented no-op rather than a
        // late-cancel that could still mark the handle cancelled and confuse
        // observers.
        let cancelled = await isCancelled(handle: handle)
        await registry.unregister(handle: handle)

        // Capture token usage off the active backend before any subsequent
        // turn can overwrite it. The legacy `GenerationQueue` set this
        // on the assistant `ChatMessage` immediately after the stream ended;
        // the runtime path needs the same per-turn pinning so back-to-back
        // sends do not cross-contaminate prompt/completion counts. Read on
        // the main actor — `InferenceService.lastTokenUsage` is MainActor-
        // isolated.
        let usage: (promptTokens: Int, completionTokens: Int)?
        if let tokenUsage {
            usage = tokenUsage
        } else {
            usage = await readLastTokenUsage()
        }
        if let usage {
            assistantMessage.promptTokens = usage.promptTokens
            assistantMessage.completionTokens = usage.completionTokens
            emit(.tokenUsageRecorded(
                messageID: assistantID,
                promptTokens: usage.promptTokens,
                completionTokens: usage.completionTokens
            ))
        }

        let reason: FinishReason
        if cancelled {
            reason = .cancelled
        } else if let streamFailed {
            // An inference error during streaming. Persist whatever we have
            // (parity with ChatViewModel.stopGeneration's partial-save
            // behaviour) and emit error. We do not collapse this into
            // `.streamFinished(reason: .empty)` because consumers need to
            // know the run failed.
            assistantMessage.content = accumulated
            if !accumulated.isEmpty {
                do {
                    try await insertMessage(assistantMessage)
                    emit(.messageInserted(assistantMessage))
                } catch {
                    emit(.errorRaised(.persistence(error)))
                    emit(.errorRaised(streamFailed))
                    emit(.streamFinished(messageID: assistantID, reason: .stop))
                    return
                }
            }
            emit(.errorRaised(streamFailed))
            emit(.streamFinished(messageID: assistantID, reason: .stop))
            return
        } else if emptyResponse {
            reason = .empty
        } else {
            reason = .stop
        }

        if cancelled {
            // On cancel, persist whatever streamed in so far if non-empty —
            // matches ChatViewModel.stopGeneration's behaviour.
            if !accumulated.isEmpty {
                assistantMessage.content = accumulated
                do {
                    try await insertMessage(assistantMessage)
                    emit(.messageInserted(assistantMessage))
                } catch {
                    emit(.errorRaised(.persistence(error)))
                    // Fall through and still emit streamFinished — the
                    // cancellation outcome is the load-bearing signal here.
                }
            }
            emit(.streamFinished(messageID: assistantID, reason: reason))
            return
        }

        if reason == .empty {
            // Drop the empty assistant message. No persistence happens; we
            // emit the terminal events and return.
            //
            // Issue #965: a switch-cancel-resend race used to silently drop
            // the resent turn here. The fix lives in
            // `GenerationQueue.discardRequests(notMatching:)`, but a stream
            // may still legitimately reach this branch (e.g. backend yields
            // zero tokens for a malformed prompt). Log a warning with backend
            // + sessionID so a future regression is observable instead of
            // silent. Semantics are unchanged — this branch still drops.
            let backendName = await readActiveBackendName()
            Log.inference.warning(
                "ConversationRuntime: dropping empty assistant turn (sessionID=\(sessionID, privacy: .private), backend=\(backendName ?? "nil", privacy: .public))"
            )
            emptyResponseObserver?(EmptyResponseDiagnostic(sessionID: sessionID, backendName: backendName))
            emit(.streamFinished(messageID: assistantID, reason: reason))
            emit(.afterGeneration(messageID: assistantID, finalText: ""))
            return
        }

        // Happy path: persist the assistant message.
        assistantMessage.content = accumulated
        do {
            try await insertMessage(assistantMessage)
            emit(.messageInserted(assistantMessage))
        } catch {
            emit(.errorRaised(.persistence(error)))
            emit(.streamFinished(messageID: assistantID, reason: reason))
            return
        }

        emit(.streamFinished(messageID: assistantID, reason: reason))
        emit(.afterGeneration(messageID: assistantID, finalText: accumulated))

        // Touch session timestamp so the sidebar reflects the assistant
        // turn's recency (parity with ChatViewModel's behaviour).
        if let sessionStore {
            await touchSession(sessionStore: sessionStore, sessionID: sessionID)
        }
    }

    // MARK: Helpers

    private func emit(_ event: ConversationEvent) {
        continuation.yield(event)
    }

    /// Combines the registry-recorded cancel state with the structured-
    /// concurrency cancel signal. Either source ending the stream maps to
    /// ``FinishReason/cancelled``.
    private func isCancelled(handle: ConversationStreamHandle) async -> Bool {
        if Task.isCancelled { return true }
        return await registry.isCancelled(handle)
    }

    // `MessageStore` and `SessionStore` are `@MainActor`-bound protocols
    // (the SwiftData adapter requires it). The runtime is not on
    // `@MainActor` itself, so the helpers below are `@MainActor`-annotated
    // and `await`-called from non-main contexts to hop. Keeping the hop
    // centralised here also makes the dispatch surface easy to swap if
    // Phase 2 lifts the protocols off main.

    @MainActor
    private func insertMessage(_ message: ChatMessageRecord) async throws {
        try await messageStore.insertMessage(message)
    }

    @MainActor
    private func updateMessage(_ message: ChatMessageRecord) async throws {
        try await messageStore.updateMessage(message)
    }

    @MainActor
    private func deleteMessage(_ messageID: UUID) async throws {
        try await messageStore.deleteMessage(messageID)
    }

    @MainActor
    private func fetchMessages(sessionID: UUID) async throws -> [ChatMessageRecord] {
        try await messageStore.fetchMessages(for: sessionID)
    }

    /// Reads ``ToolRegistry/advertisedDefinitions`` off the main actor. The
    /// registry and the `InferenceService.toolRegistry` accessor are both
    /// `@MainActor`-isolated; the runtime's generation loop is not. Hopping
    /// here keeps the call site clean of explicit `MainActor.run` blocks.
    @MainActor
    private func readAdvertisedToolDefinitions() async -> [ToolDefinition] {
        guard let registry = inferenceService.toolRegistry else { return [] }
        return registry.advertisedDefinitions
    }

    /// Reads ``InferenceService/lastTokenUsage`` off the main actor. Backends
    /// overwrite this state per-turn, so the runtime captures it once at
    /// turn-end before persistence — matching the legacy coordinator's pin.
    @MainActor
    private func readLastTokenUsage() async -> (promptTokens: Int, completionTokens: Int)? {
        inferenceService.lastTokenUsage
    }

    /// Reads ``InferenceService/activeBackendName`` off the main actor for
    /// diagnostic logging on the empty-response drop path (issue #965).
    @MainActor
    private func readActiveBackendName() async -> String? {
        inferenceService.activeBackendName
    }

    @MainActor
    private func insertSession(sessionStore: any SessionStore, session: ChatSessionRecord) async throws {
        try await sessionStore.insertSession(session)
    }

    @MainActor
    private func touchSession(sessionStore: any SessionStore, sessionID: UUID) async {
        do {
            // SessionStore does not expose a single-record fetch today;
            // fetch the page and find ours. The cost is acceptable —
            // touchSession runs at most twice per turn.
            let sessions = try await sessionStore.fetchSessions()
            guard var session = sessions.first(where: { $0.id == sessionID }) else { return }
            session.updatedAt = Date()
            try await sessionStore.updateSession(session)
        } catch {
            Log.persistence.warning(
                "ConversationRuntime: touchSession failed: \(error.localizedDescription)"
            )
            emit(.sessionTouchFailed(sessionID: sessionID))
        }
    }

    private func composeSystemPrompt(_ base: String?, slots: [PromptSlot]) -> String? {
        // Append enabled slot bodies after the caller-supplied system prompt,
        // separated by blank lines. PR-A keeps the routing minimal — every
        // enabled slot's `content` is appended in order. Position-aware
        // splicing into history (e.g., `.atDepth(n)`, `.bottomOfHistory`)
        // is a follow-up; callers that need richer routing today run their
        // own ``PromptAssembler`` outside the runtime.
        let slotText = slots
            .filter { $0.isEnabled }
            .map(\.content)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        switch (base, slotText.isEmpty) {
        case (nil, true): return nil
        case (nil, false): return slotText
        case (let base?, true): return base.isEmpty ? nil : base
        case (let base?, false):
            return base.isEmpty ? slotText : "\(base)\n\n\(slotText)"
        }
    }
}
