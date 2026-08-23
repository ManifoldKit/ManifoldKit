import Foundation

/// A generation parameter that a backend may or may not support.
public enum GenerationParameter: String, CaseIterable, Sendable, Codable {
    case temperature
    case topP
    case repeatPenalty
    case topK
    case minP
    case repetitionPenalty
    case presencePenalty
    case frequencyPenalty
    case llamaDRY
    case llamaXTC
    case llamaMirostatV2
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
    /// ``GenerationEvent/thinkingCompleted`` events for reasoning content. Consumers use this
    /// static capability flag to gate thinking-related UI (reasoning disclosure group,
    /// thinking budget slider) rather than inferring it from the active `PromptTemplate`.
    ///
    /// Defaults to `false` for source compatibility. Orthogonal to
    /// `GenerationRuntimeHints.thinkingMarkers`, which is a per-request runtime hint.
    public let supportsThinking: Bool

    /// If true, the backend can consume image parts in ``StructuredMessage`` history.
    ///
    /// UI surfaces use this to gate image-attachment affordances, and the
    /// inference coordinator uses it to fail fast rather than silently dropping
    /// image parts during flattening on text-only backends.
    public let supportsVision: Bool

    /// If true, the backend can consume audio parts in ``StructuredMessage`` history.
    ///
    /// Mirrors ``supportsVision``: UI surfaces use this to gate audio-attachment
    /// affordances, and the inference coordinator uses it to fail fast rather
    /// than silently dropping audio parts during flattening on a backend that
    /// can't hear them (#2353). Defaults to `false` — no backend in this
    /// package sets it `true` yet; `CloudMessageEncoder` has no `.audio` wire
    /// encoding today (tracked separately), so this flag currently only
    /// governs the fail-closed guard, not a live encode path.
    public let supportsAudioInput: Bool

    /// True when the backend emits ``GenerationEvent/toolCallStart(callId:name:)``
    /// and ``GenerationEvent/toolCallArgumentsDelta(callId:textDelta:)`` before
    /// each ``GenerationEvent/toolCall(_:)``. Cloud streaming backends set
    /// `true`; local inline-parser backends and non-streaming HTTP backends
    /// set `false`.
    public let streamsToolCallArguments: Bool

    /// True when the backend can emit multiple ``GenerationEvent/toolCall(_:)``
    /// events in one generation round (parallel batch). Single-call backends
    /// and small local models that only reliably emit one call at a time set
    /// `false`.
    public let supportsParallelToolCalls: Bool

    /// Whether the backend supports Foundation-style guided structured output.
    public let supportsGuidedStructuredOutput: Bool

    /// Whether the backend can emit a *strict* JSON-Schema constraint that
    /// guarantees schema-valid output — OpenAI `strict: true` function tools and
    /// `response_format: {type: "json_schema", strict: true}`, Anthropic's
    /// `structured-outputs-2025-11-13` strict tools / `output_format`.
    ///
    /// When `true`, callers that pass ``StructuredOutputStrategy/jsonSchema(_:)``
    /// via ``GenerationConfig/structuredOutput`` get the schema rewritten into
    /// the provider's strict shape (`additionalProperties: false` on every
    /// object, all properties required) before it hits the wire. Backends that
    /// report `false` (the default) reject `additionalProperties: false` and
    /// keep their legacy structured-output behaviour (e.g. `json_object`).
    ///
    /// Defaults to `false` for source compatibility — only OpenAI and Claude
    /// SaaS backends advertise `true` today.
    public let supportsStrictSchema: Bool

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

    /// Describes the fidelity of the ``GenerationEvent/promptRendered(text:)``
    /// event this backend's generations produce (emitted when
    /// `GenerationConfig.captureRenderedPrompt == true`).
    ///
    /// `true` means `.promptRendered` carries the **complete** submitted prompt —
    /// system prompt + full history + the latest user message, post-template — as
    /// a single string. This is the case for local/on-device backends that apply
    /// a chat template to the whole conversation before generation.
    ///
    /// `false` means `.promptRendered` carries only a **partial** view (typically
    /// just the most recent user message), because the full prompt is assembled
    /// on the wire as a structured message array and is not recoverable as one
    /// rendered string. This is the case for cloud chat-completion / messages
    /// backends (Anthropic, OpenAI, Ollama, any SSE cloud backend).
    ///
    /// Intended to let a consumer honestly label a captured rendered prompt as
    /// full vs partial — but no in-tree reader exists yet: every backend sets
    /// this field and nothing in this package reads it back (the Prompt
    /// Inspector surface reads `.promptRendered` events directly, not this
    /// flag). Kept as a producer-side capability seam. (It is a struct field, so
    /// the inert-surface audit — which scans types and top-level funcs, not
    /// members — does not track it directly.) Defaults to `false` — a backend
    /// that does not opt in is conservatively assumed to render only a partial
    /// prompt.
    public let rendersFullPrompt: Bool

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

    /// The tool-call dialect this backend selects when `supportsToolCalling` is
    /// `true` — the delimiters, argument encoding, and extractability that
    /// describe *how* this (model × backend × renderer) emits tool calls on the
    /// wire. `nil` when unknown or unsupported.
    ///
    /// This is the capability seam described in
    /// `docs/plans/tool-calling-architecture.md`.
    /// **Producers live in the companion backends**: manifold-mlx and
    /// manifold-llama set it from the loaded model's family (their renderers
    /// already pick a per-family dialect internally). **Core defines the seam
    /// but has no reader today** — the intended consumer is the #2005
    /// tool-calling recommendation UI, which is not yet built, so every core
    /// backend leaves this `nil` and nothing in this package reads it. Kept
    /// public because it is a companion-set field, not dead code. (The field
    /// itself is a struct member, outside the inert-surface audit's type +
    /// top-level-func scope; its `ToolCallDialect` vocabulary *types* —
    /// `ToolCallDialectFamily`, `ToolCallArgEncoding`, `ToolCallExtractability` —
    /// are the ones the audit tracks, allowlisted as companion-consumed.)
    ///
    /// Additive and optional: a backend that does not opt in leaves this `nil`,
    /// and the existing `supportsToolCalling` bool is unchanged.
    public let toolDialect: ToolCallDialect?

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
        supportsAudioInput: Bool = false,
        streamsToolCallArguments: Bool = false,
        supportsParallelToolCalls: Bool = false,
        supportsGuidedStructuredOutput: Bool = false,
        supportsStrictSchema: Bool = false,
        sharesMLXProcessResources: Bool = false,
        rendersFullPrompt: Bool = false,
        maxAdvertisedToolCount: Int? = nil,
        toolDialect: ToolCallDialect? = nil
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
        self.supportsAudioInput = supportsAudioInput
        self.streamsToolCallArguments = streamsToolCallArguments
        self.supportsParallelToolCalls = supportsParallelToolCalls
        self.supportsGuidedStructuredOutput = supportsGuidedStructuredOutput
        self.supportsStrictSchema = supportsStrictSchema
        self.sharesMLXProcessResources = sharesMLXProcessResources
        self.rendersFullPrompt = rendersFullPrompt
        self.maxAdvertisedToolCount = maxAdvertisedToolCount
        self.toolDialect = toolDialect
    }

    /// Merges an ordered list of capability sets into the "can the composed
    /// runtime as a whole do X?" union — per-flag OR and numeric maxima for
    /// routable capabilities; conservative AND/minimum for guarantees consumed
    /// before routing (`requiresPromptTemplate`, `rendersFullPrompt`,
    /// `maxAdvertisedToolCount`). Each exception is annotated at its merge
    /// line below.
    ///
    /// Originally lifted from `RouterBackend`'s inline merge so the composing
    /// backends (`RouterBackend`, ``FallbackBackend``) share one
    /// implementation and cannot drift. Every stored field is merged explicitly
    /// below — `BackendCapabilitiesFieldCompletenessTests` (Mirror-based) fails
    /// if a future stored field isn't threaded through this function (and
    /// through `updating(...)`, the copy-with helper below).
    ///
    /// An empty list yields a default ``BackendCapabilities``.
    public static func union(_ capabilities: [BackendCapabilities]) -> BackendCapabilities {
        guard let first = capabilities.first else {
            return BackendCapabilities()
        }
        var supportedParameters = first.supportedParameters
        var maxContextTokens = first.maxContextTokens
        var maxOutputTokens = first.maxOutputTokens
        var requiresPromptTemplate = first.requiresPromptTemplate
        var supportsSystemPrompt = first.supportsSystemPrompt
        var supportsStreaming = first.supportsStreaming
        var supportsToolCalling = first.supportsToolCalling
        var supportsStructuredOutput = first.supportsStructuredOutput
        var supportsNativeJSONMode = first.supportsNativeJSONMode
        var cancellationStyle = first.cancellationStyle
        var supportsTokenCounting = first.supportsTokenCounting
        var memoryStrategy = first.memoryStrategy
        var isRemote = first.isRemote
        var supportsKVCachePersistence = first.supportsKVCachePersistence
        var supportsGrammarConstrainedSampling = first.supportsGrammarConstrainedSampling
        var supportsThinking = first.supportsThinking
        var supportsVision = first.supportsVision
        var supportsAudioInput = first.supportsAudioInput
        var streamsToolCallArguments = first.streamsToolCallArguments
        var supportsParallelToolCalls = first.supportsParallelToolCalls
        var supportsGuidedStructuredOutput = first.supportsGuidedStructuredOutput
        var supportsStrictSchema = first.supportsStrictSchema
        var sharesMLXProcessResources = first.sharesMLXProcessResources
        // `rendersFullPrompt` is a fidelity *guarantee*, not a permissive
        // capability: the union answer is "every child renders the full
        // prompt" (AND), because the router picks exactly one child per turn
        // and a caller reading `.promptRendered` can't tell which one served
        // it — false is the conservative default per the field's own doc.
        var rendersFullPrompt = first.rendersFullPrompt
        // `maxAdvertisedToolCount` is most-restrictive-wins: `nil` means "no
        // limit", so the union tightens to the smallest advertised cap seen
        // so far rather than silently widening past a child's real ceiling.
        var maxAdvertisedToolCount = first.maxAdvertisedToolCount
        // Prefer the first non-nil dialect: the union answer is "the runtime can
        // serve a backend that reports *some* dialect" — a discovered dialect
        // beats an unknown one, and we don't try to reconcile conflicting ones.
        var toolDialect = first.toolDialect

        for c in capabilities.dropFirst() {
            supportedParameters.formUnion(c.supportedParameters)
            maxContextTokens = max(maxContextTokens, c.maxContextTokens)
            maxOutputTokens = max(maxOutputTokens, c.maxOutputTokens)
            // `requiresPromptTemplate` is a per-backend rule. The union answer
            // is "the runtime can serve at least one backend that *doesn't*
            // require a template" — false beats true.
            requiresPromptTemplate = requiresPromptTemplate && c.requiresPromptTemplate
            supportsSystemPrompt = supportsSystemPrompt || c.supportsSystemPrompt
            supportsStreaming = supportsStreaming || c.supportsStreaming
            supportsToolCalling = supportsToolCalling || c.supportsToolCalling
            supportsStructuredOutput = supportsStructuredOutput || c.supportsStructuredOutput
            supportsNativeJSONMode = supportsNativeJSONMode || c.supportsNativeJSONMode
            // Pick the more permissive cancellation style — cooperative beats
            // explicit because callers can always stop a cooperative backend
            // by cancelling the Task.
            if c.cancellationStyle == .cooperative { cancellationStyle = .cooperative }
            supportsTokenCounting = supportsTokenCounting || c.supportsTokenCounting
            // Memory strategy: keep `external` if any child is external (cloud
            // path is available); otherwise prefer `mappable` over `resident`.
            memoryStrategy = Self.mergedMemoryStrategy(memoryStrategy, c.memoryStrategy)
            isRemote = isRemote || c.isRemote
            supportsKVCachePersistence = supportsKVCachePersistence || c.supportsKVCachePersistence
            supportsGrammarConstrainedSampling = supportsGrammarConstrainedSampling || c.supportsGrammarConstrainedSampling
            supportsThinking = supportsThinking || c.supportsThinking
            supportsVision = supportsVision || c.supportsVision
            supportsAudioInput = supportsAudioInput || c.supportsAudioInput
            streamsToolCallArguments = streamsToolCallArguments || c.streamsToolCallArguments
            supportsParallelToolCalls = supportsParallelToolCalls || c.supportsParallelToolCalls
            supportsGuidedStructuredOutput = supportsGuidedStructuredOutput || c.supportsGuidedStructuredOutput
            supportsStrictSchema = supportsStrictSchema || c.supportsStrictSchema
            sharesMLXProcessResources = sharesMLXProcessResources || c.sharesMLXProcessResources
            rendersFullPrompt = rendersFullPrompt && c.rendersFullPrompt
            maxAdvertisedToolCount = Self.mergedToolCountCap(maxAdvertisedToolCount, c.maxAdvertisedToolCount)
            if toolDialect == nil { toolDialect = c.toolDialect }
        }
        return BackendCapabilities(
            supportedParameters: supportedParameters,
            maxContextTokens: maxContextTokens,
            requiresPromptTemplate: requiresPromptTemplate,
            supportsSystemPrompt: supportsSystemPrompt,
            supportsToolCalling: supportsToolCalling,
            supportsStructuredOutput: supportsStructuredOutput,
            supportsNativeJSONMode: supportsNativeJSONMode,
            cancellationStyle: cancellationStyle,
            supportsTokenCounting: supportsTokenCounting,
            memoryStrategy: memoryStrategy,
            maxOutputTokens: maxOutputTokens,
            supportsStreaming: supportsStreaming,
            isRemote: isRemote,
            supportsKVCachePersistence: supportsKVCachePersistence,
            supportsGrammarConstrainedSampling: supportsGrammarConstrainedSampling,
            supportsThinking: supportsThinking,
            supportsVision: supportsVision,
            supportsAudioInput: supportsAudioInput,
            streamsToolCallArguments: streamsToolCallArguments,
            supportsParallelToolCalls: supportsParallelToolCalls,
            supportsGuidedStructuredOutput: supportsGuidedStructuredOutput,
            supportsStrictSchema: supportsStrictSchema,
            sharesMLXProcessResources: sharesMLXProcessResources,
            rendersFullPrompt: rendersFullPrompt,
            maxAdvertisedToolCount: maxAdvertisedToolCount,
            toolDialect: toolDialect
        )
    }

    private static func mergedMemoryStrategy(_ a: MemoryStrategy, _ b: MemoryStrategy) -> MemoryStrategy {
        // Preference order for "the most permissive" runtime memory profile:
        // external (no local footprint) → mappable (paged) → resident (full RAM).
        if a == .external || b == .external { return .external }
        if a == .mappable || b == .mappable { return .mappable }
        return .resident
    }

    /// Most-restrictive-wins merge for `maxAdvertisedToolCount`: `nil` means
    /// "no limit", so two non-nil caps merge to their minimum (the tighter
    /// constraint governs regardless of which child actually serves a turn).
    private static func mergedToolCountCap(_ a: Int?, _ b: Int?) -> Int? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let x?, nil): return x
        case (nil, let y?): return y
        case (let x?, let y?): return min(x, y)
        }
    }

    /// Returns a copy of this capability set with the given fields overridden;
    /// every field not passed keeps its current value.
    ///
    /// Exists so call sites that need to override one or two fields (e.g.
    /// clamping `maxContextTokens` to a runtime-derived plan value) don't
    /// hand-rebuild the full ~25-field literal — a fresh-literal rebuild
    /// silently zeroes every field the call site doesn't list, which is
    /// exactly the bug this method exists to make impossible (the backend
    /// whose `loadModel` motivated this method, `AnyLanguageModelBackend`,
    /// was retired in #2435; the field-completeness contract stays load-bearing
    /// for every backend that still hand-assembles `BackendCapabilities`).
    ///
    /// The two `Optional`-typed stored fields (`maxAdvertisedToolCount`,
    /// `toolDialect`) take a double-optional parameter, the standard
    /// copy-with shape: omit the argument (default `.none`) to keep the
    /// current value, or pass `.some(nil)` / a value to override to `nil` or
    /// to something new.
    public func updating(
        supportedParameters: Set<GenerationParameter>? = nil,
        maxContextTokens: Int32? = nil,
        requiresPromptTemplate: Bool? = nil,
        supportsSystemPrompt: Bool? = nil,
        supportsToolCalling: Bool? = nil,
        supportsStructuredOutput: Bool? = nil,
        supportsNativeJSONMode: Bool? = nil,
        cancellationStyle: CancellationStyle? = nil,
        supportsTokenCounting: Bool? = nil,
        memoryStrategy: MemoryStrategy? = nil,
        maxOutputTokens: Int? = nil,
        supportsStreaming: Bool? = nil,
        isRemote: Bool? = nil,
        supportsKVCachePersistence: Bool? = nil,
        supportsGrammarConstrainedSampling: Bool? = nil,
        supportsThinking: Bool? = nil,
        supportsVision: Bool? = nil,
        supportsAudioInput: Bool? = nil,
        streamsToolCallArguments: Bool? = nil,
        supportsParallelToolCalls: Bool? = nil,
        supportsGuidedStructuredOutput: Bool? = nil,
        supportsStrictSchema: Bool? = nil,
        sharesMLXProcessResources: Bool? = nil,
        rendersFullPrompt: Bool? = nil,
        maxAdvertisedToolCount: Int?? = nil,
        toolDialect: ToolCallDialect?? = nil
    ) -> BackendCapabilities {
        BackendCapabilities(
            supportedParameters: supportedParameters ?? self.supportedParameters,
            maxContextTokens: maxContextTokens ?? self.maxContextTokens,
            requiresPromptTemplate: requiresPromptTemplate ?? self.requiresPromptTemplate,
            supportsSystemPrompt: supportsSystemPrompt ?? self.supportsSystemPrompt,
            supportsToolCalling: supportsToolCalling ?? self.supportsToolCalling,
            supportsStructuredOutput: supportsStructuredOutput ?? self.supportsStructuredOutput,
            supportsNativeJSONMode: supportsNativeJSONMode ?? self.supportsNativeJSONMode,
            cancellationStyle: cancellationStyle ?? self.cancellationStyle,
            supportsTokenCounting: supportsTokenCounting ?? self.supportsTokenCounting,
            memoryStrategy: memoryStrategy ?? self.memoryStrategy,
            maxOutputTokens: maxOutputTokens ?? self.maxOutputTokens,
            supportsStreaming: supportsStreaming ?? self.supportsStreaming,
            isRemote: isRemote ?? self.isRemote,
            supportsKVCachePersistence: supportsKVCachePersistence ?? self.supportsKVCachePersistence,
            supportsGrammarConstrainedSampling: supportsGrammarConstrainedSampling ?? self.supportsGrammarConstrainedSampling,
            supportsThinking: supportsThinking ?? self.supportsThinking,
            supportsVision: supportsVision ?? self.supportsVision,
            supportsAudioInput: supportsAudioInput ?? self.supportsAudioInput,
            streamsToolCallArguments: streamsToolCallArguments ?? self.streamsToolCallArguments,
            supportsParallelToolCalls: supportsParallelToolCalls ?? self.supportsParallelToolCalls,
            supportsGuidedStructuredOutput: supportsGuidedStructuredOutput ?? self.supportsGuidedStructuredOutput,
            supportsStrictSchema: supportsStrictSchema ?? self.supportsStrictSchema,
            sharesMLXProcessResources: sharesMLXProcessResources ?? self.sharesMLXProcessResources,
            rendersFullPrompt: rendersFullPrompt ?? self.rendersFullPrompt,
            maxAdvertisedToolCount: maxAdvertisedToolCount ?? self.maxAdvertisedToolCount,
            toolDialect: toolDialect ?? self.toolDialect
        )
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
        case supportsAudioInput
        case streamsToolCallArguments
        case supportsParallelToolCalls
        case supportsGuidedStructuredOutput
        case supportsStrictSchema
        case sharesMLXProcessResources
        case rendersFullPrompt
        case maxAdvertisedToolCount
        case toolDialect
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        supportedParameters = try c.decode(Set<GenerationParameter>.self, forKey: .supportedParameters)
        maxContextTokens = try c.decode(Int32.self, forKey: .maxContextTokens)
        maxOutputTokens = try c.decode(Int.self, forKey: .maxOutputTokens)
        // Boolean flags decode tolerantly: an older/partial capabilities blob
        // missing a now-required flag falls back to the memberwise-init default
        // rather than throwing keyNotFound. Structural keys below stay required.
        requiresPromptTemplate = (try c.decodeIfPresent(Bool.self, forKey: .requiresPromptTemplate)) ?? false
        supportsSystemPrompt = (try c.decodeIfPresent(Bool.self, forKey: .supportsSystemPrompt)) ?? true
        supportsStreaming = (try c.decodeIfPresent(Bool.self, forKey: .supportsStreaming)) ?? true
        supportsToolCalling = (try c.decodeIfPresent(Bool.self, forKey: .supportsToolCalling)) ?? false
        supportsStructuredOutput = (try c.decodeIfPresent(Bool.self, forKey: .supportsStructuredOutput)) ?? false
        supportsNativeJSONMode = (try c.decodeIfPresent(Bool.self, forKey: .supportsNativeJSONMode)) ?? false
        cancellationStyle = try c.decode(CancellationStyle.self, forKey: .cancellationStyle)
        supportsTokenCounting = (try c.decodeIfPresent(Bool.self, forKey: .supportsTokenCounting)) ?? false
        memoryStrategy = try c.decode(MemoryStrategy.self, forKey: .memoryStrategy)
        isRemote = (try c.decodeIfPresent(Bool.self, forKey: .isRemote)) ?? false
        supportsKVCachePersistence = (try c.decodeIfPresent(Bool.self, forKey: .supportsKVCachePersistence)) ?? false
        supportsGrammarConstrainedSampling = (try c.decodeIfPresent(Bool.self, forKey: .supportsGrammarConstrainedSampling)) ?? false
        supportsThinking = (try c.decodeIfPresent(Bool.self, forKey: .supportsThinking)) ?? false
        supportsVision = (try c.decodeIfPresent(Bool.self, forKey: .supportsVision)) ?? false
        supportsAudioInput = (try c.decodeIfPresent(Bool.self, forKey: .supportsAudioInput)) ?? false
        streamsToolCallArguments = (try c.decodeIfPresent(Bool.self, forKey: .streamsToolCallArguments)) ?? false
        supportsParallelToolCalls = (try c.decodeIfPresent(Bool.self, forKey: .supportsParallelToolCalls)) ?? false
        supportsGuidedStructuredOutput = (try c.decodeIfPresent(Bool.self, forKey: .supportsGuidedStructuredOutput)) ?? false
        supportsStrictSchema = (try c.decodeIfPresent(Bool.self, forKey: .supportsStrictSchema)) ?? false
        sharesMLXProcessResources = (try c.decodeIfPresent(Bool.self, forKey: .sharesMLXProcessResources)) ?? false
        rendersFullPrompt = (try c.decodeIfPresent(Bool.self, forKey: .rendersFullPrompt)) ?? false
        maxAdvertisedToolCount = try c.decodeIfPresent(Int.self, forKey: .maxAdvertisedToolCount)
        toolDialect = try c.decodeIfPresent(ToolCallDialect.self, forKey: .toolDialect)
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
        try c.encode(supportsAudioInput, forKey: .supportsAudioInput)
        try c.encode(streamsToolCallArguments, forKey: .streamsToolCallArguments)
        try c.encode(supportsParallelToolCalls, forKey: .supportsParallelToolCalls)
        try c.encode(supportsGuidedStructuredOutput, forKey: .supportsGuidedStructuredOutput)
        try c.encode(supportsStrictSchema, forKey: .supportsStrictSchema)
        try c.encode(sharesMLXProcessResources, forKey: .sharesMLXProcessResources)
        try c.encode(rendersFullPrompt, forKey: .rendersFullPrompt)
        try c.encodeIfPresent(maxAdvertisedToolCount, forKey: .maxAdvertisedToolCount)
        try c.encodeIfPresent(toolDialect, forKey: .toolDialect)
    }
}
