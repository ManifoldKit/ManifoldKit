import Foundation

/// Sampling and generation parameters shared across all inference backends.
public struct GenerationConfig: Sendable, Codable {
    public var temperature: Float
    public var topP: Float
    public var repeatPenalty: Float
    @available(*, deprecated, renamed: "maxOutputTokens", message: "Use maxOutputTokens instead.")
    public var maxTokens: Int32 {
        get { _legacyMaxTokens }
        set { _legacyMaxTokens = newValue }
    }
    /// Backing storage for the deprecated ``maxTokens`` field. Lives separately so the type's
    /// own initializers and Codable conformance can read/write the legacy value without
    /// tripping the deprecation warning. See PR #766 follow-up to #747.
    @usableFromInline internal var _legacyMaxTokens: Int32 = 512
    public var topK: Int32?
    public var typicalP: Float?

    /// Min-p sampling threshold relative to the highest-probability token.
    ///
    /// An alternative to top-p that filters tokens by probability ratio rather than
    /// cumulative mass. `nil` (the default) lets each backend apply its own value.
    /// Mirrors `GenerateParameters.minP` in `mlx-swift-lm`. Honoured by ``MLXBackend``
    /// and ``LlamaBackend``; backends that do not expose a min-p sampler ignore it.
    public var minP: Float?

    /// Repetition penalty applied to recently-generated tokens (1.0 = no penalty).
    ///
    /// Distinct from ``repeatPenalty`` only in shape — kept as a separate optional so
    /// callers can leave it `nil` and inherit the backend's default behaviour. When
    /// non-`nil` this value takes precedence over ``repeatPenalty`` for backends that
    /// support an explicit knob (MLX, llama.cpp). Backends that do not expose a
    /// repetition penalty (e.g. ``FoundationBackend``) ignore it.
    public var repetitionPenalty: Float?

    /// Deterministic sampling seed.
    ///
    /// When set, backends that expose a sampler seed (``MLXBackend``,
    /// ``LlamaBackend``) initialise their RNG from this value so two runs with the
    /// same prompt and config produce the same token stream. Backends that do not
    /// expose a seed (``FoundationBackend``, cloud backends without a `seed` API
    /// parameter) silently ignore it — a missing seed is never an error.
    /// Stored as `UInt64` for parity with mlx-swift-lm; backends with smaller seed
    /// types (e.g. llama.cpp's `uint32_t`) truncate.
    public var seed: UInt64?

    /// Maximum number of tokens the model should generate in a single response.
    ///
    /// Cloud backends send this as their `max_tokens` API parameter.
    /// Local backends (Foundation, MLX, llama.cpp) use it to cap the generation loop.
    /// `nil` means no explicit limit beyond the backend's own defaults.
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
    ///   output directly. On non-thinking models this is a no-op.
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
    /// Defaults to `false`. Backends that do not support structured output, or
    /// have not implemented JSON-mode wiring yet, silently ignore this flag.
    public var jsonMode: Bool

    /// Opt-in for backend-specific prefill-progress streaming extensions.
    ///
    /// When `true`, OpenAI-compatible backends add
    /// `X-BaseChat-Prefill-Progress: true` so compatible servers can emit
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
    /// Backends without thinking support (`BackendCapabilities.supportsThinking == false`)
    /// silently ignore this field. There is no longer a hardcoded fallback to
    /// `.qwen3` — if neither auto-detection nor the caller surfaces markers,
    /// the parser stays off.
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

    /// Number of tokens between brief cooperative yields during MLX generation.
    ///
    /// Sustained MLX inference on Mac can starve WindowServer's GPU command
    /// queue and cause hitches in other apps. To mitigate this, ``MLXBackend``
    /// inserts a 50µs `Task.sleep` every `yieldEveryNTokens` tokens. The same
    /// pattern is used in `SwiftLM/Server.swift`.
    ///
    /// - Defaults to `8` (one yield per ~8 tokens).
    /// - `0` disables the yield entirely.
    /// - Only honoured by `MLXBackend`; other backends ignore this field.
    public var yieldEveryNTokens: Int = 8

    @available(*, deprecated, message: "Use init(temperature:topP:repeatPenalty:topK:typicalP:minP:repetitionPenalty:seed:maxOutputTokens:tools:toolChoice:maxThinkingTokens:jsonMode:streamPrefillProgress:thinkingMarkers:maxToolIterations:grammar:yieldEveryNTokens:) instead.")
    public init(
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        maxTokens: Int32,
        topK: Int32? = nil,
        typicalP: Float? = nil,
        minP: Float? = nil,
        repetitionPenalty: Float? = nil,
        seed: UInt64? = nil,
        maxOutputTokens: Int? = 2048,
        tools: [ToolDefinition] = [],
        toolChoice: ToolChoice = .auto,
        maxThinkingTokens: Int? = nil,
        jsonMode: Bool = false,
        streamPrefillProgress: Bool = false,
        thinkingMarkers: ThinkingMarkers? = nil,
        maxToolIterations: Int = 10,
        grammar: String? = nil,
        yieldEveryNTokens: Int = 8
    ) {
        self.temperature = temperature
        self.topP = topP
        self.repeatPenalty = repeatPenalty
        self._legacyMaxTokens = maxTokens
        self.topK = topK
        self.typicalP = typicalP
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.seed = seed
        self.maxOutputTokens = maxOutputTokens
        self.tools = tools
        self.toolChoice = toolChoice
        self.maxThinkingTokens = maxThinkingTokens
        self.jsonMode = jsonMode
        self.streamPrefillProgress = streamPrefillProgress
        self.thinkingMarkers = thinkingMarkers
        self.maxToolIterations = max(1, maxToolIterations)
        self.grammar = grammar
        self.yieldEveryNTokens = yieldEveryNTokens
    }

    public init(
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        topK: Int32? = nil,
        typicalP: Float? = nil,
        minP: Float? = nil,
        repetitionPenalty: Float? = nil,
        seed: UInt64? = nil,
        maxOutputTokens: Int? = 2048,
        tools: [ToolDefinition] = [],
        toolChoice: ToolChoice = .auto,
        maxThinkingTokens: Int? = nil,
        jsonMode: Bool = false,
        streamPrefillProgress: Bool = false,
        thinkingMarkers: ThinkingMarkers? = nil,
        maxToolIterations: Int = 10,
        grammar: String? = nil,
        yieldEveryNTokens: Int = 8
    ) {
        self.temperature = temperature
        self.topP = topP
        self.repeatPenalty = repeatPenalty
        self.topK = topK
        self.typicalP = typicalP
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.seed = seed
        self.maxOutputTokens = maxOutputTokens
        self.tools = tools
        self.toolChoice = toolChoice
        self.maxThinkingTokens = maxThinkingTokens
        self.jsonMode = jsonMode
        self.streamPrefillProgress = streamPrefillProgress
        self.thinkingMarkers = thinkingMarkers
        self.maxToolIterations = max(1, maxToolIterations)
        self.grammar = grammar
        self.yieldEveryNTokens = yieldEveryNTokens
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case temperature, topP, repeatPenalty, maxTokens, topK, typicalP, maxOutputTokens
        case tools, toolChoice, maxThinkingTokens, jsonMode, maxToolIterations, grammar
        case yieldEveryNTokens
        case streamPrefillProgress
        case minP, repetitionPenalty, seed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        temperature = try c.decode(Float.self, forKey: .temperature)
        topP = try c.decode(Float.self, forKey: .topP)
        repeatPenalty = try c.decode(Float.self, forKey: .repeatPenalty)
        // maxTokens is deprecated; absent from payloads that never encoded it — fall back to 512.
        // We write to the backing store directly to avoid the deprecation warning on the property.
        _legacyMaxTokens = (try c.decodeIfPresent(Int32.self, forKey: .maxTokens)) ?? 512
        topK = try c.decodeIfPresent(Int32.self, forKey: .topK)
        typicalP = try c.decodeIfPresent(Float.self, forKey: .typicalP)
        maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        // New fields added after the original shape; absent from older payloads.
        tools = (try c.decodeIfPresent([ToolDefinition].self, forKey: .tools)) ?? []
        toolChoice = (try c.decodeIfPresent(ToolChoice.self, forKey: .toolChoice)) ?? .auto
        maxThinkingTokens = try c.decodeIfPresent(Int.self, forKey: .maxThinkingTokens)
        jsonMode = (try c.decodeIfPresent(Bool.self, forKey: .jsonMode)) ?? false
        streamPrefillProgress = (try c.decodeIfPresent(Bool.self, forKey: .streamPrefillProgress)) ?? false
        // maxToolIterations landed after the original shape; default to 10 when absent and
        // clamp any persisted zero/negative value to the minimum of 1.
        let decodedIterations = (try c.decodeIfPresent(Int.self, forKey: .maxToolIterations)) ?? 10
        maxToolIterations = max(1, decodedIterations)
        // thinkingMarkers is a per-request runtime hint; it is not persisted.
        thinkingMarkers = nil
        grammar = try c.decodeIfPresent(String.self, forKey: .grammar)
        // yieldEveryNTokens landed after the original shape; default to 8 when absent.
        yieldEveryNTokens = (try c.decodeIfPresent(Int.self, forKey: .yieldEveryNTokens)) ?? 8
        // minP / repetitionPenalty / seed landed after the original shape; absent
        // from older payloads, default to nil so the backend's own defaults apply.
        minP = try c.decodeIfPresent(Float.self, forKey: .minP)
        repetitionPenalty = try c.decodeIfPresent(Float.self, forKey: .repetitionPenalty)
        seed = try c.decodeIfPresent(UInt64.self, forKey: .seed)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(topP, forKey: .topP)
        try c.encode(repeatPenalty, forKey: .repeatPenalty)
        // Encode the legacy `maxTokens` wire field for backwards-compatible payloads.
        try c.encode(_legacyMaxTokens, forKey: .maxTokens)
        try c.encodeIfPresent(topK, forKey: .topK)
        try c.encodeIfPresent(typicalP, forKey: .typicalP)
        try c.encodeIfPresent(maxOutputTokens, forKey: .maxOutputTokens)
        try c.encode(tools, forKey: .tools)
        try c.encode(toolChoice, forKey: .toolChoice)
        try c.encodeIfPresent(maxThinkingTokens, forKey: .maxThinkingTokens)
        try c.encode(jsonMode, forKey: .jsonMode)
        try c.encode(streamPrefillProgress, forKey: .streamPrefillProgress)
        try c.encode(maxToolIterations, forKey: .maxToolIterations)
        try c.encodeIfPresent(grammar, forKey: .grammar)
        try c.encode(yieldEveryNTokens, forKey: .yieldEveryNTokens)
        try c.encodeIfPresent(minP, forKey: .minP)
        try c.encodeIfPresent(repetitionPenalty, forKey: .repetitionPenalty)
        try c.encodeIfPresent(seed, forKey: .seed)
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
/// All concrete backends in `BaseChatBackends` conform as `@unchecked
/// Sendable` and use either `NSLock` (`LlamaBackend`, `SSECloudBackend`)
/// or actor isolation (`MLXModelContainer`) to protect mutable state.
/// Custom conformers should follow the same pattern.
public protocol InferenceBackend: AnyObject, Sendable {
    var isModelLoaded: Bool { get }
    var isGenerating: Bool { get }

    /// What this backend supports (parameters, context size, prompt templates).
    var capabilities: BackendCapabilities { get }

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
}

extension InferenceBackend {
    public func resetConversation() {}
}
