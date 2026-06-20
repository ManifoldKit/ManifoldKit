import Foundation

/// llama.cpp DRY sampler configuration.
///
/// DRY ("Don't Repeat Yourself") penalizes tokens that would extend repeated
/// token sequences. This is llama.cpp-specific: other backends ignore it. The
/// defaults mirror llama.cpp's `common_params_sampling` defaults; keep
/// ``GenerationConfig/llamaDRY`` `nil` to preserve each backend's sampler chain.
public struct LlamaDRYSamplerOptions: Sendable, Codable, Equatable {
    /// Penalty multiplier. `0.0` disables DRY in llama.cpp.
    public var multiplier: Float
    /// Exponential penalty base. llama.cpp treats values below `1.0` as disabled.
    public var base: Float
    /// Repetition length allowed before DRY applies a penalty.
    public var allowedLength: Int32
    /// Number of recent tokens to scan (`-1` = training context, `0` = disabled).
    public var penaltyLastN: Int32
    /// Sequence breakers that reset repetition scanning.
    public var sequenceBreakers: [String]

    public init(
        multiplier: Float = 0.0,
        base: Float = 1.75,
        allowedLength: Int32 = 2,
        penaltyLastN: Int32 = -1,
        sequenceBreakers: [String] = ["\n", ":", "\"", "*"]
    ) {
        self.multiplier = multiplier
        self.base = base
        self.allowedLength = allowedLength
        self.penaltyLastN = penaltyLastN
        self.sequenceBreakers = sequenceBreakers
    }
}

/// llama.cpp XTC ("Exclude Top Choices") sampler configuration.
///
/// XTC trims the highest-probability tokens to push variety; popular in creative
/// writing presets. llama.cpp inserts XTC after the temperature step. This is
/// llama.cpp-specific: other backends ignore it. Defaults mirror llama.cpp's
/// `common_params_sampling` (`probability = 0.0` = disabled in the library).
public struct LlamaXTCSamplerOptions: Sendable, Codable, Equatable {
    /// Probability of applying XTC at each step. `0.0` disables XTC in llama.cpp.
    public var probability: Float
    /// Probability threshold below which tokens are not excluded.
    public var threshold: Float
    /// Minimum number of tokens to keep after exclusion.
    public var minKeep: Int
    /// Sampler seed; `nil` falls back to ``GenerationConfig/seed`` or a random value.
    public var seed: UInt32?

    public init(
        probability: Float = 0.0,
        threshold: Float = 0.10,
        minKeep: Int = 1,
        seed: UInt32? = nil
    ) {
        self.probability = probability
        self.threshold = threshold
        self.minKeep = minKeep
        self.seed = seed
    }
}

/// llama.cpp Mirostat v2 sampler configuration.
///
/// Mirostat v2 is an entropy-controlled sampler — when active, llama.cpp
/// **replaces** the temperature + dist tail of the chain with a single Mirostat
/// step. This is llama.cpp-specific: other backends ignore it. Defaults mirror
/// llama.cpp's `common_params_sampling` (`tau = 5.0`, `eta = 0.1`).
public struct LlamaMirostatV2SamplerOptions: Sendable, Codable, Equatable {
    /// Target cross-entropy (surprise). Higher = more variety.
    public var tau: Float
    /// Learning rate for the mu update.
    public var eta: Float
    /// Sampler seed; `nil` falls back to ``GenerationConfig/seed`` or a random value.
    public var seed: UInt32?

    public init(
        tau: Float = 5.0,
        eta: Float = 0.1,
        seed: UInt32? = nil
    ) {
        self.tau = tau
        self.eta = eta
        self.seed = seed
    }
}

/// Sampling and generation parameters shared across all inference backends.
///
/// ## Throw vs. silently ignore
///
/// Fields fall into two contractual classes, and backends honour them differently:
///
/// - **Capability-gated guarantees** (e.g. ``GenerationConfig/grammar``) carry a
///   *guarantee*: a backend that cannot honour the request MUST throw the matching
///   ``InferenceError`` (e.g. ``InferenceError/unsupportedGrammar``) rather than
///   silently degrade. Callers rely on the error to know the constraint was not applied.
/// - **Advisory hints** (e.g. ``seed``, ``minP``, ``jsonMode``, the sampler penalties,
///   and the vendor knobs below) are best-effort: backends that do not support a hint
///   silently ignore it. A missing hint is never an error.
///
/// See each field's own documentation for the per-backend specifics.
///
/// ## Codable round-trip is intentionally lossy
///
/// `GenerationConfig` conforms to `Codable` so it can be persisted (e.g. as a
/// sampler preset), but three fields are **per-request runtime hints that are
/// never encoded** and always decode back to their defaults:
/// ``GenerationConfig/jsonMode`` (decodes to `false`),
/// ``GenerationConfig/thinkingMarkers`` (decodes to `nil`), and
/// ``GenerationConfig/structuredOutput`` (decodes to `nil`). They are absent
/// from the `CodingKeys`, so an encode-then-decode cycle silently drops them.
/// Do not rely on Codable round-trip to preserve these fields — carry them
/// alongside the persisted config at the call site if you need them to survive.
public struct GenerationConfig: Sendable, Codable {
    public var temperature: Float
    public var topP: Float
    public var repeatPenalty: Float
    public var topK: Int32?
    public var typicalP: Float?

    /// Min-p sampling threshold relative to the highest-probability token.
    ///
    /// An alternative to top-p that filters tokens by probability ratio rather than
    /// cumulative mass. `nil` (the default) lets each backend apply its own value.
    /// Mirrors `GenerateParameters.minP` in `mlx-swift-lm`. Honoured by `MLXBackend`
    /// and `LlamaBackend`; backends that do not expose a min-p sampler ignore it.
    public var minP: Float?

    /// Repetition penalty applied to recently-generated tokens (1.0 = no penalty).
    ///
    /// Distinct from ``repeatPenalty`` only in shape — kept as a separate optional so
    /// callers can leave it `nil` and inherit the backend's default behaviour. When
    /// non-`nil` this value takes precedence over ``repeatPenalty`` for backends that
    /// support an explicit knob (MLX, llama.cpp). Backends that do not expose a
    /// repetition penalty (e.g. `FoundationBackend`) ignore it.
    public var repetitionPenalty: Float?

    /// Window size (in recent tokens) over which ``repetitionPenalty`` applies.
    ///
    /// `nil` lets each backend use its own default — llama.cpp uses 64, mlx-swift-lm
    /// uses 20. Honoured by `MLXBackend` and `LlamaBackend`; other backends ignore.
    public var repetitionContextSize: Int?

    /// Additive penalty for tokens that already appeared in the recent window
    /// (OpenAI-style "presence" penalty, distinct from the multiplicative
    /// ``repetitionPenalty``).
    ///
    /// `nil` (the default) lets each backend apply no presence penalty. Honoured by
    /// `MLXBackend` (mapped to `GenerateParameters.presencePenalty`) and
    /// `LlamaBackend` (mapped to the third arg of `llama_sampler_init_penalties`).
    /// Other backends ignore it.
    public var presencePenalty: Float?

    /// Window size (in recent tokens) over which ``presencePenalty`` applies.
    ///
    /// `nil` lets each backend use its own default. MLX exposes this as a separate
    /// knob from ``repetitionContextSize``; llama.cpp shares one window for all three
    /// penalties (repeat, frequency, presence) and ignores this field — the shared
    /// window comes from ``repetitionContextSize``.
    public var presenceContextSize: Int?

    /// Additive penalty that scales with how often each token has already
    /// appeared in the recent window (OpenAI-style "frequency" penalty).
    ///
    /// `nil` (the default) lets each backend apply no frequency penalty. Honoured by
    /// `MLXBackend` and `LlamaBackend`; other backends ignore.
    public var frequencyPenalty: Float?

    /// Window size (in recent tokens) over which ``frequencyPenalty`` applies.
    ///
    /// `nil` lets each backend use its own default. MLX-only — see
    /// ``presenceContextSize`` for why llama.cpp ignores it.
    public var frequencyContextSize: Int?

    // The three `llama*` fields below are backend-specific knobs living on the
    // shared GenerationConfig type. This is accepted tech debt: relocating them
    // into the companion llama package is deferred (cross-repo blast radius) and
    // tracked in #1834.

    /// llama.cpp DRY repetition sampler options.
    ///
    /// `nil` (the default) preserves the backend's existing sampler chain. When
    /// set, `LlamaBackend` inserts `llama_sampler_init_dry` after penalties
    /// and grammar, before probability filters. Other backends ignore it.
    public var llamaDRY: LlamaDRYSamplerOptions?

    /// llama.cpp XTC sampler options.
    ///
    /// `nil` (the default) preserves the backend's existing sampler chain. When
    /// set, `LlamaBackend` inserts `llama_sampler_init_xtc` immediately after
    /// the temperature step. Other backends ignore it.
    public var llamaXTC: LlamaXTCSamplerOptions?

    /// llama.cpp Mirostat v2 sampler options.
    ///
    /// `nil` (the default) preserves the backend's existing sampler chain. When
    /// set, `LlamaBackend` **replaces** the temperature + dist sampler tail
    /// with `llama_sampler_init_mirostat_v2`. Other backends ignore it.
    public var llamaMirostatV2: LlamaMirostatV2SamplerOptions?

    /// Deterministic sampling seed.
    ///
    /// When set, backends that expose a sampler seed (`MLXBackend`,
    /// `LlamaBackend`) initialise their RNG from this value so two runs with the
    /// same prompt and config produce the same token stream. Backends that do not
    /// expose a seed (`FoundationBackend`, cloud backends without a `seed` API
    /// parameter) silently ignore it — a missing seed is never an error.
    /// Stored as `UInt64` for parity with mlx-swift-lm; backends with smaller seed
    /// types (e.g. llama.cpp's `uint32_t`) truncate.
    public var seed: UInt64?

    /// Maximum number of tokens the model should generate in a single response.
    ///
    /// Cloud backends send this as their `max_tokens` API parameter.
    /// Local backends (Foundation, MLX, llama.cpp) use it to cap the generation loop.
    ///
    /// The initializer **defaults this to 2048**, a safety cap against runaway
    /// generation and cost. Long-form output (summaries, code generation, RAG
    /// answers) will be truncated at 2048 tokens unless you raise it. Pass
    /// `maxOutputTokens: nil` explicitly to remove the cap and fall back to the
    /// backend's own default limit. `nil` is never the default.
    public var maxOutputTokens: Int?

    /// Tool definitions made available to the model for this generation request.
    ///
    /// Only honoured by backends that set ``BackendCapabilities/supportsToolCalling``
    /// to `true`.  Backends that do not support tool calling silently ignore this
    /// field.  Defaults to an empty array (no tools).
    public var tools: [ToolDefinition]

    /// Controls which tool, if any, the backend is allowed to call.
    ///
    /// Only honoured when ``tools`` is non-empty and the backend supports tool
    /// calling.  Defaults to ``ToolChoice/auto``.
    public var toolChoice: ToolChoice

    /// Cap on reasoning (chain-of-thought) tokens for a single generation.
    ///
    /// - `nil` — no client-side cap. Backends reserve a default thinking budget
    ///   only when the loaded model is known to be a thinking model (Ollama
    ///   detects this via `/api/show`; Llama uses the prompt template's
    ///   `thinkingMarkers`). Non-thinking models add no reservation.
    /// - `0` — **disable thinking entirely.** On supporting backends (Ollama
    ///   with thinking-capable models, MLX/Llama with reasoning GGUFs), this
    ///   instructs the model to skip the reasoning phase and emit visible
    ///   output directly. On non-thinking models this is a no-op after
    ///   `GenerationQueue` emits an explicit unsupported-thinking warning.
    /// - `N > 0` — cap thinking tokens at `N`; additional reasoning tokens are
    ///   dropped. Visible output is still produced.
    ///
    /// See `OllamaBackend` for the wire-level mapping (`"think": false` when
    /// `0`, `num_predict` reservation when `N`). `LlamaGenerationDriver` also
    /// enforces the `N`-case cap; backends that do not honour the `0`-case
    /// today may start the reasoning phase anyway — that's deferred work.
    ///
    /// Note: lives on GenerationConfig as a per-request hint. Will move to
    /// BackendCapabilities when a backend-level thinking-capability flag is
    /// added.
    public var maxThinkingTokens: Int?

    /// Requests backend-specific JSON-object-only generation for this call.
    ///
    /// Runtime-only flag: defaults to `false` and is intentionally excluded
    /// from Codable persistence, matching other per-request hints like
    /// ``thinkingMarkers``. Backends that do not support structured output, or
    /// have not implemented JSON-mode wiring yet, silently ignore this flag.
    public var jsonMode: Bool

    /// Opt-in for backend-specific prefill-progress streaming extensions.
    ///
    /// When `true`, OpenAI-compatible backends add
    /// `X-Manifold-Prefill-Progress: true` so compatible servers can emit
    /// `prefill_progress` SSE updates before the first content token.
    /// Defaults to `false` for OpenAI wire compatibility.
    public var streamPrefillProgress: Bool

    /// Raw GBNF grammar string to constrain sampling.
    ///
    /// Honored by backends reporting `BackendCapabilities.supportsGrammarConstrainedSampling == true`.
    /// Backends that see a non-nil grammar but do not support grammar sampling MUST throw
    /// `InferenceError.unsupportedGrammar(reason:)` rather than silently ignore — silent fallback
    /// would turn a guaranteed-valid expectation into an unchecked one.
    /// Defaults to `nil` (no grammar constraint).
    public var grammar: String?

    /// Routed structured-output strategy for this generation request.
    ///
    /// Runtime-only hint: callers can use ``StructuredOutputRouter`` to choose a
    /// strategy from backend capabilities, then pass it through config without
    /// forcing every backend to understand every representation.
    public var structuredOutput: StructuredOutputStrategy?

    /// Per-request override for the thinking-marker pair the backend should use
    /// to split reasoning tokens from visible output.
    ///
    /// - `nil` — let the backend use whatever it auto-detected when the model
    ///   was loaded (e.g. by reading the Jinja chat template from the GGUF or
    ///   `tokenizer_config.json`). If the backend's auto-detection also
    ///   returned `nil`, no thinking parsing happens — every chunk surfaces
    ///   as a plain `.token` event.
    /// - non-`nil` — overrides whatever the backend auto-detected. Use this
    ///   when the caller knows better (e.g. a fine-tune that ships an empty
    ///   chat template but still emits `<think>` blocks at runtime).
    ///
    /// `GenerationQueue` emits an explicit warning when callers pass markers
    /// to a backend with `BackendCapabilities.supportsThinking == false`.
    /// There is no longer a hardcoded fallback to `.qwen3` — if neither
    /// auto-detection nor the caller surfaces markers, the parser stays off.
    public var thinkingMarkers: ThinkingMarkers?

    /// Maximum number of tool-call iterations permitted inside a single
    /// generation request.
    ///
    /// When the coordinator detects a ``ToolCall`` in the stream it dispatches
    /// the call, appends the ``ToolResult``, and re-prompts the model. Each
    /// round trip is one "iteration". This cap bounds runaway tool-call loops
    /// where a misbehaving model keeps requesting tools without finalising a
    /// user-visible response.
    ///
    /// Defaults to `10`. Values `<= 0` are silently clamped to `1` — a zero
    /// budget would prevent any tool dispatch at all and is never the intent.
    public var maxToolIterations: Int {
        didSet { if maxToolIterations < 1 { maxToolIterations = 1 } }
    }

    /// Optional run-level token ceiling for a single tool-dispatch turn.
    ///
    /// Sibling to ``maxToolIterations``: where that bounds the *number* of
    /// tool round-trips, this bounds the cumulative token spend across them.
    /// The orchestrator accumulates the prompt + completion tokens reported by
    /// each generation's terminal ``GenerationEvent/usage(_:)`` and, **at the
    /// tool-iteration boundary** (after a generation finishes, before the next
    /// one is dispatched), aborts the turn when the running total reaches this
    /// ceiling — emitting ``GenerationEvent/runTokenBudgetExceeded(tokensUsed:limit:)``
    /// and a terminal ``GenerationCompletion/Reason/runTokenBudget``. Mirrors
    /// OpenAI Agents' `max_turns` budget and LiteLLM's `max_budget`.
    ///
    /// - `nil` (the default) — no token ceiling; turns run until iteration
    ///   limit, organic stop, or another guard fires. Preserves existing
    ///   zero-config behaviour.
    /// - non-`nil` — the cumulative token budget. Values `<= 0` disable the
    ///   ceiling (treated as no limit) since a zero budget would abort before
    ///   any useful work.
    ///
    /// Enforcement is deliberately at the iteration boundary, not mid-stream:
    /// cloud backends only report usage at end-of-generation, so a mid-single-
    /// generation hard abort is not reliably checkable and is out of scope. A
    /// runaway *single* generation is bounded by ``maxOutputTokens``; this
    /// ceiling bounds runaway *multi-iteration* tool loops.
    public var maxRunTokens: Int?

    /// Number of tokens between brief cooperative yields during MLX generation.
    ///
    /// Sustained MLX inference on Mac can starve WindowServer's GPU command
    /// queue and cause hitches in other apps. To mitigate this, `MLXBackend`
    /// inserts a cooperative `Task.yield()` every `yieldEveryNTokens` tokens.
    ///
    /// - Defaults to `8` (one yield per ~8 tokens).
    /// - `0` disables the yield entirely.
    /// - Only honoured by `MLXBackend`; other backends ignore this field.
    public var yieldEveryNTokens: Int = 8

    /// Capabilities the backend serving this request must provide.
    ///
    /// Empty (the default) means any wired backend may serve the request —
    /// preserves the existing zero-config behaviour. When non-empty, `RouterBackend`
    /// dispatches to the first child whose ``BackendCapabilities`` satisfy every
    /// requirement; backends used directly may use this for fail-fast validation.
    /// Independent of ``tools`` / ``grammar`` / ``jsonMode`` — those are
    /// per-request payloads; this is a per-request *contract*.
    public var requiredCapabilities: Set<GenerationCapabilityRequirement> = []

    /// When `true`, the orchestration layer emits a
    /// ``GenerationEvent/promptRendered(text:)`` event as the first event
    /// in the generation stream, carrying the fully-assembled prompt string.
    ///
    /// Off by default (`false`) to avoid unintentional retention of
    /// sensitive prompt content. Only set this when you need to inspect or
    /// log the rendered prompt for debugging — do not leave it on in
    /// production builds that handle private user data.
    ///
    /// Runtime-only flag: excluded from `Codable` persistence to match
    /// other per-request hints like ``thinkingMarkers`` and ``jsonMode``.
    public var captureRenderedPrompt: Bool = false

    public init(
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        topK: Int32? = nil,
        typicalP: Float? = nil,
        minP: Float? = nil,
        repetitionPenalty: Float? = nil,
        repetitionContextSize: Int? = nil,
        presencePenalty: Float? = nil,
        presenceContextSize: Int? = nil,
        frequencyPenalty: Float? = nil,
        frequencyContextSize: Int? = nil,
        llamaDRY: LlamaDRYSamplerOptions? = nil,
        llamaXTC: LlamaXTCSamplerOptions? = nil,
        llamaMirostatV2: LlamaMirostatV2SamplerOptions? = nil,
        seed: UInt64? = nil,
        maxOutputTokens: Int? = 2048,
        tools: [ToolDefinition] = [],
        toolChoice: ToolChoice = .auto,
        maxThinkingTokens: Int? = nil,
        jsonMode: Bool = false,
        streamPrefillProgress: Bool = false,
        thinkingMarkers: ThinkingMarkers? = nil,
        maxToolIterations: Int = 10,
        maxRunTokens: Int? = nil,
        grammar: String? = nil,
        structuredOutput: StructuredOutputStrategy? = nil,
        yieldEveryNTokens: Int = 8,
        requiredCapabilities: Set<GenerationCapabilityRequirement> = []
    ) {
        self.temperature = temperature
        self.topP = topP
        self.repeatPenalty = repeatPenalty
        self.topK = topK
        self.typicalP = typicalP
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.repetitionContextSize = repetitionContextSize
        self.presencePenalty = presencePenalty
        self.presenceContextSize = presenceContextSize
        self.frequencyPenalty = frequencyPenalty
        self.frequencyContextSize = frequencyContextSize
        self.llamaDRY = llamaDRY
        self.llamaXTC = llamaXTC
        self.llamaMirostatV2 = llamaMirostatV2
        self.seed = seed
        self.maxOutputTokens = maxOutputTokens
        self.tools = tools
        self.toolChoice = toolChoice
        self.maxThinkingTokens = maxThinkingTokens
        self.jsonMode = jsonMode
        self.streamPrefillProgress = streamPrefillProgress
        self.thinkingMarkers = thinkingMarkers
        self.maxToolIterations = max(1, maxToolIterations)
        self.maxRunTokens = maxRunTokens
        self.grammar = grammar
        self.structuredOutput = structuredOutput
        self.yieldEveryNTokens = yieldEveryNTokens
        self.requiredCapabilities = requiredCapabilities
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case temperature, topP, repeatPenalty, topK, typicalP, maxOutputTokens
        case tools, toolChoice, maxThinkingTokens, maxToolIterations, grammar
        case yieldEveryNTokens
        case streamPrefillProgress
        case minP, repetitionPenalty, seed
        case repetitionContextSize
        case presencePenalty, presenceContextSize
        case frequencyPenalty, frequencyContextSize
        case llamaDRY
        case llamaXTC
        case llamaMirostatV2
        case requiredCapabilities
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        temperature = try c.decode(Float.self, forKey: .temperature)
        topP = try c.decode(Float.self, forKey: .topP)
        repeatPenalty = try c.decode(Float.self, forKey: .repeatPenalty)
        topK = try c.decodeIfPresent(Int32.self, forKey: .topK)
        typicalP = try c.decodeIfPresent(Float.self, forKey: .typicalP)
        maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        // New fields added after the original shape; absent from older payloads.
        tools = (try c.decodeIfPresent([ToolDefinition].self, forKey: .tools)) ?? []
        toolChoice = (try c.decodeIfPresent(ToolChoice.self, forKey: .toolChoice)) ?? .auto
        maxThinkingTokens = try c.decodeIfPresent(Int.self, forKey: .maxThinkingTokens)
        // jsonMode is a per-request runtime hint; persisted payloads always decode
        // with the canonical default regardless of any legacy on-disk key.
        jsonMode = false
        streamPrefillProgress = (try c.decodeIfPresent(Bool.self, forKey: .streamPrefillProgress)) ?? false
        // maxToolIterations landed after the original shape; default to 10 when absent and
        // clamp any persisted zero/negative value to the minimum of 1.
        let decodedIterations = (try c.decodeIfPresent(Int.self, forKey: .maxToolIterations)) ?? 10
        maxToolIterations = max(1, decodedIterations)
        // maxRunTokens is a per-request runtime hint; it is not persisted (same
        // policy as thinkingMarkers / structuredOutput).
        maxRunTokens = nil
        // thinkingMarkers is a per-request runtime hint; it is not persisted.
        thinkingMarkers = nil
        grammar = try c.decodeIfPresent(String.self, forKey: .grammar)
        // structuredOutput is a per-request runtime hint; it is not persisted.
        structuredOutput = nil
        // yieldEveryNTokens landed after the original shape; default to 8 when absent.
        yieldEveryNTokens = (try c.decodeIfPresent(Int.self, forKey: .yieldEveryNTokens)) ?? 8
        // minP / repetitionPenalty / seed landed after the original shape; absent
        // from older payloads, default to nil so the backend's own defaults apply.
        minP = try c.decodeIfPresent(Float.self, forKey: .minP)
        repetitionPenalty = try c.decodeIfPresent(Float.self, forKey: .repetitionPenalty)
        seed = try c.decodeIfPresent(UInt64.self, forKey: .seed)
        // repetitionContextSize / presencePenalty / presenceContextSize / frequencyPenalty /
        // frequencyContextSize landed after the above; absent from older payloads,
        // default to nil so each backend applies its own default.
        repetitionContextSize = try c.decodeIfPresent(Int.self, forKey: .repetitionContextSize)
        presencePenalty = try c.decodeIfPresent(Float.self, forKey: .presencePenalty)
        presenceContextSize = try c.decodeIfPresent(Int.self, forKey: .presenceContextSize)
        frequencyPenalty = try c.decodeIfPresent(Float.self, forKey: .frequencyPenalty)
        frequencyContextSize = try c.decodeIfPresent(Int.self, forKey: .frequencyContextSize)
        llamaDRY = try c.decodeIfPresent(LlamaDRYSamplerOptions.self, forKey: .llamaDRY)
        llamaXTC = try c.decodeIfPresent(LlamaXTCSamplerOptions.self, forKey: .llamaXTC)
        llamaMirostatV2 = try c.decodeIfPresent(LlamaMirostatV2SamplerOptions.self, forKey: .llamaMirostatV2)
        // requiredCapabilities is a per-request runtime contract; landed after
        // the original shape, so older payloads decode to an empty set.
        requiredCapabilities = (try c.decodeIfPresent(
            Set<GenerationCapabilityRequirement>.self,
            forKey: .requiredCapabilities
        )) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(topP, forKey: .topP)
        try c.encode(repeatPenalty, forKey: .repeatPenalty)
        try c.encodeIfPresent(topK, forKey: .topK)
        try c.encodeIfPresent(typicalP, forKey: .typicalP)
        try c.encodeIfPresent(maxOutputTokens, forKey: .maxOutputTokens)
        try c.encode(tools, forKey: .tools)
        try c.encode(toolChoice, forKey: .toolChoice)
        try c.encodeIfPresent(maxThinkingTokens, forKey: .maxThinkingTokens)
        try c.encode(streamPrefillProgress, forKey: .streamPrefillProgress)
        try c.encode(maxToolIterations, forKey: .maxToolIterations)
        try c.encodeIfPresent(grammar, forKey: .grammar)
        try c.encode(yieldEveryNTokens, forKey: .yieldEveryNTokens)
        try c.encodeIfPresent(minP, forKey: .minP)
        try c.encodeIfPresent(repetitionPenalty, forKey: .repetitionPenalty)
        try c.encodeIfPresent(seed, forKey: .seed)
        try c.encodeIfPresent(repetitionContextSize, forKey: .repetitionContextSize)
        try c.encodeIfPresent(presencePenalty, forKey: .presencePenalty)
        try c.encodeIfPresent(presenceContextSize, forKey: .presenceContextSize)
        try c.encodeIfPresent(frequencyPenalty, forKey: .frequencyPenalty)
        try c.encodeIfPresent(frequencyContextSize, forKey: .frequencyContextSize)
        try c.encodeIfPresent(llamaDRY, forKey: .llamaDRY)
        try c.encodeIfPresent(llamaXTC, forKey: .llamaXTC)
        try c.encodeIfPresent(llamaMirostatV2, forKey: .llamaMirostatV2)
        if !requiredCapabilities.isEmpty {
            try c.encode(requiredCapabilities, forKey: .requiredCapabilities)
        }
    }
}

/// Common interface for inference backends.
///
/// Each backend wraps a different inference engine (MLX, llama.cpp, etc.)
/// and exposes the same async streaming API. `InferenceService` picks the
/// right backend based on model format and delegates all work here.
///
/// Backends are unaware of the generation queue — they always see one
/// `generate()` call at a time. Queuing, priority ordering, and session
/// scoping are service-level concerns handled by `InferenceService`.
///
/// ## Thread Safety
///
/// `InferenceService` is `@MainActor`-isolated and calls backend methods
/// from that context, but `loadModel(from:plan:)` is dispatched via
/// `Task.detached` to avoid blocking the main thread during heavy I/O.
/// This means backend methods can be called from **any** thread.
///
/// The generation queue guarantees only one `generate()` call is active at
/// a time, but `stopGeneration()` and `unloadModel()` may arrive
/// concurrently from the main actor while generation runs on a detached
/// task. Conformers with mutable state **must** provide their own
/// synchronization (e.g. `NSLock`, actor isolation).
///
/// All concrete backends in `ManifoldBackends` conform as `@unchecked
/// Sendable` and use either `NSLock` (`LlamaBackend`, `SSECloudBackend`)
/// or actor isolation (`MLXModelContainer`) to protect mutable state.
/// Custom conformers should follow the same pattern.
///
/// New backends adopt this protocol; conformance is verified by the
/// contract harness in `BackendContractChecks` and the per-capability
/// meta-contract. See `Tests/README.md` for the conformance walkthrough.
public protocol InferenceBackend: AnyObject, Sendable {
    var isModelLoaded: Bool { get }
    var isGenerating: Bool { get }

    /// What this backend supports (parameters, context size, prompt templates).
    var capabilities: BackendCapabilities { get }

    /// Introspectable description of the currently loaded model — context
    /// window, sampling parameter support, thinking markers.
    ///
    /// Populated at ``loadModel(from:plan:)`` time. Returns `nil` when no
    /// model has been loaded yet, or when the backend cannot introspect the
    /// model (uncommon — most backends fall back to
    /// ``ModelManifest/unknown(modelIdentifier:producerKind:)``).
    ///
    /// The default implementation returns `nil`. Backends that have not yet
    /// adopted the manifest source-of-truth pattern compile against this
    /// default; consumers (`ContextWindowManager`, request builders) fall
    /// back to ``BackendCapabilities`` when the manifest is absent. This
    /// keeps the addition non-breaking for adopters of `InferenceBackend`.
    var manifest: ModelManifest? { get }

    /// Loads a model from the given URL, consuming a precomputed ``ModelLoadPlan``.
    ///
    /// - For GGUF backends, `url` points to a single `.gguf` file.
    /// - For MLX backends, `url` points to a directory containing
    ///   `config.json` + `.safetensors` weights.
    /// - For cloud backends, `url` is the configured base URL and the plan is
    ///   informational — cloud providers enforce their own limits server-side.
    ///
    /// The plan carries the authoritative effective context size and verdict.
    /// Callers must check `plan.verdict != .deny` before invoking this method;
    /// conformers may rely on that precondition.
    func loadModel(from url: URL, plan: ModelLoadPlan) async throws

    /// Generates a response from a prompt, streaming events as they are produced.
    /// Errors during generation are thrown into the stream.
    ///
    /// **KV cache reuse semantics.** KV state MAY be reused across consecutive `generate()` calls
    /// in the same model-loaded session — defined as calls between `loadModel()`,
    /// `resetConversation()`, and `unloadModel()`. Callers do not pass a session ID; sessionhood
    /// is implicit in "no intervening reset." Backends reporting
    /// `BackendCapabilities.supportsKVCachePersistence: true` MUST honor this semantic; backends
    /// reporting `false` (default) MUST clear KV per call (current behavior).
    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream

    /// Requests that the current generation stop as soon as possible.
    ///
    /// ## Contract
    ///
    /// After `stopGeneration()` returns, the backend **must** satisfy all of:
    ///
    /// 1. **Cancel in-flight generation** — any running `generate()` stream is
    ///    terminated. The stream's `onTermination` handler fires.
    /// 2. **Ready for reuse** — the backend accepts a new `generate()` call
    ///    without requiring `loadModel()` or `resetConversation()` first.
    ///    There must be no corrupted sessions or stale state.
    /// 3. **`isGenerating` is `false`** — callers can check this synchronously
    ///    to confirm the stop took effect.
    ///
    /// Calling `stopGeneration()` when no generation is in progress is a no-op.
    func stopGeneration()

    /// Unloads the model and frees all associated memory.
    func unloadModel()

    /// Resets any accumulated conversation state without unloading the model.
    ///
    /// Backends that maintain multi-turn conversation history (e.g. Foundation)
    /// should clear it here. The default implementation is a no-op.
    func resetConversation()

    /// Zeroes any in-memory KV-cache residue produced by previous inference
    /// calls on this backend.
    ///
    /// The default implementation is a no-op. Backends that hold hot KV state
    /// between turns (`LlamaBackend`, `MLXBackend`) override this to
    /// scrub the residue as best the underlying runtime allows.
    ///
    /// Call this:
    /// - Immediately after ``resetConversation()`` on a session clear.
    /// - When switching away from a session (before loading the next session's
    ///   context), so the previous turn's data does not persist in the KV
    ///   buffers.
    func secureWipe()
}

extension InferenceBackend {
    public func resetConversation() {}
    public func secureWipe() {}
    /// Default — backends that haven't adopted manifest source-of-truth yet
    /// return `nil`, and consumers fall back to ``capabilities``.
    public var manifest: ModelManifest? { nil }
}
