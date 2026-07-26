import Foundation
import os
import ManifoldInference
import ManifoldCloudCore

/// Inference backend for Ollama servers using the native `/api/chat` endpoint.
///
/// Ollama streams responses as newline-delimited JSON (NDJSON) rather than SSE,
/// so this backend overrides ``parseResponseStream(bytes:continuation:)`` to parse
/// each line directly instead of using `SSEStreamParser`.
///
/// Use ``OllamaModelListService`` to discover available models before configuring
/// this backend.
///
/// Usage:
/// ```swift
/// let backend = OllamaBackend()
/// backend.configure(baseURL: URL(string: "http://localhost:11434")!, modelName: "llama3.2")
/// try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
/// let stream = try backend.generate(prompt: "Hello", systemPrompt: nil, config: .init())
/// for try await event in stream.events { if case .token(let t) = event { print(t, terminator: "") } }
/// ```
public final class OllamaBackend: SSECloudBackend, EndpointBackendURLModelConfigurable, AdvisoryResidencyConfigurable, @unchecked Sendable {

    // MARK: - Adapter composition (Phase 3/Ollama)
    //
    // `OllamaBackend` composes ``OllamaAdapter`` so the cross-backend audit
    // (`CloudSeamUsageAuditTest`) recognises it as on the unified-adapter
    // path. The adapter holds the eight per-provider divergences
    // (NDJSON framing transport, OllamaDoneFlagFinalizer, OllamaWholeToolCalls,
    // OllamaImagesField, OllamaFormatField, OllamaToolResult, NoPromptCache,
    // OllamaErrorBodyDecoder). Stream parsing now runs in
    // `CloudRoutedStreamParser` and event extraction is
    // driven by a fresh per-stream ``OllamaStreamEventExtractor`` whose
    // factory pulls the active ``GenerationConfig`` + auto-detected
    // thinking markers from a state-lock-guarded snapshot stashed by
    // the override of `parseResponseStream(bytes:config:continuation:)`.
    //
    // The runtime capability probe (`/api/show`) stays on `loadModel`
    // where it owns the manifest lifecycle — it's not part of the
    // standard `CloudHTTPProviderAdapter` surface.
    public let adapter: any CloudHTTPProviderAdapter

    /// How long Ollama should keep the model loaded in VRAM after a request.
    /// Default is "30m" (30 minutes). Ollama's own default is "5m".
    ///
    /// This is **advisory residency**: it is sent as the request body's
    /// `keep_alive` field and the *Ollama server* decides when to actually free
    /// VRAM. MK cannot evict a server-side model itself. When an Ollama endpoint
    /// is loaded under a non-`.never` ``KeepAlivePolicy``, the lifecycle
    /// coordinator overwrites this via ``applyAdvisoryKeepAlive(idleTimeout:)``
    /// so the server's keep-alive horizon agrees with MK's owned idle policy
    /// instead of diverging from it.
    public var keepAlive: String = "30m"

    /// Bridges MK's owned ``KeepAlivePolicy`` idle horizon into Ollama's
    /// server-side `keep_alive` advice.
    ///
    /// Owned vs advisory residency: MK's policy unloads the *in-process* model
    /// when its idle timer fires; this method translates the same horizon into
    /// the `keep_alive` string Ollama uses to decide when *it* frees VRAM, so
    /// the two timers agree instead of diverging (see
    /// ``AdvisoryResidencyConfigurable``). A `nil` timeout (`.never`) leaves the
    /// existing default in place — no advice is given. Emits seconds (`"<n>s"`)
    /// so the wire value matches the configured timeout exactly; a fractional
    /// timeout is rounded up to whole seconds (Ollama parses integer seconds),
    /// and any non-positive value clamps to `"0s"` (Ollama unloads immediately).
    public func applyAdvisoryKeepAlive(idleTimeout: TimeInterval?) {
        guard let idleTimeout else { return }
        let seconds = max(0, Int(idleTimeout.rounded(.up)))
        keepAlive = "\(seconds)s"
    }

    /// Whether the currently-loaded Ollama model advertises thinking/reasoning
    /// capability. Detected once at `loadModel` time by probing `/api/show`
    /// for `capabilities: ["thinking"]` or Jinja template markers
    /// (`<think>`, `{{ if .Thinking }}`, etc.). Defaults to `false` when the
    /// probe fails or the server returns an unexpected shape — detection is a
    /// best-effort optimisation, never a blocker.
    ///
    /// Consumers: `buildRequest` uses this flag to decide whether
    /// `maxThinkingTokens == nil` should reserve a 2048-token thinking budget
    /// (thinking models only) and whether `maxThinkingTokens == 0` should
    /// forward `"think": false` on the wire (thinking models only; Ollama
    /// silently ignores the flag on non-thinking models but we omit it for
    /// clean request bodies).
    /// Backing storage for ``isThinkingModel``, guarded by the base class's
    /// `stateLock` like every other load-state field. Written inside the
    /// `withStateLock` blocks in `loadModel`/`unloadModel`; read from
    /// `capabilities`/`buildRequest`, which run on a different actor — an
    /// off-lock `var` here was an unsynchronized access / Swift-6 data race.
    private var _isThinkingModel: Bool = false

    public var isThinkingModel: Bool {
        withStateLock { _isThinkingModel }
    }

    /// Backing storage for the loaded model's vision (image-input) capability,
    /// detected from `/api/show`'s `capabilities: ["vision", ...]` list at load
    /// time. Guarded by the base class's `stateLock` exactly like
    /// ``_isThinkingModel`` — written inside the `withStateLock` blocks in
    /// `loadModel`/`unloadModel`, read from `capabilities` which runs on a
    /// different actor (an off-lock `var` would be a Swift-6 data race). `false`
    /// before any load and for text-only models.
    private var _isVisionModel: Bool = false

    /// Whether the loaded model accepts image input, as advertised by Ollama's
    /// `/api/show` capabilities list. Drives `capabilities.supportsVision` and
    /// the central ``BackendVisionCapability/ollamaSupportsImageInput(probedVision:)``
    /// gate. `false` until a vision-capable model is loaded.
    public var isVisionModel: Bool {
        withStateLock { _isVisionModel }
    }

    /// Whether the loaded model supports tool calling, as advertised by
    /// Ollama's `/api/show` `capabilities` list. Guarded by `stateLock` like
    /// its siblings. Defaults to `true` (the historical assumption, and the
    /// probe-failure fallback) so a dead probe never disables tool calling;
    /// only a successful probe that omits "tools" withdraws the claim.
    private var _supportsTools: Bool = true

    private var supportsTools: Bool {
        withStateLock { _supportsTools }
    }

    /// Default per-request idle timeout for Ollama connections.
    ///
    /// Large models may need several minutes to load into VRAM and prefill a
    /// long prompt before any response byte arrives. This generous default
    /// prevents the connection from being killed during that load phase.
    /// Matches the ``keepAlive`` default of 30 minutes.
    ///
    /// Override via ``SSECloudBackend/requestIdleTimeout`` after init.
    public static let defaultRequestIdleTimeout: TimeInterval = 1800

    /// Default application-level idle timeout between generation *events*
    /// (see ``SSECloudBackend/streamIdleTimeout``).
    ///
    /// #2376: a tool-continuation turn against Ollama could stall for a
    /// long time after the tool result was posted with no visible error and
    /// no application-level signal, because this backend never configured
    /// ``SSECloudBackend/streamIdleTimeout`` (the finer-grained, event-level
    /// gate `GenerationStream` already implements) — `defaultRequestIdleTimeout`
    /// alone was doing the job. `defaultRequestIdleTimeout` (1800s) is stamped
    /// onto `URLRequest.timeoutInterval`, but the backend's `URLSession`
    /// (`URLSessionProvider.unpinned`) separately configures
    /// `timeoutIntervalForResource = 600`, which Foundation enforces
    /// independently and which a per-request `timeoutInterval` cannot
    /// override — so the connection's *actual* outer ceiling was already
    /// governed by that 600s resource timeout, not by
    /// `defaultRequestIdleTimeout`'s 1800s (read from
    /// `Sources/ManifoldCloudCore/URLSessionProvider.swift`, not verified
    /// with a live multi-minute stall). Either way, that ceiling produced no
    /// application-visible failure state for several minutes — long enough
    /// that a user has no way to tell a real stall from a working turn —
    /// violating Principle 6 (errors are visible).
    ///
    /// 5 minutes gives a bound Ollama itself owns and reports through
    /// (`InferenceError.idleTimeout`) well before either transport-level
    /// ceiling could fire, while still covering the "several minutes" cold
    /// VRAM load / long-prompt prefill window `defaultRequestIdleTimeout`'s
    /// own doc comment describes. `GenerationStream`'s idle monitor starts
    /// counting from stream creation — slightly before the connection is
    /// even opened — so this covers the pre-first-token `.loading` window
    /// too, not just mid-stream gaps.
    /// Override via ``SSECloudBackend/streamIdleTimeout`` after init.
    public static let defaultStreamIdleTimeout: Duration = .seconds(300)

    /// Conservative floor for `num_ctx` when the caller did not plumb a real
    /// context budget via `ModelLoadPlan` (`.cloud()` default is `1`).
    /// Ollama's server-side `OLLAMA_CONTEXT_LENGTH` defaults to 2048 tokens,
    /// which silently truncates multi-turn conversations with no error signal.
    /// 8192 matches what most mainstream local models are happy with and keeps
    /// multi-turn chat working even when the caller forgot to size the plan.
    static let defaultNumCtxFloor: Int = 8192

    /// Effective context size derived from the `ModelLoadPlan` passed to
    /// `loadModel(from:plan:)`. Used to populate Ollama's `options.num_ctx` in
    /// every request body so the server doesn't fall back to its 2048-token
    /// default (the silent-truncation footgun). Falls back to
    /// ``defaultNumCtxFloor`` when the plan carries a non-meaningful size
    /// (the `.cloud()` factory defaults to `1`).
    /// Guarded by `stateLock`.
    private var effectiveNumCtx: Int = defaultNumCtxFloor

    /// ``ThinkingMarkers`` auto-detected from the loaded model's `/api/show`
    /// `template` field. Set by ``loadModel(from:plan:)`` via the show
    /// probe; consumed by ``parseResponseStream(bytes:config:continuation:)``
    /// when the server never populates the side-channel `message.thinking`
    /// field and the model leaks reasoning via inline tags.
    ///
    /// Guarded by `stateLock`. `nil` on non-thinking models (or when the
    /// probe failed); ``parseResponseStream`` falls back to ``ThinkingMarkers/qwen3``
    /// only when both this and the per-request override are absent.
    private var _autoDetectedThinkingMarkers: ThinkingMarkers?

    /// Manifest produced by the `/api/show` probe at load time. Captures the
    /// real `model_info.context_length`, the auto-detected thinking marker
    /// pair, and the thinking-capability flag in one structured value.
    /// Guarded by `stateLock`.
    private var _manifest: ModelManifest?

    /// Snapshot of the active ``GenerationConfig`` for the current generation,
    /// stashed by ``parseResponseStream(bytes:config:continuation:)`` so the
    /// adapter routing's `streamConsumerFactory` (which receives no
    /// parameters) can construct an ``OllamaStreamEventExtractor`` honouring
    /// the per-call thinking/visible caps and the per-request thinking
    /// markers override. Read-once per stream open. Guarded by `stateLock`.
    private var _pendingStreamConfig: GenerationConfig?

    /// Public accessor for the manifest captured at the most recent
    /// successful load. Returns `nil` before any load. Used by the
    /// conformance harness to assert the cross-backend invariant that
    /// `.thinkingToken` emitters report `manifest.supportsThinking == true`.
    public override var manifest: ModelManifest? {
        withStateLock { _manifest }
    }

    // MARK: - Init

    /// Package-internal initializer used by registrar and framework-internal infrastructure.
    ///
    /// This path is identical to the public `init(urlSession:)` with a `nil` session
    /// but is NOT marked deprecated, so framework-internal callers
    /// (``OllamaBackends``, `TraitAwareServerBackendProvider`, etc.) don't generate
    /// deprecation warnings when following the recommended migration path.
    /// `package` (not `internal`) because `TraitAwareServerBackendProvider` lives
    /// in the `ManifoldServer` module and calls this across the module boundary.
    /// External consumers building `OllamaBackend` directly should use the
    /// public init or register via `DefaultBackends.register(_:)`.
    package init(_registrar: Void) {
        self.adapter = OllamaAdapter(
            capabilities: Self.defaultAdapterCapabilities,
            requestBuilder: { _, _, _, _ in
                throw CloudBackendError.invalidURL(
                    "OllamaAdapter.requestBuilder is not the live path; the OllamaBackend installs a CloudAdapterRouting that delegates to its own buildRequest override."
                )
            }
        )
        super.init(
            defaultModelName: "llama3.2",
            urlSession: URLSessionProvider.unpinned,
            payloadHandler: CloudPayloadHandler.ollama
        )
        requestIdleTimeout = OllamaBackend.defaultRequestIdleTimeout
        // #2376: bound the event-level gap too — see `defaultStreamIdleTimeout`.
        streamIdleTimeout = OllamaBackend.defaultStreamIdleTimeout
        let weakSelfBox = WeakOllamaBackendBox(self)
        let routing = CloudAdapterRouting(
            payloadHandler: adapter.payloadHandler,
            framedTransport: adapter.framedTransport,
            streamFinalizer: adapter.streamFinalizer,
            errorBodyDecoder: adapter.errorBodyDecoder,
            buildRequest: { prompt, systemPrompt, config, hints in
                guard let backend = weakSelfBox.value else {
                    throw CloudBackendError.backendDeallocated
                }
                return try backend.buildRequest(
                    prompt: prompt,
                    systemPrompt: systemPrompt,
                    config: config,
                    hints: hints
                )
            },
            streamConsumerFactory: {
                guard let backend = weakSelfBox.value else {
                    return OllamaStreamEventExtractor(
                        config: GenerationConfig(),
                        autoDetectedMarkers: nil
                    )
                }
                let (config, markers, auto) = backend.snapshotForExtractor()
                return OllamaStreamEventExtractor(
                    config: config,
                    thinkingMarkers: markers,
                    autoDetectedMarkers: auto
                )
            }
        )
        self.configure(adapterRouting: routing)
    }

    /// Creates an Ollama backend.
    ///
    /// - Parameter urlSession: Custom URLSession for testing. Pass `nil` to use the default.
    ///
    /// When `urlSession` is `nil` and the runtime kill-switch
    /// ``URLSessionProvider/networkDisabled`` is set, the underlying property
    /// access traps. Use ``makeChecked(urlSession:)`` for a throwing variant
    /// that surfaces the kill-switch as a recoverable error.
    @available(*, deprecated, message: "Direct construction bypasses registration. Register via OllamaBackends.register(with:) or quickStart(), or use makeChecked(urlSession:) for kill-switch-safe construction; see docs/MIGRATION-shims-retired.md.")
    public init(urlSession: URLSession? = nil) {
        // Adapter capabilities mirror what `OllamaBackend.capabilities`
        // resolves before any /api/show probe has run. The dynamic
        // `capabilities` property remains the authoritative source once
        // `loadModel` has populated `_manifest`. The adapter's
        // `requestBuilder` closure is a no-op placeholder — `buildRequest`
        // is the canonical request builder and the adapter-routed path
        // below threads it through the routing's `buildRequest` closure.
        self.adapter = OllamaAdapter(
            capabilities: Self.defaultAdapterCapabilities,
            requestBuilder: { _, _, _, _ in
                throw CloudBackendError.invalidURL(
                    "OllamaAdapter.requestBuilder is not the live path; the OllamaBackend installs a CloudAdapterRouting that delegates to its own buildRequest override."
                )
            }
        )
        super.init(
            defaultModelName: "llama3.2",
            urlSession: urlSession ?? URLSessionProvider.unpinned,
            payloadHandler: CloudPayloadHandler.ollama
        )
        // Ollama servers often need time to load a model into VRAM before the
        // first response byte arrives. Set a generous HTTP-layer idle timeout
        // so that cold-start latency isn't misreported as a network failure.
        requestIdleTimeout = OllamaBackend.defaultRequestIdleTimeout
        // #2376: bound the event-level gap too — see `defaultStreamIdleTimeout`.
        streamIdleTimeout = OllamaBackend.defaultStreamIdleTimeout

        // Phase 3/Ollama — install adapter routing so the stream loop runs
        // in `CloudRoutedStreamParser` driving a fresh
        // per-stream `OllamaStreamEventExtractor`. The routing's
        // `buildRequest` closure forwards to `self.buildRequest` (weakly
        // captured) so the tool-aware-history snapshot/clear, the
        // num_ctx + thinking-budget arithmetic, the manifest-gated
        // parameter gating, and the keep_alive plumbing all keep running
        // on the backend where they own their state.
        //
        // The `streamConsumerFactory` reads `_pendingStreamConfig` plus
        // the auto-detected thinking markers under the state lock so each
        // generation gets an extractor with the live caps/markers. The
        // snapshot is set by the `parseResponseStream(bytes:config:
        // continuation:)` override below immediately before super
        // routes — the order is guaranteed because `super` invokes the
        // factory synchronously at stream open.
        let weakSelfBox = WeakOllamaBackendBox(self)
        let routing = CloudAdapterRouting(
            payloadHandler: adapter.payloadHandler,
            framedTransport: adapter.framedTransport,
            streamFinalizer: adapter.streamFinalizer,
            errorBodyDecoder: adapter.errorBodyDecoder,
            buildRequest: { prompt, systemPrompt, config, hints in
                guard let backend = weakSelfBox.value else {
                    throw CloudBackendError.backendDeallocated
                }
                return try backend.buildRequest(
                    prompt: prompt,
                    systemPrompt: systemPrompt,
                    config: config,
                    hints: hints
                )
            },
            streamConsumerFactory: {
                guard let backend = weakSelfBox.value else {
                    // The backend deallocated between request dispatch and
                    // stream open. Return a no-op-ish consumer using
                    // defaults so the routed loop can complete cleanly
                    // rather than crashing on a forced unwrap.
                    return OllamaStreamEventExtractor(
                        config: GenerationConfig(),
                        autoDetectedMarkers: nil
                    )
                }
                let (config, markers, auto) = backend.snapshotForExtractor()
                return OllamaStreamEventExtractor(
                    config: config,
                    thinkingMarkers: markers,
                    autoDetectedMarkers: auto
                )
            }
        )
        self.configure(adapterRouting: routing)
    }

    /// Static adapter capabilities used at init time. Mirrors the dynamic
    /// `capabilities` property's pre-probe values so the adapter
    /// composition is valid immediately. The dynamic property remains the
    /// authoritative source once a real `modelName` is loaded.
    private static let defaultAdapterCapabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [
            .temperature, .topP, .topK, .repeatPenalty,
            .minP, .presencePenalty, .frequencyPenalty,
        ],
        maxContextTokens: 128_000,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true,
        supportsToolCalling: true,
        supportsStructuredOutput: false,
        supportsNativeJSONMode: true,
        cancellationStyle: .cooperative,
        supportsTokenCounting: false,
        memoryStrategy: .external,
        maxOutputTokens: 128_000,
        supportsStreaming: true,
        isRemote: true,
        supportsThinking: false,
        // Pre-probe default: vision is unknown until `/api/show` runs at load
        // time. The dynamic `capabilities` override flips this on for models
        // that advertise the `vision` capability.
        supportsVision: false,
        streamsToolCallArguments: false,
        supportsParallelToolCalls: true,
        // Ollama's /api/chat takes a structured message array, so the captured
        // `.promptRendered` is only the latest user message — partial (#1905).
        rendersFullPrompt: false
    )

    /// Reads the snapshot the `parseResponseStream` override stashed
    /// immediately before delegating to super, plus the auto-detected
    /// thinking markers captured at load time. Falls back to a default
    /// config if no snapshot has been stashed (shouldn't happen on the
    /// production path; defensive against a future refactor that calls
    /// the routing's factory outside the stream-open path).
    fileprivate func snapshotForExtractor() -> (GenerationConfig, ThinkingMarkers?, ThinkingMarkers?) {
        // Read the per-request thinking-marker hint (#2152) outside the state
        // lock — `activeHints` takes the same non-recursive `NSLock`, so reading
        // it inside `withStateLock` would deadlock.
        let hintMarkers = activeHints.thinkingMarkers
        return withStateLock {
            let config = _pendingStreamConfig ?? GenerationConfig()
            // Clear after read — the snapshot is one-shot, mirroring
            // `toolAwareHistory`'s snapshot-and-clear pattern below.
            _pendingStreamConfig = nil
            return (config, hintMarkers, _autoDetectedThinkingMarkers)
        }
    }

    /// Throwing factory that propagates ``URLSessionProvider/networkDisabled``
    /// as ``CloudBackendError/networkDisabled`` instead of trapping.
    @available(*, deprecated, message: "Direct construction bypasses registration. Register via OllamaBackends.register(with:) or quickStart(), or use makeChecked(urlSession:) for kill-switch-safe construction; see docs/MIGRATION-shims-retired.md.")
    public static func makeChecked(urlSession: URLSession? = nil) throws -> OllamaBackend {
        let session: URLSession
        if let urlSession {
            session = urlSession
        } else {
            session = try URLSessionProvider.throwingUnpinned()
        }
        return OllamaBackend(urlSession: session)
    }

    // MARK: - Subclass Hooks

    public override var backendName: String { "Ollama" }

    public override var capabilities: BackendCapabilities {
        // Prefer the `/api/show` `model_info.context_length` captured into
        // the manifest at load time. Fall back to the historical 128k
        // default (covers most modern Llama 3.x / Qwen3 weights) until a
        // real probe runs.
        let resolvedManifest = withStateLock { _manifest }
        let resolvedContext: Int32
        if let resolvedManifest {
            resolvedContext = Int32(resolvedManifest.contextWindow)
        } else {
            resolvedContext = 128_000
        }
        return BackendCapabilities(
            supportedParameters: [
                .temperature, .topP, .topK, .repeatPenalty,
                .minP, .presencePenalty, .frequencyPenalty,
            ],
            maxContextTokens: resolvedContext,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            // Tool calling wiring: Ollama's native /api/chat endpoint accepts an
            // OpenAI-shaped `tools` array and emits `message.tool_calls` on the
            // wire (streaming delivers each tool_call in its own NDJSON line).
            // The coordinator dispatches calls through `ToolRegistry`; this
            // backend is responsible only for serialising `tools` /
            // `tool_choice` on the request and parsing `tool_calls` into
            // `GenerationEvent.toolCall`. Whether the *model* accepts tools is
            // probed from `/api/show` at load time (like thinking/vision) —
            // claiming support for a model without it turns into a
            // generation-time HTTP 400 instead of a truthful pre-flight.
            supportsToolCalling: supportsTools,
            supportsStructuredOutput: false,
            supportsNativeJSONMode: true,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false,
            memoryStrategy: .external,
            maxOutputTokens: 128_000,
            supportsStreaming: true,
            isRemote: true,
            // Reflect the auto-detected thinking capability from `/api/show`
            // here so consumers can gate reasoning UI without consulting the
            // legacy `isThinkingModel` flag separately. Defaults to the live
            // probe value; the manifest carries the same bit.
            supportsThinking: isThinkingModel,
            // Reflect the auto-detected vision capability from `/api/show`'s
            // `capabilities: ["vision", ...]` list. The image *wire* path
            // (`OllamaImagesField`) has always existed; this advertises it so
            // consumers can gate image attachment on a real signal instead of
            // assuming false. `false` until a vision model loads. Routed through
            // the central gate to match the cloud families' pattern.
            supportsVision: BackendVisionCapability.ollamaSupportsImageInput(probedVision: isVisionModel),
            // Ollama emits tool calls as whole entries on a single NDJSON
            // line — no incremental `arguments` fragments arrive across
            // multiple lines (some `qwen2.5:7b` configs may stream deltas
            // but this backend treats Ollama as whole-call only for v1).
            streamsToolCallArguments: false,
            // `/api/chat` is happy to return multiple `tool_calls[]` entries
            // in a single assistant message — the loop in `parseResponseStream`
            // emits them in array order so the orchestrator's serial dispatch
            // honours the model's intent.
            supportsParallelToolCalls: true,
            // Structured message array on the wire → partial `.promptRendered` (#1905).
            rendersFullPrompt: false
        )
    }

    /// Encodes structured turns into Ollama `/api/chat` message dicts, lifting
    /// `MessagePart.image` payloads onto the message-level `images: [base64]`
    /// field that Ollama's multimodal models consume. Ollama takes raw base64
    /// (no `data:` URI prefix, no MIME) — see ``OllamaImagesField``. Text parts
    /// concatenate into `content`; non-text/non-image parts (thinking, tool
    /// call/result) are dropped here because the image path is only taken for
    /// plain vision turns (the tool loop owns the tool-aware path above).
    static func encodeOllamaMessagesWithImages(_ history: [StructuredMessage]) -> [[String: Any]] {
        history.map { message in
            var entry: [String: Any] = ["role": message.role]
            entry["content"] = message.textContent
            var images: [String] = []
            for part in message.parts {
                if case let .image(data, _, _) = part {
                    images.append(CloudImageEncoding.base64String(from: data))
                }
            }
            if !images.isEmpty {
                entry["images"] = images
            }
            return entry
        }
    }

    // MARK: - Model Lifecycle

    // Plan is informational for cloud backends.
    public override func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        guard let configuredBaseURL = baseURL else {
            throw CloudBackendError.invalidURL(
                "No base URL configured. Call configure(baseURL:modelName:) first."
            )
        }

        // Validate the configured host against DNS rebinding / SSRF before
        // any network I/O fires — must run before /api/show probe below.
        try await DNSRebindingGuard.validate(url: configuredBaseURL)

        // Ollama v0.18.0+ routes any model tag ending in `:cloud` to remote
        // inference (Ollama's hosted service) rather than the local server.
        // ManifoldKit positions itself as local-first, so silently sending
        // prompts off-device would violate the caller's expectation — throw a
        // descriptive error at load time rather than leak conversation content
        // to a remote endpoint the user didn't consciously opt into.
        if modelName.hasSuffix(":cloud") {
            throw CloudBackendError.invalidURL(
                "Ollama model '\(modelName)' is a :cloud-suffixed tag that routes to remote inference. ManifoldKit is local-first — strip the :cloud suffix or switch to a cloud backend (ClaudeBackend, OpenAIBackend) if remote inference is intended."
            )
        }

        // Honour the plan's effective context size so Ollama's `num_ctx`
        // matches what BCK's `ContextWindowManager` budgets against. If the
        // caller used the `.cloud()` factory (which defaults to 1), fall back
        // to the floor — Ollama's own 2048 default is a documented footgun
        // that silently truncates multi-turn conversations.
        let planned = plan.effectiveContextSize
        let resolvedNumCtx = planned > Self.defaultNumCtxFloor ? planned : Self.defaultNumCtxFloor
        withStateLock { effectiveNumCtx = resolvedNumCtx }

        let probed: OllamaShowProbe
        do {
            probed = try await OllamaModelProbe.probeShow(
                baseURL: configuredBaseURL,
                modelName: modelName,
                urlSession: urlSession
            )
        } catch {
            Log.network.info("OllamaBackend /api/show probe threw \(error.localizedDescription, privacy: .public) — treating \(self.modelName, privacy: .public) as non-thinking with conservative manifest")
            probed = .empty
        }

        let resolvedContextWindow = probed.contextLength ?? max(resolvedNumCtx, Self.defaultNumCtxFloor)
        let manifest = ModelManifest(
            contextWindow: resolvedContextWindow,
            supportsTools: probed.tools,
            supportsThinking: probed.thinking,
            thinkingMarkers: probed.thinkingMarkers,
            supportsSeed: false, // Ollama's /api/chat ignores seed in current releases.
            supportedSamplingParameters: [
                .temperature, .topP, .topK,
                .presencePenalty, .frequencyPenalty,
                .repeatPenalty,
            ],
            modelIdentifier: modelName,
            producerKind: .lan
        )
        withStateLock {
            _isThinkingModel = probed.thinking
            _isVisionModel = probed.vision
            _supportsTools = probed.tools
            _autoDetectedThinkingMarkers = probed.thinkingMarkers
            _manifest = manifest
        }

        setIsModelLoaded(true)
        Log.inference.info("OllamaBackend configured for \(self.modelName, privacy: .public) at \(self.baseURL?.host() ?? "unknown", privacy: .public) thinking=\(self.isThinkingModel, privacy: .public) num_ctx=\(resolvedNumCtx, privacy: .public) ctxWindow=\(resolvedContextWindow, privacy: .public)")
    }

    // MARK: - Request Building

    public override func buildRequest(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig,
        hints: GenerationRuntimeHints
    ) throws -> URLRequest {
        guard let baseURL else {
            throw CloudBackendError.invalidURL("No base URL configured")
        }

        let chatURL = baseURL.appendingPathComponent("api/chat")

        // Build the messages array from the per-call history threaded on the
        // stack (#2312) — never from shared instance state. When any turn
        // carries a tool call/result part (the orchestrator is mid tool-dispatch
        // loop) we emit the OpenAI-compatible shape Ollama expects:
        //   - assistant entries optionally carry a `tool_calls` array with
        //     {id, type: "function", function: {name, arguments}} entries.
        //   - tool entries carry `tool_call_id` alongside role and content.
        // Otherwise we fall back to the classic string tuples — this preserves
        // the shape every existing OllamaBackend test asserts on.
        var messages: [[String: Any]] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        let history = hints.history
        // Vision turns only take the structured path: a turn carries images
        // only via `MessagePart.image`, which the text-only flattened projection
        // drops. Falling through to the text path when no image is present
        // preserves every existing OllamaBackend wire-shape assertion (the
        // structured encoder is image-aware but the plain string history is
        // what the suite pins).
        if history.containsToolParts {
            messages.append(contentsOf: CloudMessageEncoder.ollama.encodeMessages(
                systemPrompt: nil,
                prompt: "",
                structuredHistory: nil,
                toolAwareHistory: history.toolAwareHistory,
                plainHistory: nil
            ))
        } else if history.containsImages {
            messages.append(contentsOf: Self.encodeOllamaMessagesWithImages(history))
        } else if !history.isEmpty {
            messages.append(contentsOf: history.flattenedHistory.map { ["role": $0.role, "content": $0.content] })
        } else {
            messages.append(["role": "user", "content": prompt])
        }

        // num_predict has to cover thinking + visible tokens together on
        // Ollama. The three-state `maxThinkingTokens` semantics below map
        // directly to the wire:
        //
        //   nil → default thinking reserve, *only* on known thinking models
        //         (was unconditional pre-P4; non-thinking models no longer
        //         over-provision 2048 unused tokens).
        //   0   → explicitly disable thinking. Sends `think: false` on
        //         thinking-capable models; non-thinking models omit the key
        //         because Ollama treats it as a no-op there.
        //   N>0 → explicit cap at N thinking tokens; `think` is omitted so
        //         Ollama honours the model's per-request default and we stay
        //         forward-compatible with future capability flags.
        //
        // Visible output is still re-capped client-side in
        // parseResponseStream using the server's own `eval_count`, so an
        // over-generous num_predict can never cause more visible tokens than
        // `maxOutputTokens` to surface to the caller.
        let visibleBudget = config.maxOutputTokens ?? 2048
        let thinkingBudget: Int
        let thinkDirective: Bool?
        switch config.maxThinkingTokens {
        case .some(0):
            thinkingBudget = 0
            thinkDirective = isThinkingModel ? false : nil
        case .some(let n):
            thinkingBudget = n
            thinkDirective = nil
        case nil:
            thinkingBudget = isThinkingModel ? 2048 : 0
            thinkDirective = nil
        }

        let numCtx = withStateLock { effectiveNumCtx }
        var options: [String: Any] = [
            "temperature": config.temperature,
            "top_p": config.topP,
            "top_k": config.topK.map { Int($0) } ?? 40,
            "repeat_penalty": config.repeatPenalty,
            "num_predict": visibleBudget + thinkingBudget,
            // Ollama's server-side default is `OLLAMA_CONTEXT_LENGTH` (2048).
            // Multi-turn conversations with long history or tool results get
            // silently truncated at that ceiling with no error signal. Set
            // `num_ctx` explicitly to BCK's effective context size so the
            // server honours whatever budget we decided on at load time.
            "num_ctx": numCtx,
        ]
        // Only include the modern penalty knobs when the caller set them. Omitting
        // preserves whatever the Ollama server-side default is (typically 0 for
        // additive penalties, 1.0 for multiplicative) and keeps wire payloads
        // identical for callers that haven't migrated.
        if let minP = config.minP { options["min_p"] = minP }
        if let presence = config.presencePenalty { options["presence_penalty"] = presence }
        if let frequency = config.frequencyPenalty { options["frequency_penalty"] = frequency }
        if let repWindow = config.repetitionContextSize { options["repeat_last_n"] = repWindow }
        // User-settable stop sequences (#1944). Ollama accepts `options.stop`
        // (array). Emit only when non-empty to keep wire payloads identical for
        // callers that never set stops.
        if !config.stopSequences.isEmpty { options["stop"] = config.stopSequences }

        // Ollama's modern `/api/chat` returns `tool_calls` inside
        // `message.tool_calls` on streaming NDJSON lines. Earlier versions
        // required `stream: false`, but as of the v0.1.x+ API that BCK
        // targets tool_calls stream inline alongside content. Leave
        // `stream: true` and parse tool_calls in `parseResponseStream`.
        var body: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "stream": true,
            "options": options,
            "keep_alive": keepAlive,
        ]
        if hints.jsonMode {
            body["format"] = "json"
        }
        if let think = thinkDirective {
            body["think"] = think
        }
        // Tool definitions — serialise the BCK `ToolDefinition` list into
        // OpenAI's `tools` envelope, which Ollama accepts natively.
        // `tool_choice` maps one-to-one: `.auto` omits the field so Ollama's
        // default (let-the-model-decide) takes effect; `.none` / `.required`
        // are passed through as literal strings; `.tool(name:)` produces the
        // function-selection object Ollama expects for forced selection.
        if !config.tools.isEmpty {
            body["tools"] = CloudMessageEncoder.ollama.encodeTools(config.tools)
            CloudMessageEncoder.ollamaApplyToolChoice(config.toolChoice, into: &body)
        }

        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Prefer Connection: close for streaming NDJSON so a half-closed
        // keep-alive socket from a previous turn cannot be reused for the next
        // generate call. Tool-continuation turns (#2376) issue a second
        // `/api/chat` immediately after the first stream ends; on platforms
        // where URLSession's keep-alive pool is sticky (iOS simulator in
        // particular), reusing a connection that was cancelled mid-drain is a
        // known hang shape. Closing is free for a local LAN hop.
        request.setValue("close", forHTTPHeaderField: "Connection")
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData

        let isToolContinuation = history.containsToolParts
        if isToolContinuation {
            // #2376: the walkthrough hang left no request-body evidence. Always
            // log a structured summary for tool-continuation requests so the
            // next stall surfaces message roles, tool names, and body size
            // without requiring a debugger.
            let summary = Self.toolContinuationRequestSummary(
                messages: messages,
                toolsCount: config.tools.count,
                bodyBytes: bodyData.count
            )
            Log.network.info(
                "OllamaBackend tool-continuation request to \(chatURL.absoluteString, privacy: .public) model=\(self.modelName, privacy: .public) \(summary, privacy: .public)"
            )
            // Stash so a later idle-timeout / zero-event stall can re-emit the
            // same summary without re-encoding the body (#2376 diagnostics).
            CloudRequestDiagnostic.store(summary)
        } else {
            Log.network.debug(
                "OllamaBackend request to \(chatURL.absoluteString, privacy: .public) model=\(self.modelName, privacy: .public)"
            )
        }

        return request
    }

    /// Compact, log-safe summary of a tool-continuation request body for #2376
    /// diagnostics. Roles + tool names only — never raw user content or tool
    /// result payloads (those can carry secrets).
    static func toolContinuationRequestSummary(
        messages: [[String: Any]],
        toolsCount: Int,
        bodyBytes: Int
    ) -> String {
        let roles = messages.map { ($0["role"] as? String) ?? "?" }
        var toolNames: [String] = []
        for message in messages {
            if let calls = message["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    let name = (call["function"] as? [String: Any])?["name"] as? String
                    toolNames.append(name ?? "?")
                }
            }
            if let callId = message["tool_call_id"] as? String, !callId.isEmpty {
                // Pairing id present on the tool-result turn — surface a
                // truncated form so a missing/empty id is obvious in logs.
                let short = callId.count > 12 ? String(callId.prefix(12)) + "…" : callId
                toolNames.append("result:\(short)")
            }
        }
        let rolesJoined = roles.joined(separator: "→")
        let toolsJoined = toolNames.isEmpty ? "-" : toolNames.joined(separator: ",")
        return "messages=\(messages.count) roles=[\(rolesJoined)] tool_turns=[\(toolsJoined)] tools=\(toolsCount) body_bytes=\(bodyBytes)"
    }

    // MARK: - NDJSON Stream Parsing
    //
    // Phase 3/Ollama deleted the inline `OllamaStreamProcessor` parser. The
    // adapter routing installed at `init` time threads stream parsing
    // through `CloudRoutedStreamParser`, which drives a
    // fresh `OllamaStreamEventExtractor` per generation (NDJSON via
    // `NDJSONTransport`, termination via `OllamaDoneFlagFinalizer`,
    // per-stream state owned by the extractor). The override below
    // exists only to stash the active `GenerationConfig` into the
    // state-lock-guarded snapshot the routing's `streamConsumerFactory`
    // pulls — the `CloudStreamEventConsumer` protocol receives no
    // parameters by design, so this is how Ollama's per-call thinking and
    // visible caps reach the extractor.
    //
    // (#189) The pre-first-token stall — Ollama holding an open `200 OK`
    // connection for minutes while it loads the model into VRAM and prefills
    // the prompt — is surfaced as `GenerationStream.Phase.loading` via the
    // `signalsLoadingUntilFirstToken` override below. The shared
    // `SSEGenerationTaskRunner` holds `.loading` from connect until the first
    // event is yielded, then transitions to `.streaming`. The generous
    // `defaultRequestIdleTimeout` keeps the HTTP layer from killing the load
    // window in the first place.

    /// Ollama can stall on an open connection for minutes during model load /
    /// prompt prefill before the first token arrives — surface that window as
    /// `.loading` rather than lying about `.streaming`. See
    /// ``SSECloudBackend/signalsLoadingUntilFirstToken``.
    public override var signalsLoadingUntilFirstToken: Bool { true }

    public override func parseResponseStream(
        bytes: URLSession.AsyncBytes,
        config: GenerationConfig,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        // Stash the config snapshot so the routing's
        // `streamConsumerFactory` can construct an extractor with the
        // live caps + per-request thinking-markers override. The factory
        // is invoked synchronously at stream open inside super's
        // adapter-routed loop; the snapshot is read-once-and-cleared in
        // `snapshotForExtractor()`.
        withStateLock { _pendingStreamConfig = config }
        try await super.parseResponseStream(bytes: bytes, config: config, continuation: continuation)
    }

    // MARK: - HTTP Status Validation

    public override func checkStatusCode(
        _ response: HTTPURLResponse,
        bytes: URLSession.AsyncBytes
    ) async throws {
        let statusCode = response.statusCode
        guard !(200...299).contains(statusCode) else { return }

        switch statusCode {
        case 404:
            throw CloudBackendError.serverError(statusCode: 404, message: "Model not found. Pull the model with `ollama pull <model>` first.")
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap { TimeInterval($0) }
            throw CloudBackendError.rateLimited(retryAfter: retryAfter)
        default:
            let message = await drainAndSanitizeErrorBody(
                bytes,
                extractor: { OllamaModelProbe.extractErrorMessage(from: $0) }
            )
            throw CloudBackendError.sanitizedServerError(statusCode: statusCode, rawMessage: message)
        }
    }

    // MARK: - Unload

    public override func unloadModel() {
        withStateLock {
            _isThinkingModel = false
            _isVisionModel = false
            _supportsTools = true
            _manifest = nil
            _autoDetectedThinkingMarkers = nil
            _pendingStreamConfig = nil
        }
        super.unloadModel()
    }
}

/// Sendable weak reference used by the routing closure to call back into
/// the backend's `buildRequest` and `snapshotForExtractor()` without
/// retaining `self`. Matches the `WeakBackendBox` pattern in
/// `OpenAIBackend.swift`.
private final class WeakOllamaBackendBox: @unchecked Sendable {
    weak var value: OllamaBackend?
    init(_ value: OllamaBackend) { self.value = value }
}

