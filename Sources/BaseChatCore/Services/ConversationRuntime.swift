import Foundation
import BaseChatInference

// MARK: - Send input
//
// PR-A ships the ``send`` sub-flow. Regenerate lands in PR-B; edit lands in
// PR-C. Each sub-flow has its own input type and command method; all three
// share the ``runGenerationTurn`` private helper for the generation inner
// loop (context assembly → enqueue → drain → finalise).

/// Input for ``ConversationRuntime/send(_:)``.
///
/// Carries the user-supplied text plus the generation knobs the runtime
/// forwards to ``InferenceService/enqueueAsync(...)``. The `sessionID` is
/// required — the runtime is session-scoped at the call site (Phase 1.2's
/// public stance), and turning a no-session call into a "generic" turn
/// would require a parallel error path consumers shouldn't have to
/// pattern-match.
public struct SendInput: Sendable {
    public let sessionID: UUID
    public let userText: String
    public let systemPrompt: String?
    public let temperature: Float
    public let topP: Float
    public let repeatPenalty: Float
    public let maxOutputTokens: Int?
    public let maxThinkingTokens: Int?

    public init(
        sessionID: UUID,
        userText: String,
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        maxOutputTokens: Int? = 2048,
        maxThinkingTokens: Int? = nil
    ) {
        self.sessionID = sessionID
        self.userText = userText
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.repeatPenalty = repeatPenalty
        self.maxOutputTokens = maxOutputTokens
        self.maxThinkingTokens = maxThinkingTokens
    }
}

// MARK: - Regenerate input

/// Input for ``ConversationRuntime/regenerate(_:)``.
///
/// No `userText` — regenerate re-runs the last user turn with no new input.
/// The runtime finds the last assistant message, deletes it, and streams a
/// fresh response into a new assistant record.
public struct RegenerateInput: Sendable {
    public let sessionID: UUID
    public let systemPrompt: String?
    public let temperature: Float
    public let topP: Float
    public let repeatPenalty: Float
    public let maxOutputTokens: Int?
    public let maxThinkingTokens: Int?

    public init(
        sessionID: UUID,
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        maxOutputTokens: Int? = 2048,
        maxThinkingTokens: Int? = nil
    ) {
        self.sessionID = sessionID
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.repeatPenalty = repeatPenalty
        self.maxOutputTokens = maxOutputTokens
        self.maxThinkingTokens = maxThinkingTokens
    }
}

// MARK: - Edit input

/// Input for ``ConversationRuntime/edit(_:)``.
///
/// Identifies the message to edit by ID, carries the replacement content,
/// and includes the same generation knobs as ``SendInput`` and
/// ``RegenerateInput`` for the subsequent generation turn (if any).
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

    public init(
        sessionID: UUID,
        messageID: UUID,
        newContent: String,
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        maxOutputTokens: Int? = 2048,
        maxThinkingTokens: Int? = nil
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
    }
}

// MARK: - Branch input

/// Input for ``ConversationRuntime/branch(_:)``.
///
/// Forks a conversation at a chosen message. The runtime copies messages from
/// `sourceSessionID` up to and including `branchMessageID` into a new session
/// identified by `newSessionID`, then optionally triggers a generation turn on
/// the new session if the last copied message is a user message.
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

// MARK: - Stream handle

/// Identifier for an in-flight runtime stream.
///
/// Returned from ``ConversationRuntime/send(_:)`` and passed back to
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
/// ## Scope (PR-C)
///
/// PR-A ships the scaffolding plus the ``send(_:)`` sub-flow. PR-B adds
/// ``regenerate(_:)``. PR-C adds ``edit(_:)`` and extracts a shared
/// ``runGenerationTurn`` helper that all three sub-flows delegate the
/// generation inner loop to. Branch / other sub-flows ship in later PRs.
/// None of these PRs absorb the streaming-token batcher, thinking-block
/// disclosure, loop detection, or tool-dispatch loop from
/// `GenerationCoordinator`; those stay on the `ChatViewModel` adapter for
/// now and migrate into the runtime in follow-up PRs.
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
    public init(
        messageStore: any MessageStore,
        sessionStore: (any SessionStore)? = nil,
        inferenceService: InferenceService,
        pipeline: PromptContextPipeline? = nil
    ) {
        self.messageStore = messageStore
        self.sessionStore = sessionStore
        self.inferenceService = inferenceService
        self.pipeline = pipeline
        var cap: AsyncStream<ConversationEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { cap = $0 }
        self.continuation = cap
    }

    deinit {
        continuation.finish()
    }

    // MARK: Commands

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
    public func send(_ input: SendInput) async throws -> ConversationStreamHandle {
        let handle = ConversationStreamHandle()

        // Persist the user message synchronously so the caller observes
        // ordering (`messageInserted(user)` before `send` returns) — the
        // stream task fires off after this point. Persistence failures
        // throw out so the caller can surface them; matching ChatViewModel's
        // current shape where a user-message persistence failure aborts the
        // turn before any assistant work runs.
        let userMessage = ChatMessageRecord(
            role: .user,
            content: input.userText,
            sessionID: input.sessionID
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
            await touchSession(sessionStore: sessionStore, sessionID: input.sessionID)
        }

        // Detach the streaming work onto an unstructured task so `send`
        // returns the handle promptly. The task captures `self` strongly
        // for the duration of the turn — releases via the registry when
        // the turn ends.
        Task.detached { [self] in
            await runSendTurn(input: input, handle: handle)
        }

        return handle
    }

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
    public func regenerate(_ input: RegenerateInput) async throws -> ConversationStreamHandle {
        let handle = ConversationStreamHandle()

        // Fetch history synchronously so we can locate and delete the last
        // assistant message before returning the handle. Callers observe
        // ordering: `.messageRemoved` fires before `regenerate` returns, so
        // adapters that unsubscribe from the old message slot can do so
        // before the new stream starts.
        let history: [ChatMessageRecord]
        do {
            history = try await fetchMessages(sessionID: input.sessionID)
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
            await runRegenerateTurn(input: input, handle: handle)
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
    public func edit(_ input: EditInput) async throws -> ConversationStreamHandle? {
        // Fetch history synchronously so we can locate the target message and
        // delete trailing messages before returning. Callers observe ordering:
        // `.messageUpdated` and `.messageRemoved` events fire before `edit`
        // returns so adapters can update their view-state before the stream
        // starts.
        let history: [ChatMessageRecord]
        do {
            history = try await fetchMessages(sessionID: input.sessionID)
        } catch {
            throw ConversationError.persistence(error)
        }

        guard let index = history.firstIndex(where: { $0.id == input.messageID }) else {
            throw ConversationError.messageNotFound(input.messageID)
        }

        // Update the edited message's content in the store.
        var updatedMessage = history[index]
        updatedMessage.content = input.newContent
        do {
            try await updateMessage(updatedMessage)
        } catch {
            throw ConversationError.persistence(error)
        }
        emit(.messageUpdated(updatedMessage))

        // Delete all messages after the edited one. On first failure stop
        // deleting and throw — callers reload from the store on failure; the
        // partial deletion is acknowledged, matching ChatViewModel's behaviour.
        let trailing = Array(history[(index + 1)...])
        for msg in trailing {
            do {
                try await deleteMessage(msg.id)
            } catch {
                throw ConversationError.persistence(error)
            }
            emit(.messageRemoved(messageID: msg.id))
        }

        // If the edited message was from the user, regenerate.
        guard updatedMessage.role == .user else {
            // Assistant edit: no generation needed.
            return nil
        }

        let handle = ConversationStreamHandle()
        Task.detached { [self] in
            await runEditGenerationTurn(input: input, handle: handle)
        }
        return handle
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
    public func branch(_ input: BranchInput) async throws -> ConversationStreamHandle? {
        // Fetch source history synchronously so callers observe ordering:
        // `.sessionBranched` fires before `branch` returns.
        let sourceHistory: [ChatMessageRecord]
        do {
            sourceHistory = try await fetchMessages(sessionID: input.sourceSessionID)
        } catch {
            throw ConversationError.persistence(error)
        }

        // Find the branch point and slice history up to and including it.
        guard let branchIndex = sourceHistory.firstIndex(where: { $0.id == input.branchMessageID }) else {
            throw ConversationError.messageNotFound(input.branchMessageID)
        }
        let slice = Array(sourceHistory[...branchIndex])

        // Create the new session. Derive title from the source session when
        // the caller didn't supply one — best-effort via fetchSessions; no
        // title is better than crashing if session store is absent.
        let newSessionTitle: String
        if let supplied = input.newSessionTitle {
            newSessionTitle = supplied
        } else if let sessionStore {
            let sessions = (try? await sessionStore.fetchSessions()) ?? []
            newSessionTitle = sessions.first(where: { $0.id == input.sourceSessionID })?.title ?? "New Chat"
        } else {
            newSessionTitle = "New Chat"
        }

        let newSession = ChatSessionRecord(id: input.newSessionID, title: newSessionTitle)
        if let sessionStore {
            do {
                try await insertSession(sessionStore: sessionStore, session: newSession)
            } catch {
                throw ConversationError.persistence(error)
            }
        }

        // Copy messages into the new session with fresh IDs and updated sessionID.
        for original in slice {
            let copy = ChatMessageRecord(
                role: original.role,
                contentParts: original.contentParts,
                timestamp: original.timestamp,
                sessionID: input.newSessionID
            )
            do {
                try await insertMessage(copy)
            } catch {
                throw ConversationError.persistence(error)
            }
        }

        emit(.sessionBranched(newSessionID: input.newSessionID, copiedCount: slice.count))

        // Optionally trigger generation on the new session.
        guard input.generateAfterBranch, slice.last?.role == .user else {
            return nil
        }

        let handle = ConversationStreamHandle()
        Task.detached { [self] in
            await runBranchGenerationTurn(input: input, branchedHistory: slice, handle: handle)
        }
        return handle
    }

    // MARK: Send turn

    private func runSendTurn(
        input: SendInput,
        handle: ConversationStreamHandle
    ) async {
        // 1. Build history first — one store fetch covers both the message
        //    count for context assembly and the structured messages for
        //    enqueueAsync. By the time we get here, the user message we
        //    just inserted is in the store (insertMessage awaited above).
        //    We do not include the empty assistant slot — it is not yet
        //    inserted.
        let history: [ChatMessageRecord]
        do {
            history = try await fetchMessages(sessionID: input.sessionID)
        } catch {
            emit(.errorRaised(.persistence(error)))
            return
        }

        await runGenerationTurn(
            sessionID: input.sessionID,
            userPrompt: input.userText,
            history: history,
            systemPrompt: input.systemPrompt,
            temperature: input.temperature,
            topP: input.topP,
            repeatPenalty: input.repeatPenalty,
            maxOutputTokens: input.maxOutputTokens,
            maxThinkingTokens: input.maxThinkingTokens,
            handle: handle
        )
    }

    // MARK: Regenerate turn

    private func runRegenerateTurn(
        input: RegenerateInput,
        handle: ConversationStreamHandle
    ) async {
        // Fetch history after deletion — the removed assistant message is
        // gone, so context assembly starts from the last user turn.
        let history: [ChatMessageRecord]
        do {
            history = try await fetchMessages(sessionID: input.sessionID)
        } catch {
            emit(.errorRaised(.persistence(error)))
            return
        }

        await runGenerationTurn(
            sessionID: input.sessionID,
            userPrompt: nil,
            history: history,
            systemPrompt: input.systemPrompt,
            temperature: input.temperature,
            topP: input.topP,
            repeatPenalty: input.repeatPenalty,
            maxOutputTokens: input.maxOutputTokens,
            maxThinkingTokens: input.maxThinkingTokens,
            handle: handle
        )
    }

    // MARK: Edit generation turn

    private func runEditGenerationTurn(
        input: EditInput,
        handle: ConversationStreamHandle
    ) async {
        // Fetch history fresh after the synchronous edit + deletion — the
        // updated message and removed trailing messages are already
        // committed to the store before the detached task runs.
        let history: [ChatMessageRecord]
        do {
            history = try await fetchMessages(sessionID: input.sessionID)
        } catch {
            emit(.errorRaised(.persistence(error)))
            return
        }

        // `prompt: nil` — same as regenerate; no new user-supplied text.
        await runGenerationTurn(
            sessionID: input.sessionID,
            userPrompt: nil,
            history: history,
            systemPrompt: input.systemPrompt,
            temperature: input.temperature,
            topP: input.topP,
            repeatPenalty: input.repeatPenalty,
            maxOutputTokens: input.maxOutputTokens,
            maxThinkingTokens: input.maxThinkingTokens,
            handle: handle
        )
    }

    // MARK: Branch generation turn

    private func runBranchGenerationTurn(
        input: BranchInput,
        branchedHistory: [ChatMessageRecord],
        handle: ConversationStreamHandle
    ) async {
        // Re-fetch from the new session so the history reflects the persisted
        // copies with their new IDs and sessionID.
        let history: [ChatMessageRecord]
        do {
            history = try await fetchMessages(sessionID: input.newSessionID)
        } catch {
            emit(.errorRaised(.persistence(error)))
            return
        }

        await runGenerationTurn(
            sessionID: input.newSessionID,
            userPrompt: nil,
            history: history,
            systemPrompt: input.systemPrompt,
            temperature: input.temperature,
            topP: input.topP,
            repeatPenalty: input.repeatPenalty,
            maxOutputTokens: input.maxOutputTokens,
            maxThinkingTokens: input.maxThinkingTokens,
            handle: handle
        )
    }

    // MARK: Shared generation inner loop
    //
    // All three turn methods (send, regenerate, edit) converge here after
    // their respective setup steps. The caller is responsible for fetching
    // a clean `history` slice; this method owns context assembly → enqueue
    // → drain → finalise.

    private func runGenerationTurn(
        sessionID: UUID,
        userPrompt: String?,
        history: [ChatMessageRecord],
        systemPrompt: String?,
        temperature: Float,
        topP: Float,
        repeatPenalty: Float,
        maxOutputTokens: Int?,
        maxThinkingTokens: Int?,
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

        let composedSystemPrompt = composeSystemPrompt(systemPrompt, slots: slots)

        let structuredHistory: [StructuredMessage] = history.map { record in
            StructuredMessage(role: record.role.rawValue, parts: record.contentParts)
        }

        let token: InferenceService.GenerationRequestToken
        let stream: GenerationStream
        do {
            (token, stream) = try await inferenceService.enqueueAsync(
                structuredMessages: structuredHistory,
                systemPrompt: composedSystemPrompt,
                temperature: temperature,
                topP: topP,
                repeatPenalty: repeatPenalty,
                maxOutputTokens: maxOutputTokens,
                maxThinkingTokens: maxThinkingTokens,
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

        // Drain the stream. This loop deliberately does *not* re-implement
        // GenerationCoordinator's batching, thinking-block disclosure, loop
        // detection, or tool-dispatch behaviour — those migrate in follow-up
        // PRs.
        var accumulated = ""
        var emptyResponse = true
        var streamFailed: ConversationError?

        do {
            for try await event in stream.events {
                let cancelled = await isCancelled(handle: handle)
                if cancelled { break }
                switch event {
                case .token(let text):
                    accumulated += text
                    emptyResponse = false
                    emit(.tokenEmitted(messageID: assistantID, delta: text))

                case .thinkingToken, .thinkingComplete, .thinkingSignature,
                        .toolCall, .toolCallStart, .toolCallArgumentsDelta,
                        .toolResult, .toolDispatchStarted, .toolDispatchCompleted,
                        .toolLoopLimitReached, .usage, .prefillProgress,
                        .kvCacheReuse, .diagnosticThrottle:
                    // Out of scope. Tool-call routing through the runtime ships
                    // in a follow-up; usage / prefill / diagnostic events are
                    // observed by adapters that want them via direct
                    // InferenceService observation today.
                    continue
                }
            }
        } catch {
            let cancelled = await isCancelled(handle: handle)
            if cancelled {
                streamFailed = .cancelled
            } else {
                streamFailed = .inference(error)
            }
        }

        // Finalise the assistant message. If the stream produced no visible
        // content and was not cancelled, drop it — matches the
        // `ChatViewModel`/`GenerationCoordinator` rule that keeps the
        // transcript clean of empty turns.
        //
        // Unregister before emitting terminal events so that any cancel(_:)
        // called after this point is a documented no-op rather than a
        // late-cancel that could still mark the handle cancelled and confuse
        // observers.
        let cancelled = await isCancelled(handle: handle)
        await registry.unregister(handle: handle)

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
