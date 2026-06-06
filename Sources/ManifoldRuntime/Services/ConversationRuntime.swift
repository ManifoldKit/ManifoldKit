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
/// single-consumer. Use it for lifecycle observation, event ordering, and UI
/// adapters that need the full event transcript. Callers either iterate it
/// directly (tests) or install an adapter that drains it into observable state
/// (`ChatViewModel`-shaped consumers). The stream is capped at 500 buffered
/// events using `.bufferingOldest` — when a slow consumer falls behind,
/// already-arrived events are preserved and the newest unprocessed arrivals
/// are dropped. Adapters must drain the stream on a long-lived task to
/// avoid hitting the cap during normal operation.
///
/// Treat token, thinking, tool-call, skill, hook, and handoff events as
/// observational progress. Treat ``ConversationEvent/streamFinished(messageID:reason:)``,
/// ``ConversationEvent/errorRaised(_:)``, and message mutation events as
/// important inputs for event consumers that reconcile UI or side-channel
/// state, not as the recommended command-completion primitive. Command-style
/// callers should use ``processTurnWithOutcome(_:)`` and await the returned
/// ``ConversationTurnHandle/outcome`` for reliable per-turn completion,
/// including cancellation, empty responses, and asynchronous generation
/// failures. That outcome path is independent of event buffering, dropped
/// events, and competing consumers.
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

    /// Host-mutable holder for the per-session knobs the executor reads at
    /// the top of each turn. Exposed through the `update*` mutators below
    /// so a host that built the runtime once at app init can swap context
    /// per scenario card / per agent flow without rebuilding.
    private let bindings: RuntimeBindingsBox

    // MARK: Event stream

    /// Lifecycle event stream for observation, progress rendering, state
    /// reconciliation, and ordering assertions.
    ///
    /// Single-consumer by design — see the type docs. Capped at 500 buffered
    /// events: when a slow consumer falls behind, the oldest unprocessed
    /// events are preserved and the newest arrivals are dropped. This prevents
    /// unbounded memory growth when the consumer stalls (e.g. app backgrounded
    /// during a long generation). Await
    /// ``processTurnWithOutcome(_:)``'s ``ConversationTurnHandle/outcome`` when
    /// command-style turn completion must be reliable.
    ///
    /// For multi-consumer observation, use ``addEventTap(bufferingPolicy:)``
    /// to install additional independent streams that each receive the full
    /// event flow without competing with this consumer.
    public let events: AsyncStream<ConversationEvent>
    private let continuation: AsyncStream<ConversationEvent>.Continuation

    /// Fan-out registry for secondary event consumers installed via
    /// ``addEventTap(bufferingPolicy:)``. Separate from the primary
    /// ``continuation`` so the primary stream's `.bufferingOldest(500)` policy
    /// does not affect tap consumers, and a slow tap cannot stall the turn loop.
    private let eventTaps = EventTapRegistry()

    // MARK: In-flight state

    private let registry = InFlightStreamRegistry()
    private let turnTasks = ConversationTurnTaskRegistry()

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
    ///   - historyShaper: Optional host-owned history transformer applied to the
    ///     canonical fetched history before additive ``HistoryProvider``
    ///     contributions, prompt-context slot assembly, and RAG. Use this to
    ///     remove or rewrite prompt-visible history without mutating canonical
    ///     persistence. A throwing shaper aborts the turn with
    ///     ``ConversationError/contextAssembly(_:)``.
    ///   - historyProviders: Optional list of additive ``HistoryProvider``
    ///     conformances applied after `historyShaper` (when present) and before
    ///     prompt-context slot assembly. Providers are applied in registration
    ///     order; each sees the history as augmented by all preceding providers.
    ///     A throwing provider aborts the current turn with a
    ///     ``ConversationError/persistence(_:)`` error. Defaults to `[]` so
    ///     existing call sites compile unchanged.
    ///   - hostTurnContextProvider: Optional richer async/throwing provider that
    ///     builds per-turn ``TurnContext/appData`` from full request metadata.
    ///     When supplied, its result is threaded through history shaping,
    ///     history providers, prompt-context assembly, and
    ///     ``GenerationHook/postGeneration(_:)``. A thrown error aborts the turn
    ///     with ``ConversationError/contextAssembly(_:)``.
    ///   - turnContextProvider: Legacy source-compatible session-ID-only appData
    ///     provider. Used only when `hostTurnContextProvider` is `nil`.
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
        preTurnCompressionPolicy: (any PreTurnCompressionPolicy)? = nil,
        historyShaper: (any HistoryShaper)? = nil,
        historyProviders: [any HistoryProvider] = [],
        hostTurnContextProvider: (any HostTurnContextProvider)? = nil,
        turnContextProvider: (@Sendable (UUID) -> (any Sendable)?)? = nil,
        sessionToolSources: [any SessionToolSource] = [],
        hookRegistry: HookRegistry? = nil
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
            preTurnCompressionPolicy: preTurnCompressionPolicy,
            historyShaper: historyShaper,
            historyProviders: historyProviders,
            hostTurnContextProvider: hostTurnContextProvider,
            turnContextProvider: turnContextProvider,
            sessionToolSources: sessionToolSources,
            hookRegistry: hookRegistry
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
        preTurnCompressionPolicy: (any PreTurnCompressionPolicy)? = nil,
        hookTimeout: Duration = .seconds(30),
        historyShaper: (any HistoryShaper)? = nil,
        historyProviders: [any HistoryProvider] = [],
        hostTurnContextProvider: (any HostTurnContextProvider)? = nil,
        turnContextProvider: (@Sendable (UUID) -> (any Sendable)?)? = nil,
        sessionToolSources: [any SessionToolSource] = [],
        hookRegistry: HookRegistry? = nil
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
        let bindings = RuntimeBindingsBox(
            sessionToolSources: sessionToolSources,
            hookRegistry: hookRegistry
        )
        self.bindings = bindings
        self.executor = ConversationTurnExecutor(
            persistence: persistence,
            inferenceService: inferenceService,
            pipeline: pipeline,
            budgetPlanner: budgetPlanner,
            ragService: ragService,
            usageStore: usageStore,
            registry: registry,
            emit: { [eventTaps] event in
                continuation.yield(event)
                eventTaps.broadcast(event)
            },
            emptyResponseObserver: emptyResponseObserver,
            generationHooks: generationHooks,
            compressionPolicy: compressionPolicy,
            preTurnCompressionPolicy: preTurnCompressionPolicy,
            hookTimeout: hookTimeout,
            historyShaper: historyShaper,
            historyProviders: historyProviders,
            hostTurnContextProvider: hostTurnContextProvider,
            turnContextProvider: turnContextProvider,
            bindings: bindings
        )
    }

    // MARK: Host-mutable bindings

    /// Replaces the per-session tool contributors used by subsequent turns.
    ///
    /// Used by host-app scenario machinery (e.g. the demo's per-card
    /// runtime swap) that builds the runtime once at app init and then
    /// needs to swap which sources are advertised on each turn. The
    /// executor re-reads bindings at the top of every send turn, so the
    /// new sources take effect on the next turn without an executor
    /// rebuild. In-flight streams are not reconfigured — cancel and
    /// resend if mid-stream rebind is required.
    public func updateSessionToolSources(_ sources: [any SessionToolSource]) async {
        await bindings.updateSessionToolSources(sources)
    }

    /// Replaces the ``HookRegistry`` used by subsequent turns. Pass `nil`
    /// to detach hooks. Same per-turn rebind semantics as
    /// ``updateSessionToolSources(_:)``.
    public func updateHookRegistry(_ registry: HookRegistry?) async {
        await bindings.updateHookRegistry(registry)
    }

    deinit {
        turnTasks.cancelAll()
        let registry = registry
        let inferenceService = inferenceService
        // Use Task.detached so the teardown hop does not inherit an
        // unspecified executor context from the non-isolated deinit.
        Task.detached {
            let tokens = await registry.markAllCancelled()
            for token in tokens {
                await inferenceService.cancelAsync(token)
            }
        }
        continuation.finish()
        eventTaps.finishAll()
    }

    package var activeTurnTaskCount: Int {
        turnTasks.count
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
        try await processTurn(input, outcomeCompletion: nil)
    }

    /// Processes one turn and returns a per-turn handle with reliable
    /// completion independent of the global ``events`` stream.
    ///
    /// The returned ``ConversationTurnHandle/outcome`` completes exactly once
    /// for generation flows, including cancellation, empty responses, and
    /// asynchronous failures. It is not affected by ``events`` buffering, event
    /// drops, or another component already consuming the event stream. Flows
    /// that do not generate (assistant edit, branch without generation) still
    /// return `nil`.
    @discardableResult
    public func processTurnWithOutcome(_ input: TurnInput) async throws -> ConversationTurnHandle? {
        let completion = ConversationTurnOutcomeCompletion()
        guard let streamHandle = try await processTurn(input, outcomeCompletion: completion) else {
            return nil
        }
        return ConversationTurnHandle(streamHandle: streamHandle, completion: completion)
    }

    private func processTurn(
        _ input: TurnInput,
        outcomeCompletion: ConversationTurnOutcomeCompletion?
    ) async throws -> ConversationStreamHandle? {
        switch input.kind {
        case let .send(text, attachments):
            return try await executor.runSendFlow(
                sessionID: input.sessionID,
                text: text,
                attachments: attachments,
                config: input.config,
                taskRegistry: turnTasks,
                outcomeCompletion: outcomeCompletion
            )
        case .regenerate:
            return try await executor.runRegenerateFlow(
                sessionID: input.sessionID,
                config: input.config,
                taskRegistry: turnTasks,
                outcomeCompletion: outcomeCompletion
            )
        case let .edit(messageID, text):
            return try await executor.runEditFlow(
                sessionID: input.sessionID,
                messageID: messageID,
                text: text,
                config: input.config,
                taskRegistry: turnTasks,
                outcomeCompletion: outcomeCompletion
            )
        case let .branch(messageID, newSessionID, newSessionTitle, generateAfter):
            return try await executor.runBranchFlow(
                sourceSessionID: input.sessionID,
                branchMessageID: messageID,
                newSessionID: newSessionID,
                newSessionTitle: newSessionTitle,
                generateAfter: generateAfter,
                config: input.config,
                taskRegistry: turnTasks,
                outcomeCompletion: outcomeCompletion
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
        turnTasks.cancel(handle)
        guard let token else { return }
        await inferenceService.cancelAsync(token)
    }

    // MARK: Secondary event taps

    /// Installs a secondary multicast tap on this runtime's event flow.
    ///
    /// The returned stream receives every ``ConversationEvent`` the primary
    /// ``events`` stream sees. The tap is independent of the primary consumer —
    /// installing one does not starve ``events``, and a slow tap does not stall
    /// the turn loop.
    ///
    /// - Parameter bufferingPolicy: Controls what happens when the tap consumer
    ///   falls behind. Defaults to `.unbounded` so no events are dropped; pass a
    ///   bounded policy if you need backpressure semantics.
    /// - Returns: An `AsyncStream` that delivers events until the runtime
    ///   terminates, at which point the stream finishes normally.
    public func addEventTap(
        bufferingPolicy: AsyncStream<ConversationEvent>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<ConversationEvent> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { [eventTaps] continuation in
            let id = eventTaps.register(continuation)
            continuation.onTermination = { _ in
                eventTaps.deregister(id)
            }
        }
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

// MARK: - AsyncSequence Conformance

extension ConversationRuntime: AsyncSequence {
    public typealias Element = ConversationEvent
    public typealias AsyncIterator = AsyncStream<ConversationEvent>.AsyncIterator

    /// Returns an iterator over the conversation lifecycle events emitted by
    /// this runtime.
    ///
    /// Allows idiomatic iteration with `for await event in runtime { … }`
    /// instead of `for await event in runtime.events { … }`.
    ///
    /// - Note: The ``events`` stream is single-consumer by design and capped at
    ///   500 buffered events. See the type documentation for details on
    ///   multi-consumer observation via ``addEventTap(bufferingPolicy:)``.
    public nonisolated func makeAsyncIterator() -> AsyncStream<ConversationEvent>.AsyncIterator {
        events.makeAsyncIterator()
    }
}
