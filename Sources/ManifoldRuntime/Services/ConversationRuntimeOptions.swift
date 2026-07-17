import Foundation
import ManifoldInference

/// Optional ``ConversationRuntime`` extension points threaded through
/// ``ManifoldBootstrap`` to the runtime it constructs.
///
/// All properties default to `nil` / empty, which reproduces the behaviour of
/// a bootstrap with no options specified. Set only what your host app needs:
///
/// ```swift
/// var options = ConversationRuntimeOptions()
/// options.historyShaper = StoryHistoryShaper()
/// options.compressionPolicy = SummarisationPolicy()
/// options.generationHooks = [TitleGenerationHook()]
///
/// let bootstrap = try ManifoldBootstrap(
///     configuration: config,
///     runtimeOptions: options,
///     makeModelContainer: { try ModelContainerFactory.makeContainer() }
/// )
/// ```
///
/// Passing an `auxiliaryInferenceService` lets the runtime use a separate, cheap
/// model for internal tasks like session-title generation and compression routing,
/// keeping those off your primary model:
///
/// ```swift
/// var options = ConversationRuntimeOptions()
/// options.auxiliaryInferenceService = InferenceService(backend: FoundationBackend())
/// ```
public struct ConversationRuntimeOptions {

    /// Custom prompt-context assembly pipeline replacing the default slot-merge.
    public var pipeline: PromptContextPipeline?

    /// Custom token-budget planner used during context trimming.
    public var budgetPlanner: ContextBudgetPlanner?

    /// Hooks called after each completed generation turn.
    public var generationHooks: [any GenerationHook]

    /// Post-turn history-compression policy.
    public var compressionPolicy: (any CompressionPolicy)?

    /// Pre-turn history-compression policy applied before each new turn.
    public var preTurnCompressionPolicy: (any PreTurnCompressionPolicy)?

    /// Host-owned transformer applied to assembled history before each turn.
    public var historyShaper: (any HistoryShaper)?

    /// History augmentation providers injected before context assembly.
    public var historyProviders: [any HistoryProvider]

    /// Async/throwing richer per-turn context provider. Supersedes
    /// ``turnContextProvider`` when both are set.
    ///
    /// `package`-visibility only (2026-07 residual sweep, D.6) — the
    /// `HostTurnContextProvider` protocol has zero external adopters, so
    /// this property is no longer settable from outside the package. Only
    /// `ManifoldBootstrap` (same package) reads it; hosts on the public API
    /// use ``turnContextProvider`` or the planner-path `TurnContext.appData`
    /// handoff instead.
    package var hostTurnContextProvider: (any HostTurnContextProvider)?

    /// Legacy synchronous per-turn context provider.
    public var turnContextProvider: (@Sendable (UUID) -> (any Sendable)?)?

    /// Auxiliary inference service for internal framework tasks such as
    /// session-title generation and compression routing. When `nil` the
    /// runtime falls back to the primary ``InferenceService``.
    public var auxiliaryInferenceService: InferenceService?

    /// Optional ``RunStore`` that opts the runtime into durable, resumable
    /// multi-step runs (P3b #1784).
    ///
    /// When set — and no explicit `turnDriver` override is supplied — the
    /// runtime constructs a ``ResumableRunDriver`` over this store instead of
    /// the default ``SingleTurnDriver``, enabling
    /// ``ConversationRuntime/startRun(_:using:)`` /
    /// ``ConversationRuntime/resumeRun(_:using:)``. Leaving it `nil` (the
    /// default) reproduces pre-P3 single-turn behaviour exactly.
    ///
    /// `package`-visibility only (2026-07 residual sweep, D.2) — the Agentic
    /// Run subsystem has zero external adopters, so this property is no
    /// longer settable from a public initializer. Only `ManifoldBootstrap`
    /// (same SwiftPM package) sets it, via `enableResumableRuns:`.
    package var runStore: (any RunStore)?

    public init(
        pipeline: PromptContextPipeline? = nil,
        budgetPlanner: ContextBudgetPlanner? = nil,
        generationHooks: [any GenerationHook] = [],
        compressionPolicy: (any CompressionPolicy)? = nil,
        preTurnCompressionPolicy: (any PreTurnCompressionPolicy)? = nil,
        historyShaper: (any HistoryShaper)? = nil,
        historyProviders: [any HistoryProvider] = [],
        turnContextProvider: (@Sendable (UUID) -> (any Sendable)?)? = nil,
        auxiliaryInferenceService: InferenceService? = nil
    ) {
        self.pipeline = pipeline
        self.budgetPlanner = budgetPlanner
        self.generationHooks = generationHooks
        self.compressionPolicy = compressionPolicy
        self.preTurnCompressionPolicy = preTurnCompressionPolicy
        self.historyShaper = historyShaper
        self.historyProviders = historyProviders
        self.hostTurnContextProvider = nil
        self.turnContextProvider = turnContextProvider
        self.auxiliaryInferenceService = auxiliaryInferenceService
        self.runStore = nil
    }
}
