import Foundation

/// A generation parameter that a backend may or may not support.
public enum GenerationParameter: String, CaseIterable, Sendable, Codable {
    case temperature
    case topP
    case repeatPenalty
    case topK
    case typicalP
    case minP
    case repetitionPenalty
    case presencePenalty
    case frequencyPenalty
    case llamaDRY
    case llamaXTC
    case llamaMirostatV2
}

/// How the backend loads model weights into memory.
public enum MemoryStrategy: String, Sendable, Equatable, Codable {
    /// Model must be fully resident in RAM (e.g., MLX on unified memory).
    case resident
    /// Model is memory-mapped; only active pages + KV cache need RAM (e.g., llama.cpp).
    case mappable
    /// No local model memory needed (cloud APIs, OS-managed models).
    case external
}

/// How the backend responds to a cancellation request.
public enum CancellationStyle: String, Sendable, Equatable, Codable {
    /// Cancels via Swift task cancellation.
    case cooperative
    /// Requires calling `stopGeneration()` explicitly.
    case explicit
}

/// Describes what an inference backend supports.
///
/// The UI reads these to enable/disable controls (e.g., hide the top-p slider
/// for Apple Foundation Models which only expose temperature).
public struct BackendCapabilities: Sendable, Equatable, Codable {
    /// Which sampling parameters the backend accepts.
    public let supportedParameters: Set<GenerationParameter>

    /// Maximum context window in tokens.
    public let maxContextTokens: Int32

    /// Effective token limit for this backend/model.
    ///
    /// Convenience accessor over `maxContextTokens`. Use this when branching
    /// generation strategy based on context size (e.g., in `PromptAssembler`).
    public var contextWindowSize: Int { Int(maxContextTokens) }

    /// Maximum number of tokens the model can generate in a single response.
    public let maxOutputTokens: Int

    /// Whether the caller must format messages into a prompt string
    /// using a `PromptTemplate`. When `false`, the backend applies
    /// its own chat template internally (MLX, Foundation).
    public let requiresPromptTemplate: Bool

    /// Whether the backend supports a separate system prompt.
    public let supportsSystemPrompt: Bool

    /// Whether the backend streams tokens as they are generated.
    public let supportsStreaming: Bool

    /// Whether the backend supports tool/function calling.
    public let supportsToolCalling: Bool

    /// Whether the backend supports structured (JSON schema) output.
    public let supportsStructuredOutput: Bool

    /// Whether the backend supports a native JSON-object generation mode.
    public let supportsNativeJSONMode: Bool

    /// How the backend handles generation cancellation.
    public let cancellationStyle: CancellationStyle

    /// Whether the backend can count tokens locally before sending a request.
    public let supportsTokenCounting: Bool

    /// How the backend loads model weights into memory.
    public let memoryStrategy: MemoryStrategy

    /// `true` for any backend that makes network calls (cloud APIs, Ollama, etc.).
    /// All remote backends must also reflect this in their `memoryStrategy`.
    public let isRemote: Bool

    /// If true, the backend reuses KV cache state across consecutive `generate()` calls in the
    /// same model-loaded session — defined as calls between `loadModel()`, `resetConversation()`,
    /// and `unloadModel()`. Transparent to callers; enables Track D.
    public let supportsKVCachePersistence: Bool

    /// If true, the backend honors `GenerationConfig.grammar` via sampler-level GBNF constraint
    /// and the caller can rely on grammar-valid output. Backends reporting `false` (default) MUST
    /// throw `InferenceError.unsupportedGrammar(reason:)` when `config.grammar != nil`.
    public let supportsGrammarConstrainedSampling: Bool

    /// If true, the backend can emit ``GenerationEvent/thinkingToken(_:)`` and
    /// ``GenerationEvent/thinkingComplete`` events for reasoning content. Consumers use this
    /// static capability flag to gate thinking-related UI (reasoning disclosure group,
    /// thinking budget slider) rather than inferring it from the active `PromptTemplate`.
    ///
    /// Defaults to `false` for source compatibility. Orthogonal to
    /// `GenerationConfig.thinkingMarkers`, which is a per-request runtime hint.
    public let supportsThinking: Bool

    /// If true, the backend can consume image parts in ``StructuredMessage`` history.
    ///
    /// UI surfaces use this to gate image-attachment affordances, and the
    /// inference coordinator uses it to fail fast rather than silently dropping
    /// image parts during flattening on text-only backends.
    public let supportsVision: Bool

    /// True when the backend emits ``GenerationEvent/toolCallStart(callId:name:)``
    /// and ``GenerationEvent/toolCallArgumentsDelta(callId:textDelta:)`` before
    /// each ``GenerationEvent/toolCall(_:)``. Cloud streaming backends set
    /// `true`; local inline-parser backends and non-streaming HTTP backends
    /// set `false`.
    public let streamsToolCallArguments: Bool

    /// Whether the backend streams tool-call argument deltas incrementally.
    /// Alias for ``streamsToolCallArguments`` with a clearer name.
    ///
    /// The original name `streamsToolCallArguments` is ambiguous — it could be
    /// read as "streams the arguments as a whole". This alias makes the
    /// incremental-delta semantics explicit. Both names refer to the same
    /// capability and may be used interchangeably.
    public var streamsToolCallArgumentDeltas: Bool { streamsToolCallArguments }

    /// True when the backend can emit multiple ``GenerationEvent/toolCall(_:)``
    /// events in one generation round (parallel batch). Single-call backends
    /// and small local models that only reliably emit one call at a time set
    /// `false`.
    public let supportsParallelToolCalls: Bool

    /// Whether the backend supports Foundation-style guided structured output.
    public let supportsGuidedStructuredOutput: Bool

    /// `true` when the backend uses MLX's process-global resources — the GPU
    /// buffer cache (`MLX.Memory.cacheLimit`), the Metal device, and the MLX
    /// runtime singleton — and must coordinate with `MLXResourceArbiter` for
    /// safe multi-backend hosting in the same process.
    ///
    /// Hosts loading multiple MLX-family backends concurrently (e.g. a chat
    /// LLM plus an MLX embedding model) read this flag to decide whether to
    /// serialize lifecycle hooks or assume the backends are independent.
    /// For single-MLX setups the flag is informational; for multi-MLX it
    /// signals that direct `MLX.Memory.*` calls from sibling code would
    /// trample the arbiter's per-instance accounting.
    ///
    /// Defaults to `false` — only the MLX backend (and any future backends
    /// sharing the MLX runtime) sets this to `true`.
    public let sharesMLXProcessResources: Bool

    /// Hard cap on the number of tools that may be advertised to this backend
    /// in a single generation turn.
    ///
    /// When non-`nil`, `ConversationTurnExecutor` truncates the tool list it
    /// passes to `GenerationConfig.tools` to at most this many entries —
    /// lexicographic order, so the selection is deterministic. Backends that
    /// impose no limit leave this `nil`.
    ///
    /// ``FoundationBackend`` sets this to `16`: Apple's on-device model
    /// degrades when the schema catalogue grows too large because it spends
    /// an increasing share of its context budget re-reading tool definitions
    /// rather than reasoning. `16` is the empirically-derived ceiling (see
    /// `MCPToolFilter.foundationModelsToolCap`).
    public let maxAdvertisedToolCount: Int?

    /// Preferred structured-output mechanism implied by this capability set.
    public var preferredStructuredOutputSupport: StructuredOutputSupport {
        if supportsGrammarConstrainedSampling {
            return .grammarConstrainedSampling
        }
        if supportsGuidedStructuredOutput {
            return .guidedGeneration
        }
        if supportsStructuredOutput {
            return .jsonSchema
        }
        return .jsonPrompting
    }

    /// Parameters the UI should present controls for.
    public var visibleParameters: [GenerationParameter] {
        GenerationParameter.allCases.filter { supportedParameters.contains($0) }
    }

    public init(
        supportedParameters: Set<GenerationParameter> = [.temperature],
        maxContextTokens: Int32 = 4096,
        requiresPromptTemplate: Bool = false,
        supportsSystemPrompt: Bool = true,
        supportsToolCalling: Bool = false,
        supportsStructuredOutput: Bool = false,
        supportsNativeJSONMode: Bool = false,
        cancellationStyle: CancellationStyle = .cooperative,
        supportsTokenCounting: Bool = false,
        memoryStrategy: MemoryStrategy = .resident,
        maxOutputTokens: Int = 4096,
        supportsStreaming: Bool = true,
        isRemote: Bool = false,
        supportsKVCachePersistence: Bool = false,
        supportsGrammarConstrainedSampling: Bool = false,
        supportsThinking: Bool = false,
        supportsVision: Bool = false,
        streamsToolCallArguments: Bool = false,
        supportsParallelToolCalls: Bool = false,
        supportsGuidedStructuredOutput: Bool = false,
        sharesMLXProcessResources: Bool = false,
        maxAdvertisedToolCount: Int? = nil
    ) {
        self.supportedParameters = supportedParameters
        self.maxContextTokens = maxContextTokens
        self.requiresPromptTemplate = requiresPromptTemplate
        self.supportsSystemPrompt = supportsSystemPrompt
        self.supportsToolCalling = supportsToolCalling
        self.supportsStructuredOutput = supportsStructuredOutput
        self.supportsNativeJSONMode = supportsNativeJSONMode
        self.cancellationStyle = cancellationStyle
        self.supportsTokenCounting = supportsTokenCounting
        self.memoryStrategy = memoryStrategy
        self.maxOutputTokens = maxOutputTokens
        self.supportsStreaming = supportsStreaming
        self.isRemote = isRemote
        self.supportsKVCachePersistence = supportsKVCachePersistence
        self.supportsGrammarConstrainedSampling = supportsGrammarConstrainedSampling
        self.supportsThinking = supportsThinking
        self.supportsVision = supportsVision
        self.streamsToolCallArguments = streamsToolCallArguments
        self.supportsParallelToolCalls = supportsParallelToolCalls
        self.supportsGuidedStructuredOutput = supportsGuidedStructuredOutput
        self.sharesMLXProcessResources = sharesMLXProcessResources
        self.maxAdvertisedToolCount = maxAdvertisedToolCount
    }

    private enum CodingKeys: String, CodingKey {
        case supportedParameters
        case maxContextTokens
        case maxOutputTokens
        case requiresPromptTemplate
        case supportsSystemPrompt
        case supportsStreaming
        case supportsToolCalling
        case supportsStructuredOutput
        case supportsNativeJSONMode
        case cancellationStyle
        case supportsTokenCounting
        case memoryStrategy
        case isRemote
        case supportsKVCachePersistence
        case supportsGrammarConstrainedSampling
        case supportsThinking
        case supportsVision
        case streamsToolCallArguments
        case supportsParallelToolCalls
        case supportsGuidedStructuredOutput
        case sharesMLXProcessResources
        case maxAdvertisedToolCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        supportedParameters = try c.decode(Set<GenerationParameter>.self, forKey: .supportedParameters)
        maxContextTokens = try c.decode(Int32.self, forKey: .maxContextTokens)
        maxOutputTokens = try c.decode(Int.self, forKey: .maxOutputTokens)
        requiresPromptTemplate = try c.decode(Bool.self, forKey: .requiresPromptTemplate)
        supportsSystemPrompt = try c.decode(Bool.self, forKey: .supportsSystemPrompt)
        supportsStreaming = try c.decode(Bool.self, forKey: .supportsStreaming)
        supportsToolCalling = try c.decode(Bool.self, forKey: .supportsToolCalling)
        supportsStructuredOutput = try c.decode(Bool.self, forKey: .supportsStructuredOutput)
        supportsNativeJSONMode = (try c.decodeIfPresent(Bool.self, forKey: .supportsNativeJSONMode)) ?? false
        cancellationStyle = try c.decode(CancellationStyle.self, forKey: .cancellationStyle)
        supportsTokenCounting = try c.decode(Bool.self, forKey: .supportsTokenCounting)
        memoryStrategy = try c.decode(MemoryStrategy.self, forKey: .memoryStrategy)
        isRemote = try c.decode(Bool.self, forKey: .isRemote)
        supportsKVCachePersistence = (try c.decodeIfPresent(Bool.self, forKey: .supportsKVCachePersistence)) ?? false
        supportsGrammarConstrainedSampling = (try c.decodeIfPresent(Bool.self, forKey: .supportsGrammarConstrainedSampling)) ?? false
        supportsThinking = (try c.decodeIfPresent(Bool.self, forKey: .supportsThinking)) ?? false
        supportsVision = (try c.decodeIfPresent(Bool.self, forKey: .supportsVision)) ?? false
        streamsToolCallArguments = (try c.decodeIfPresent(Bool.self, forKey: .streamsToolCallArguments)) ?? false
        supportsParallelToolCalls = (try c.decodeIfPresent(Bool.self, forKey: .supportsParallelToolCalls)) ?? false
        supportsGuidedStructuredOutput = (try c.decodeIfPresent(Bool.self, forKey: .supportsGuidedStructuredOutput)) ?? false
        sharesMLXProcessResources = (try c.decodeIfPresent(Bool.self, forKey: .sharesMLXProcessResources)) ?? false
        maxAdvertisedToolCount = try c.decodeIfPresent(Int.self, forKey: .maxAdvertisedToolCount)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(supportedParameters, forKey: .supportedParameters)
        try c.encode(maxContextTokens, forKey: .maxContextTokens)
        try c.encode(maxOutputTokens, forKey: .maxOutputTokens)
        try c.encode(requiresPromptTemplate, forKey: .requiresPromptTemplate)
        try c.encode(supportsSystemPrompt, forKey: .supportsSystemPrompt)
        try c.encode(supportsStreaming, forKey: .supportsStreaming)
        try c.encode(supportsToolCalling, forKey: .supportsToolCalling)
        try c.encode(supportsStructuredOutput, forKey: .supportsStructuredOutput)
        try c.encode(supportsNativeJSONMode, forKey: .supportsNativeJSONMode)
        try c.encode(cancellationStyle, forKey: .cancellationStyle)
        try c.encode(supportsTokenCounting, forKey: .supportsTokenCounting)
        try c.encode(memoryStrategy, forKey: .memoryStrategy)
        try c.encode(isRemote, forKey: .isRemote)
        try c.encode(supportsKVCachePersistence, forKey: .supportsKVCachePersistence)
        try c.encode(supportsGrammarConstrainedSampling, forKey: .supportsGrammarConstrainedSampling)
        try c.encode(supportsThinking, forKey: .supportsThinking)
        try c.encode(supportsVision, forKey: .supportsVision)
        try c.encode(streamsToolCallArguments, forKey: .streamsToolCallArguments)
        try c.encode(supportsParallelToolCalls, forKey: .supportsParallelToolCalls)
        try c.encode(supportsGuidedStructuredOutput, forKey: .supportsGuidedStructuredOutput)
        try c.encode(sharesMLXProcessResources, forKey: .sharesMLXProcessResources)
        try c.encodeIfPresent(maxAdvertisedToolCount, forKey: .maxAdvertisedToolCount)
    }
}
