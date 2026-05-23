import Foundation
import ManifoldInference

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
/// (`ChatViewModel`-shaped consumers). The stream is capped at 500 buffered
/// events using `.bufferingOldest` — when a slow consumer falls behind,
/// already-arrived events are preserved and the newest unprocessed arrivals
/// are dropped. Adapters must drain the stream on a long-lived task to
/// avoid hitting the cap during normal operation.
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

    private let inferenceService: InferenceService

    /// Optional auxiliary backend for framework-internal classification tasks
    /// (title generation, compression routing). When set, these cheap tasks
    /// run against this service instead of the primary ``inferenceService``,
    /// leaving the user's chosen model free for real conversation turns.
    ///
    /// Host apps can inject a `FoundationBackend`-backed service here on
    /// iOS 26+ / macOS 26+ where on-device inference is free and low-latency.
    /// `ManifoldBootstrap` wires this automatically when the platform supports it.
    public let auxiliaryInferenceService: InferenceService?

    /// Returns ``auxiliaryInferenceService`` when set, otherwise the primary
    /// ``inferenceService``. Used internally for classification tasks that do
    /// not belong on the user's chosen model (title generation, compression).
    public var classificationService: InferenceService {
        auxiliaryInferenceService ?? inferenceService
    }

    private let executor: ConversationTurnExecutor

    // MARK: Event stream

    /// Lifecycle event stream. Single-consumer by design — see the type
    /// docs. Capped at 500 buffered events: when a slow consumer falls
    /// behind, the oldest unprocessed events are preserved and the newest
    /// arrivals are dropped. This prevents unbounded memory growth when the
    /// consumer stalls (e.g. app backgrounded during a long generation).
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
    ///     For proportional per-provider weight splitting, supply a
    ///     ``ContextBudgetPlanner`` via `budgetPlanner` instead.
    ///   - budgetPlanner: Optional. When present, takes priority over `pipeline`
    ///     and performs proportional token-budget allocation with spillover across
    ///     its registered providers. Use this when different context sources
    ///     (lore, retrieval, world state) should compete for tokens by weight
    ///     rather than receiving the full budget each.
    ///   - usageStore: Optional. When provided, a ``TurnUsageRecord`` is
    ///     persisted after each successful generation turn. Recording is
    ///     best-effort — a store failure logs a warning and never aborts
    ///     the turn loop.
    ///   - generationHooks: Optional list of callbacks invoked after each
    ///     successful generation turn. Hooks are awaited in order with a
    ///     per-hook timeout (default 30 s). A hung hook is cancelled and
    ///     logged — it never blocks the next turn. Hooks do not fire on
    ///     cancelled, errored, or empty-response turns.
    ///   - compressionPolicy: Optional. When provided, the runtime calls
    ///     ``CompressionPolicy/shouldCompress(promptTokens:contextSize:contextUtilization:)``
    ///     after each successful generation turn. When it returns `true`,
    ///     the runtime compresses history and emits
    ///     ``ConversationEvent/historyCompressed(sessionID:)``. Compression
    ///     failures are logged and never abort the turn.
    ///   - historyProviders: Optional list of ``HistoryProvider`` conformances
    ///     applied to the fetched history before context assembly. Providers are
    ///     applied in registration order; each sees the history as augmented by
    ///     all preceding providers. A throwing provider aborts the current turn
    ///     with a ``ConversationError/persistence(_:)`` error. Defaults to `[]`
    ///     so existing call sites compile unchanged.
    public convenience init(
        messageStore: any MessageStore,
        sessionStore: (any SessionStore)? = nil,
        inferenceService: InferenceService,
        pipeline: PromptContextPipeline? = nil,
        budgetPlanner: ContextBudgetPlanner? = nil,
        ragService: RAGService? = nil,
        auxiliaryInferenceService: InferenceService? = nil,
        usageStore: (any UsageStore)? = nil,
        generationHooks: [any GenerationHook] = [],
        compressionPolicy: (any CompressionPolicy)? = nil,
        historyProviders: [any HistoryProvider] = [],
        turnContextProvider: (@Sendable (UUID) -> (any Sendable)?)? = nil,
        sessionToolSources: [any SessionToolSource] = []
    ) {
        self.init(
            messageStore: messageStore,
            sessionStore: sessionStore,
            inferenceService: inferenceService,
            pipeline: pipeline,
            budgetPlanner: budgetPlanner,
            ragService: ragService,
            auxiliaryInferenceService: auxiliaryInferenceService,
            usageStore: usageStore,
            emptyResponseObserver: nil,
            generationHooks: generationHooks,
            compressionPolicy: compressionPolicy,
            historyProviders: historyProviders,
            turnContextProvider: turnContextProvider,
            sessionToolSources: sessionToolSources
        )
    }

    /// Test-only init that lets the caller observe the empty-assistant drop
    /// path and configure the hook timeout. Wrapped in `package` so test
    /// targets can reach it without widening the public surface.
    package init(
        messageStore: any MessageStore,
        sessionStore: (any SessionStore)? = nil,
        inferenceService: InferenceService,
        pipeline: PromptContextPipeline? = nil,
        budgetPlanner: ContextBudgetPlanner? = nil,
        ragService: RAGService? = nil,
        auxiliaryInferenceService: InferenceService? = nil,
        usageStore: (any UsageStore)? = nil,
        emptyResponseObserver: (@Sendable (EmptyResponseDiagnostic) -> Void)?,
        generationHooks: [any GenerationHook] = [],
        compressionPolicy: (any CompressionPolicy)? = nil,
        hookTimeout: Duration = .seconds(30),
        historyProviders: [any HistoryProvider] = [],
        turnContextProvider: (@Sendable (UUID) -> (any Sendable)?)? = nil,
        sessionToolSources: [any SessionToolSource] = []
    ) {
        self.inferenceService = inferenceService
        self.auxiliaryInferenceService = auxiliaryInferenceService
        let persistence = ConversationPersistencePort(
            messageStore: messageStore,
            sessionStore: sessionStore
        )
        var cap: AsyncStream<ConversationEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingOldest(500)) { cap = $0 }
        let continuation = cap!
        self.continuation = continuation
        self.executor = ConversationTurnExecutor(
            persistence: persistence,
            inferenceService: inferenceService,
            pipeline: pipeline,
            budgetPlanner: budgetPlanner,
            ragService: ragService,
            usageStore: usageStore,
            registry: registry,
            emit: { continuation.yield($0) },
            emptyResponseObserver: emptyResponseObserver,
            generationHooks: generationHooks,
            compressionPolicy: compressionPolicy,
            hookTimeout: hookTimeout,
            historyProviders: historyProviders,
            turnContextProvider: turnContextProvider,
            sessionToolSources: sessionToolSources
        )
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
            return try await executor.runSendFlow(
                sessionID: input.sessionID,
                text: text,
                attachments: attachments,
                config: input.config
            )
        case .regenerate:
            return try await executor.runRegenerateFlow(
                sessionID: input.sessionID,
                config: input.config
            )
        case let .edit(messageID, text):
            return try await executor.runEditFlow(
                sessionID: input.sessionID,
                messageID: messageID,
                text: text,
                config: input.config
            )
        case let .branch(messageID, newSessionID, newSessionTitle, generateAfter):
            return try await executor.runBranchFlow(
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
}
