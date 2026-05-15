#if Ollama
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
public final class OllamaBackend: SSECloudBackend, CloudBackendURLModelConfigurable, ToolCallingHistoryReceiver, @unchecked Sendable {

    /// How long Ollama should keep the model loaded in VRAM after a request.
    /// Default is "30m" (30 minutes). Ollama's own default is "5m".
    public var keepAlive: String = "30m"

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
    public private(set) var isThinkingModel: Bool = false

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

    /// Public accessor for the manifest captured at the most recent
    /// successful load. Returns `nil` before any load. Used by the
    /// conformance harness to assert the cross-backend invariant that
    /// `.thinkingToken` emitters report `manifest.supportsThinking == true`.
    public override var manifest: ModelManifest? {
        withStateLock { _manifest }
    }

    // MARK: - Init

    /// Creates an Ollama backend.
    ///
    /// - Parameter urlSession: Custom URLSession for testing. Pass `nil` to use the default.
    ///
    /// When `urlSession` is `nil` and the runtime kill-switch
    /// ``URLSessionProvider/networkDisabled`` is set, the underlying property
    /// access traps. Use ``makeChecked(urlSession:)`` for a throwing variant
    /// that surfaces the kill-switch as a recoverable error.
    @available(*, deprecated, message: "OllamaBackend remains available; this is a build-mode migration notice. Before the next major, add the `Ollama` trait to package dependencies or register via DefaultBackends.register(_:); see README 'Build modes' and #714.")
    public init(urlSession: URLSession? = nil) {
        super.init(
            defaultModelName: "llama3.2",
            urlSession: urlSession ?? URLSessionProvider.unpinned,
            payloadHandler: OllamaPayloadHandler()
        )
    }

    /// Throwing factory that propagates ``URLSessionProvider/networkDisabled``
    /// as ``CloudBackendError/networkDisabled`` instead of trapping.
    @available(*, deprecated, message: "OllamaBackend remains available; this is a build-mode migration notice. Before the next major, add the `Ollama` trait to package dependencies or register via DefaultBackends.register(_:); see README 'Build modes' and #714.")
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
            // `GenerationEvent.toolCall`.
            supportsToolCalling: true,
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
            // Ollama emits tool calls as whole entries on a single NDJSON
            // line — no incremental `arguments` fragments arrive across
            // multiple lines (some `qwen2.5:7b` configs may stream deltas
            // but BCK treats Ollama as whole-call only for v1; see
            // TODO(#753) below in `parseResponseStream`).
            streamsToolCallArguments: false,
            // `/api/chat` is happy to return multiple `tool_calls[]` entries
            // in a single assistant message — the loop in `parseResponseStream`
            // emits them in array order so the orchestrator's serial dispatch
            // honours the model's intent.
            supportsParallelToolCalls: true
        )
    }

    // MARK: - Tool-Aware Conversation History

    /// Cached tool-aware history from the most recent
    /// `setToolAwareHistory(_:)` call. Consumed once by `buildRequest` and
    /// cleared after use so a subsequent non-tool generation falls back to the
    /// plain string history in `conversationHistory`.
    private var toolAwareHistory: [ToolAwareHistoryEntry]?

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

        self.isThinkingModel = probed.thinking
        let resolvedContextWindow = probed.contextLength ?? max(resolvedNumCtx, Self.defaultNumCtxFloor)
        let manifest = ModelManifest(
            contextWindow: resolvedContextWindow,
            supportsTools: true,
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
        config: GenerationConfig
    ) throws -> URLRequest {
        guard let baseURL else {
            throw CloudBackendError.invalidURL("No base URL configured")
        }

        let chatURL = baseURL.appendingPathComponent("api/chat")

        // Build the messages array. When tool-aware history is present (set
        // by the orchestrator in the middle of a tool-dispatch loop), we emit
        // the OpenAI-compatible shape Ollama expects:
        //   - assistant entries optionally carry a `tool_calls` array with
        //     {id, type: "function", function: {name, arguments}} entries.
        //   - tool entries carry `tool_call_id` alongside role and content.
        // When tool-aware history is absent we fall back to the classic
        // ConversationHistoryReceiver string tuples — this preserves the
        // shape every existing OllamaBackend test asserts on.
        var messages: [[String: Any]] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        // Snapshot and clear: tool-aware history is a one-shot payload supplied
        // by the orchestrator loop. If a subsequent non-tool generation runs on
        // the same backend instance, it must fall back to `conversationHistory`
        // rather than replaying stale tool-result messages.
        let snapshotToolHistory: [ToolAwareHistoryEntry]? = withStateLock {
            let snapshot = self.toolAwareHistory
            self.toolAwareHistory = nil
            return snapshot
        }
        if let toolHistory = snapshotToolHistory {
            messages.append(contentsOf: CloudMessageEncoder.ollama.encodeMessages(
                systemPrompt: nil,
                prompt: "",
                structuredHistory: nil,
                toolAwareHistory: toolHistory,
                plainHistory: nil
            ))
        } else if let history = conversationHistory {
            messages.append(contentsOf: history.map { ["role": $0.role, "content": $0.content] })
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
        if config.jsonMode {
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
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Log.network.debug("OllamaBackend request to \(chatURL.absoluteString, privacy: .public) model=\(self.modelName, privacy: .public)")

        return request
    }

    // MARK: - NDJSON Stream Parsing

    // TODO: (#189) Detect Ollama model-loading state and set GenerationStream
    // phase to .loading. Requires the monitoring task pattern from
    // GenerationStream to detect the pre-first-token stall that indicates
    // Ollama is loading the model into VRAM. The stall detection at
    // timeout/2 partially addresses this by showing .stalled.

    /// Parses Ollama's NDJSON response format instead of SSE.
    public override func parseResponseStream(
        bytes: URLSession.AsyncBytes,
        config: GenerationConfig,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        var processor = OllamaStreamProcessor(
            limits: effectiveSSEStreamLimits,
            config: config,
            autoDetectedThinkingMarkers: withStateLock { _autoDetectedThinkingMarkers },
            continuation: continuation,
            handleUsage: { [weak self] usage in self?.handleUsage(usage) }
        )
        try await processor.parse(bytes: bytes)
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
            var errorBodyData = Data()
            for try await byte in bytes {
                errorBodyData.append(byte)
                if errorBodyData.count > 2048 { break }
            }
            let errorBody = String(decoding: errorBodyData, as: UTF8.self)
            Log.network.debug("Ollama upstream error body: \(errorBody, privacy: .private)")
            let host = self.baseURL?.host()
            let message = CloudErrorSanitizer.sanitize(
                OllamaModelProbe.extractErrorMessage(from: errorBody),
                host: host
            )
            throw CloudBackendError.serverError(statusCode: statusCode, message: message)
        }
    }

    // MARK: - ToolCallingHistoryReceiver

    public func setToolAwareHistory(_ messages: [ToolAwareHistoryEntry]) {
        withStateLock { self.toolAwareHistory = messages }
    }

    // MARK: - Unload

    public override func unloadModel() {
        withStateLock {
            _manifest = nil
            _autoDetectedThinkingMarkers = nil
        }
        isThinkingModel = false
        super.unloadModel()
    }
}
#endif

