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
    public var hostTurnContextProvider: (any HostTurnContextProvider)?

    /// Legacy synchronous per-turn context provider. Used only when
    /// ``hostTurnContextProvider`` is `nil`.
    public var turnContextProvider: (@Sendable (UUID) -> (any Sendable)?)?

    /// Auxiliary inference service for internal framework tasks such as
    /// session-title generation and compression routing. When `nil` the
    /// runtime falls back to the primary ``InferenceService``.
    public var auxiliaryInferenceService: InferenceService?

    public init(
        pipeline: PromptContextPipeline? = nil,
        budgetPlanner: ContextBudgetPlanner? = nil,
        generationHooks: [any GenerationHook] = [],
        compressionPolicy: (any CompressionPolicy)? = nil,
        preTurnCompressionPolicy: (any PreTurnCompressionPolicy)? = nil,
        historyShaper: (any HistoryShaper)? = nil,
        historyProviders: [any HistoryProvider] = [],
        hostTurnContextProvider: (any HostTurnContextProvider)? = nil,
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
        self.hostTurnContextProvider = hostTurnContextProvider
        self.turnContextProvider = turnContextProvider
        self.auxiliaryInferenceService = auxiliaryInferenceService
    }
}
