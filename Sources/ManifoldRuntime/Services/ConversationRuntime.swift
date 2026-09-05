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
/// ``processTurn(_:)`` and ``processTurnWithOutcome(_:)`` are the only turn
/// entry points on this type. Build a ``TurnInput`` with the appropriate
/// ``TurnKind`` (`.send`, `.regenerate`, `.edit`, or `.branch`) and a shared
/// ``TurnConfig``. There are no per-verb methods here — `send`/`regenerate`/
/// `edit`/`branch` and their old per-flow input structs were collapsed into
/// this unified shape (see ``TurnConfig``'s doc comment) and no shim survives
/// for them. Per-verb convenience methods live one layer up, on
/// `ChatViewModel`: `sendMessage`, `regenerateLastResponse`, `editMessage`,
/// and `branch(from:)` construct the appropriate ``TurnInput`` and call
/// through to this type, while `stopGeneration` is the cancellation entry
/// point — it routes to ``cancel(_:)`` (and the inference service), not
/// ``processTurn(_:)``.
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

    /// The pluggable turn-execution strategy.
    ///
    /// Defaults to ``SingleTurnDriver`` which reproduces the pre-P3 linear
    /// behavior exactly. Pass a ``ResumableRunDriver`` (P3b) when you need
    /// long-running, checkpointed runs that survive app suspension.
    ///
    /// Custom drivers conform to ``TurnDriver`` and add zero engine-core
    /// edits — EDGE by design.
    private let turnDriver: any TurnDriver

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
    private let eventTaps = EventTapRegistry<ConversationEvent>()

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
    ///   - usageStore: Optional. When provided, a ``TurnUsage`` is
    ///     persisted after each successful generation turn. Recording is
    ///     best-effort — a store failure logs a warning and never aborts
    ///     the turn loop.
    ///   - generationHooks: Optional list of callbacks invoked after each
    ///     successful generation turn. Hooks are awaited in order with a
    ///     per-hook cancellation-request deadline (default 30 s). A hook that
    ///     exceeds it receives cancellation and is logged, but its direct
    ///     invocation still settles before the turn outcome; cancellation is
    ///     cooperative. Hooks do not fire on cancelled, errored, or
    ///     empty-response turns.
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
    ///   - turnContextProvider: Legacy source-compatible session-ID-only appData
    ///     provider.
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
            generationHooks: generationHooks,
            compressionPolicy: compressionPolicy,
            preTurnCompressionPolicy: preTurnCompressionPolicy,
            historyShaper: historyShaper,
            historyProviders: historyProviders,
            hostTurnContextProvider: nil,
            turnContextProvider: turnContextProvider,
            sessionToolSources: sessionToolSources,
            hookRegistry: hookRegistry,
            runStore: nil
        )
    }

    /// Internal-construction path for hosts wired through ``ManifoldBootstrap``
    /// (`ManifoldPersistenceSwiftData`, same SwiftPM package). Demoted to
    /// `package` alongside ``HostTurnContextProvider`` (2026-07 residual
    /// sweep, D.6) — the protocol has zero external adopters, so the public
    /// initializer above no longer accepts it. `runStore` joined this overload
    /// in the D.2 residual sweep (2026-07) for the same reason — the Agentic
    /// Run subsystem has zero external adopters.
    ///
    /// `hostTurnContextProvider` and `runStore` are both required (no default)
    /// so this overload never becomes ambiguous with the public initializer
    /// above at call sites that omit both labels entirely — the public
    /// initializer is the sole match in that case, and this one is the sole
    /// match whenever either label is supplied explicitly.
    package convenience init(
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
        hostTurnContextProvider: (any HostTurnContextProvider)?,
        turnContextProvider: (@Sendable (UUID) -> (any Sendable)?)? = nil,
        sessionToolSources: [any SessionToolSource] = [],
        hookRegistry: HookRegistry? = nil,
        runStore: (any RunStore)?
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
            hookRegistry: hookRegistry,
            turnDriver: nil,
            runStore: runStore
        )
    }

    /// Test-only init that lets the caller observe the empty-assistant drop
    /// path and configure the hook timeout. Wrapped in `package` so test
    /// targets can reach it without widening the public surface.
    ///
    /// This overload preserves the original 19-parameter signature (no
    /// `turnDriver:`) so the package ABI surface is additive. It delegates
    /// to the ``TurnDriver``-seam overload with `turnDriver: nil`, which
    /// selects ``SingleTurnDriver`` and reproduces pre-P3 linear behaviour.
    package convenience init(
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
        self.init(
            messageStore: messageStore,
            sessionStore: sessionStore,
            inferenceService: inferenceService,
            pipeline: pipeline,
            budgetPlanner: budgetPlanner,
            ragService: ragService,
            auxiliaryInferenceService: auxiliaryInferenceService,
            usageStore: usageStore,
            emptyResponseObserver: emptyResponseObserver,
            generationHooks: generationHooks,
            compressionPolicy: compressionPolicy,
            preTurnCompressionPolicy: preTurnCompressionPolicy,
            hookTimeout: hookTimeout,
            historyShaper: historyShaper,
            historyProviders: historyProviders,
            hostTurnContextProvider: hostTurnContextProvider,
            turnContextProvider: turnContextProvider,
            sessionToolSources: sessionToolSources,
            hookRegistry: hookRegistry,
            turnDriver: nil
        )
    }

    /// Designated test-and-power-user init that exposes the ``TurnDriver``
    /// seam. Pass a ``ResumableRunDriver`` to enable checkpointed multi-step
    /// runs; pass `nil` (or omit) to fall back to ``SingleTurnDriver``.
    ///
    /// Wrapped in `package` so test targets and framework-internal call
    /// sites can reach it without widening the public surface.
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
        hookRegistry: HookRegistry? = nil,
        turnDriver: (any TurnDriver)?,
        runStore: (any RunStore)? = nil
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
        // Driver selection (P3b #1784):
        //   1. An explicit `turnDriver` override always wins (test/power-user seam).
        //   2. Otherwise, if a `runStore` was supplied, wrap it in a
        //      ResumableRunDriver so the runtime gains durable startRun/resumeRun.
        //   3. Otherwise fall back to SingleTurnDriver to preserve pre-P3 linear
        //      behaviour — every caller that omits both keeps the old behaviour.
        if let turnDriver {
            self.turnDriver = turnDriver
        } else if let runStore {
            self.turnDriver = ResumableRunDriver(runStore: runStore)
        } else {
            self.turnDriver = SingleTurnDriver()
        }
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
    ///
    /// **Layer split (#2440):** this method *replaces* the full source list
    /// wholesale — it is the per-turn swap primitive for hosts driving
    /// `ConversationRuntime` directly. `mergeSessionToolSources(_:)` below
    /// is the sibling *accumulate* primitive that
    /// `ManifoldBootstrap.addToolSources(_:)` (in `ManifoldPersistenceSwiftData`,
    /// one layer up) forwards to — that primitive is `package`-scoped
    /// plumbing, not part of this type's public surface. Call this method
    /// directly only when you want a wholesale swap; call
    /// `ManifoldBootstrap.addToolSources(_:)` when you want to add without
    /// disturbing what's already registered.
    public func updateSessionToolSources(_ sources: [any SessionToolSource]) async {
        await bindings.updateSessionToolSources(sources)
    }

    /// Merges `sources` into the currently registered session tool sources,
    /// replacing only the entries whose *dynamic type* matches an incoming
    /// source — every other currently-registered source is left untouched.
    /// Two sources of the same dynamic type passed together in one `sources`
    /// array are both kept (de-duplication only ever consults sources
    /// registered by an *earlier* call).
    ///
    /// This is the **single source of truth** for "what's currently
    /// registered" — there is no separate accumulator anywhere else. A
    /// source installed or swapped via ``updateSessionToolSources(_:)``
    /// directly (the wholesale-swap primitive above) is exactly what the
    /// next `mergeSessionToolSources(_:)` call merges into, so the two
    /// primitives never drift out of sync with each other (#2441).
    ///
    /// Runs atomically inside the `RuntimeBindingsBox` actor — read, merge,
    /// and write happen in one hop, so two concurrent callers can't race
    /// each other into a lost update the way a separate
    /// read-then-compute-then-write across two actor calls could.
    ///
    /// `ManifoldBootstrap.addToolSources(_:)` (`ManifoldPersistenceSwiftData`)
    /// is a thin public forward to this method — see that method's doc for
    /// the accumulate-layer framing. `package`-scoped rather than `public`:
    /// it is the plumbing `addToolSources(_:)` is built on, not a second
    /// public entry point alongside it.
    package func mergeSessionToolSources(_ sources: [any SessionToolSource]) async {
        await bindings.mergeSessionToolSources(sources)
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
        // Delegate to the wired TurnDriver. SingleTurnDriver (the default)
        // reproduces the pre-P3 per-kind switch exactly; ResumableRunDriver
        // (P3b) adds checkpointed multi-step orchestration on top.
        try await turnDriver.executeTurn(
            input,
            executor: executor,
            taskRegistry: turnTasks,
            outcomeCompletion: outcomeCompletion
        )
    }

    // MARK: Bulk cancellation

    /// Cancels all in-flight generation turns and waits for them to drain.
    ///
    /// Call this from a `BGContinuedProcessingTask.expirationHandler` — the
    /// handler is synchronous, so fire a detached task that awaits this method
    /// (see the ``ConversationRuntime`` `BGContinuedProcessingTask` recipe in
    /// the `BackgroundTaskSupport` DocC article) — or any other context where
    /// the caller needs a clean shutdown without a retained
    /// ``ConversationStreamHandle``.
    ///
    /// Mirrors the `deinit` teardown path so the two stay in sync. Idempotent —
    /// safe to call when no turns are in flight.
    public func cancelAllTurns() async {
        turnTasks.cancelAll()
        let tokens = await registry.markAllCancelled()
        for token in tokens {
            await inferenceService.cancelAsync(token)
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

    // MARK: Resumable run API (P3b)

    /// Starts a ``ConversationRun`` using the wired ``TurnDriver``.
    ///
    /// Available only when the runtime was initialised with a
    /// ``ResumableRunDriver``. Returns an `AsyncStream<RunEvent>` that
    /// delivers lifecycle events (started / step / paused / resumed /
    /// completed / cancelled / failed) until the run terminates.
    ///
    /// Calling this method when the runtime uses the default
    /// ``SingleTurnDriver`` logs a warning and returns an immediately-
    /// finishing stream — hosts should pair ``startRun`` with a
    /// ``ResumableRunDriver``.
    ///
    /// - Parameters:
    ///   - run:      The run record to start. The driver persists it.
    ///   - using:    The input provider that drives step synthesis.
    /// - Returns: A stream of ``RunEvent`` values.
    package func startRun(
        _ run: ConversationRun,
        using provider: any RunInputProvider = FixedGoalRunInputProvider()
    ) -> AsyncStream<RunEvent> {
        guard let resumableDriver = turnDriver as? ResumableRunDriver else {
            Log.inference.warning(
                "ConversationRuntime.startRun: runtime was not configured with a ResumableRunDriver; ignoring."
            )
            return AsyncStream { $0.finish() }
        }
        return resumableDriver.startRun(
            run,
            using: provider,
            executor: executor,
            taskRegistry: turnTasks
        )
    }

    /// Resumes a previously-checkpointed ``ConversationRun`` from the
    /// ``RunStore`` and continues it from the first not-yet-completed step.
    ///
    /// Available only when the runtime was initialised with a
    /// ``ResumableRunDriver``. Unlike ``ResumableRunDriver/resumeRun()`` (which
    /// flips an in-memory pause flag on the live run), this reloads the run and
    /// its steps from the store, making it a durable cross-process resume.
    ///
    /// Calling this method when the runtime uses the default
    /// ``SingleTurnDriver`` logs a warning and returns an immediately-finishing
    /// stream.
    ///
    /// - Parameters:
    ///   - runID:  The id of the persisted run to resume.
    ///   - using:  The input provider that drives step synthesis. Must satisfy
    ///             the idempotency contract on
    ///             ``RunInputProvider/nextInput(for:stepIndex:prior:)``.
    /// - Returns: A stream of ``RunEvent`` values.
    package func resumeRun(
        _ runID: UUID,
        using provider: any RunInputProvider = FixedGoalRunInputProvider()
    ) -> AsyncStream<RunEvent> {
        guard let resumableDriver = turnDriver as? ResumableRunDriver else {
            Log.inference.warning(
                "ConversationRuntime.resumeRun: runtime was not configured with a ResumableRunDriver; ignoring."
            )
            return AsyncStream { $0.finish() }
        }
        return resumableDriver.resume(
            runID: runID,
            using: provider,
            executor: executor,
            taskRegistry: turnTasks
        )
    }

    /// Requests that the active run pause after its current step (P3b #1784).
    ///
    /// No-op when the runtime uses the default ``SingleTurnDriver``. The run
    /// emits ``RunEvent/runPaused`` once it suspends; the persisted run status
    /// transitions to ``RunStatus/paused`` so a later ``resumeRun(_:using:)``
    /// can pick it up — even across a process restart.
    package func pauseActiveRun() async {
        guard let resumableDriver = turnDriver as? ResumableRunDriver else {
            Log.inference.warning(
                "ConversationRuntime.pauseActiveRun: runtime was not configured with a ResumableRunDriver; ignoring."
            )
            return
        }
        await resumableDriver.pauseRun()
    }

    /// Requests that the active run cancel (P3b #1784).
    ///
    /// No-op when the runtime uses the default ``SingleTurnDriver``. The run
    /// emits ``RunEvent/runCancelled`` and its persisted status becomes
    /// ``RunStatus/cancelled`` (terminal).
    package func cancelActiveRun() async {
        guard let resumableDriver = turnDriver as? ResumableRunDriver else {
            Log.inference.warning(
                "ConversationRuntime.cancelActiveRun: runtime was not configured with a ResumableRunDriver; ignoring."
            )
            return
        }
        await resumableDriver.cancelRun()
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
