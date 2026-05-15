#if CloudSaaS
import Foundation
import os
import ManifoldInference
import ManifoldCloudCore

/// Cloud inference backend using the OpenAI Chat Completions API.
///
/// Compatible with OpenAI, Ollama, LM Studio, and any OpenAI-compatible endpoint.
/// Streams responses via Server-Sent Events (SSE).
///
/// Usage:
/// ```swift
/// let backend = OpenAIBackend()
/// backend.configure(
///     baseURL: URL(string: "https://api.openai.com")!,
///     apiKey: "sk-...",
///     modelName: "gpt-4o-mini"
/// )
/// try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
/// let stream = try backend.generate(prompt: "Hello", systemPrompt: nil, config: .init())
/// for try await event in stream.events { if case .token(let t) = event { print(t, terminator: "") } }
/// ```
public final class OpenAIBackend: SSECloudBackend, TokenUsageProvider, CloudBackendURLModelConfigurable, CloudBackendKeychainConfigurable, StructuredHistoryReceiver, ToolCallingHistoryReceiver, @unchecked Sendable {

    // MARK: - Adapter composition (Phase 2/B/ii)
    //
    // `OpenAIBackend` composes a `CloudHTTPProviderAdapter` (specifically
    // `OpenAIAdapter`) so the cross-backend audit
    // (`CloudSeamUsageAuditTest`) recognises it as on the unified-adapter
    // path. The adapter holds the seven per-provider divergences described
    // in the audit (message encoding, payload handling, framing
    // transport, stream finalization, tool-call shape, image input shape,
    // structured-output shape, tool-result encoding, prompt-cache shape,
    // error-body decoding) as composable witnesses.
    //
    // **Routing status — staged**: the adapter is *exposed* through this
    // property and consulted by the audit; the existing
    // `parseResponseStream` / `buildRequest` paths still drive
    // generation directly. Phase 2/B/iii will invert the call: the
    // backend body becomes a thin host that asks the adapter for the
    // framing transport and stream finalizer rather than running the
    // SSE loop inline. We split the inversion out of this PR to keep
    // the behavioural-parity diff reviewable — the adapter wiring lands
    // here, the runtime re-routing lands next.
    public let adapter: any CloudHTTPProviderAdapter

    // MARK: - Init

    /// Creates an OpenAI-compatible backend.
    ///
    /// - Parameter urlSession: Custom URLSession. Pass `nil` to use the default
    ///   session with certificate pinning enabled.
    ///
    /// When `urlSession` is `nil` and the runtime kill-switch
    /// ``URLSessionProvider/networkDisabled`` is set, the underlying property
    /// access traps. Use ``makeChecked(urlSession:)`` for a throwing variant
    /// that surfaces the kill-switch as a recoverable error.
    public init(urlSession: URLSession? = nil) {
        // Adapter capabilities mirror what `OpenAIBackend.capabilities`
        // would resolve for the default model name (`gpt-4o-mini`). The
        // adapter's `requestBuilder` is a no-op placeholder — the
        // backend's `buildRequest` override is the canonical request
        // builder, and the adapter-routed path below threads it through
        // the routing's `buildRequest` closure (which forwards to
        // `self.buildRequest`). The adapter itself remains the
        // composition root the cross-backend audit recognises.
        self.adapter = OpenAIAdapter(
            capabilities: Self.defaultAdapterCapabilities,
            requestBuilder: { _, _, _, _ in
                throw CloudBackendError.invalidURL(
                    "OpenAIAdapter.requestBuilder is not the live path; the OpenAIBackend installs a CloudAdapterRouting that delegates to its own buildRequest override."
                )
            }
        )
        super.init(
            defaultModelName: "gpt-4o-mini",
            urlSession: urlSession ?? URLSessionProvider.pinned,
            payloadHandler: CloudPayloadHandler.openAI
        )

        // Phase 2/B/iii/δ — install adapter routing so the stream loop
        // runs in `SSECloudBackend.parseResponseStreamRouted` and event
        // extraction is driven by a fresh per-stream
        // `OpenAIStreamEventExtractor`. This is the inversion the
        // staged Phase 2/B preamble set up: the backend body stops
        // overriding `parseResponseStream` and becomes a thin host
        // around the adapter + extractor.
        //
        // The routing's `buildRequest` closure forwards to
        // `self.buildRequest` (captured weakly) so all the stateful
        // pieces — tool-aware-history snapshot/clear, structured-history
        // vision pre-flight, manifest-gated parameter gating, just-in-
        // time keychain key resolution — keep running on the backend
        // where they own their state.
        let weakSelfBox = WeakBackendBox(self)
        let routing = CloudAdapterRouting(
            payloadHandler: adapter.payloadHandler,
            framedTransport: adapter.framedTransport,
            streamFinalizer: adapter.streamFinalizer,
            errorBodyDecoder: adapter.errorBodyDecoder,
            buildRequest: { prompt, systemPrompt, config in
                guard let backend = weakSelfBox.value else {
                    throw CloudBackendError.backendDeallocated
                }
                return try backend.buildRequest(
                    prompt: prompt,
                    systemPrompt: systemPrompt,
                    config: config
                )
            },
            streamConsumerFactory: { OpenAIStreamEventExtractor() }
        )
        self.configure(adapterRouting: routing)
    }

    /// Static adapter capabilities used at init time. Mirrors the dynamic
    /// `capabilities` property's values for `gpt-4o-mini` so the adapter
    /// composition is valid immediately. The dynamic property remains the
    /// authoritative source once a real `modelName` is configured.
    private static let defaultAdapterCapabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP],
        maxContextTokens: 128_000,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true,
        supportsToolCalling: true,
        supportsStructuredOutput: true,
        supportsNativeJSONMode: true,
        cancellationStyle: .cooperative,
        supportsTokenCounting: false,
        memoryStrategy: .external,
        maxOutputTokens: 16_384,
        supportsStreaming: true,
        isRemote: true,
        supportsVision: true,
        streamsToolCallArguments: true,
        supportsParallelToolCalls: true
    )

    /// Throwing factory that propagates ``URLSessionProvider/networkDisabled``
    /// as ``CloudBackendError/networkDisabled`` instead of trapping.
    public static func makeChecked(urlSession: URLSession? = nil) throws -> OpenAIBackend {
        let session: URLSession
        if let urlSession {
            session = urlSession
        } else {
            session = try URLSessionProvider.throwingPinned()
        }
        return OpenAIBackend(urlSession: session)
    }

    // MARK: - Subclass Hooks

    public override var backendName: String { "OpenAI" }

    /// Manifest looked up from ``CloudModelManifestTable/openAI(modelName:)``
    /// against the configured ``modelName``.
    ///
    /// Cloud backends can't introspect the model at runtime, so the manifest
    /// is derived from a vendored prefix table. Returns an `unknown(...)`
    /// manifest (conservative defaults: 8k context, no seed, no penalties)
    /// for any model name that doesn't prefix-match a table entry — that
    /// keeps the backend safe against new model releases without having to
    /// ship a code change for every API name.
    public override var manifest: ModelManifest? {
        CloudModelManifestTable.openAI(modelName: modelName)
    }

    public override var capabilities: BackendCapabilities {
        // Derive the wire-relevant context window from the manifest produced
        // at loadModel-time; fall back to OpenAI's mainstream 128k when the
        // host configured a model name we don't recognise.
        let resolvedContext = Int32(manifest?.contextWindow ?? 128_000)
        return BackendCapabilities(
            supportedParameters: [.temperature, .topP],
            maxContextTokens: resolvedContext,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            // Chat Completions tool calling: the request encodes BCK
            // ``ToolDefinition``s into OpenAI's `tools[]` envelope, the
            // streaming response delivers `tool_calls[]` deltas keyed by
            // `index`, and the backend buffers them so consumers see a clean
            // `.toolCallStart` → N×`.toolCallArgumentsDelta` → `.toolCall`
            // sequence per call.
            supportsToolCalling: true,
            supportsStructuredOutput: true,
            supportsNativeJSONMode: true,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false,
            memoryStrategy: .external,
            maxOutputTokens: 16_384,
            supportsStreaming: true,
            isRemote: true,
            // Vision support is gated on the configured model name. OpenAI's
            // vision-capable families (gpt-4o*, gpt-4-turbo, gpt-4.1, o1, o3)
            // accept `image_url` content parts; older completions-only models
            // do not. ``GenerationQueue``'s pre-flight reads this flag
            // and rejects image attachments before we ever build a request,
            // so a non-vision model surfaces a clear local error rather than
            // a 400 from upstream.
            supportsVision: BackendVisionCapability.openAIChatCompletionsSupportsImageInput(modelName: modelName),
            streamsToolCallArguments: true,
            supportsParallelToolCalls: true
        )
    }

    // MARK: - Structured History

    /// Structured replay history. Set by ``GenerationQueue`` when the
    /// caller uses ``InferenceService/enqueue(structuredMessages:...)``;
    /// carries ``MessagePart/image(data:mimeType:)`` parts so vision turns
    /// can be serialised as `image_url` content parts on the request body.
    ///
    /// Also consumed by text-only multi-turn replay: when no image parts are
    /// present the encoder still uses the structured history so a user that
    /// later attaches an image gets the structured array shape consistently.
    private var _structuredHistory: [StructuredMessage]?

    public func setStructuredHistory(_ messages: [StructuredMessage]) {
        withStateLock { self._structuredHistory = messages }
    }

    // MARK: - Tool-Aware Conversation History

    /// Cached tool-aware history from the most recent
    /// `setToolAwareHistory(_:)` call. Consumed once by `buildRequest` and
    /// cleared after use so a subsequent non-tool generation falls back to the
    /// plain string history in `conversationHistory`.
    private var toolAwareHistory: [ToolAwareHistoryEntry]?

    public func setToolAwareHistory(_ messages: [ToolAwareHistoryEntry]) {
        withStateLock { self.toolAwareHistory = messages }
    }

    // MARK: - Model Lifecycle

    // Plan is informational for cloud backends.
    public override func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        guard baseURL != nil else {
            throw CloudBackendError.invalidURL(
                "No base URL configured. Call configure(baseURL:apiKey:modelName:) first."
            )
        }
        setIsModelLoaded(true)
        Log.inference.info("OpenAI backend configured for \(self.modelName, privacy: .public) at \(self.baseURL?.host() ?? "unknown", privacy: .public)")
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

        let completionsURL = baseURL.appendingPathComponent("v1/chat/completions")

        // Snapshot and clear: tool-aware history is a one-shot payload supplied
        // by the orchestrator loop. If a subsequent non-tool generation runs on
        // the same backend instance, it must fall back to `conversationHistory`
        // rather than replaying stale tool-result messages.
        let snapshotToolHistory: [ToolAwareHistoryEntry]? = withStateLock {
            let snapshot = self.toolAwareHistory
            self.toolAwareHistory = nil
            return snapshot
        }

        let structuredSnapshot: [StructuredMessage]? = withStateLock { self._structuredHistory }

        var messages: [[String: Any]] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }

        // Precedence:
        //   1. tool-aware history — only set during a tool-call loop, must
        //      win over the structured/plain replay so the model sees the
        //      `tool_calls` ↔ `tool` pairing it requires.
        //   2. structured history (only when it carries images) — emits
        //      `image_url` content parts for vision turns, and collapses
        //      text-only turns to plain string content for the common case.
        //   3. plain (role, content) history — legacy fallback. Keeps the
        //      common text-only wire shape minimal and matches every
        //      pre-vision OpenAIBackend test that asserts on it.
        //   4. prompt-only single user turn.
        if let toolHistory = snapshotToolHistory {
            messages.append(contentsOf: toolHistory.map(OpenAIToolEncoding.encodeChatCompletionsEntry))
        } else if let structured = structuredSnapshot,
                  !structured.isEmpty,
                  CloudImageEncoding.imageCount(in: structured) > 0 {
            // Vision pre-flight: refuse to forward images to a model that
            // doesn't advertise vision support. ``GenerationQueue``
            // already gates this path on `capabilities.supportsVision`, but
            // the backend may be driven directly (e.g. the OpenAI-compat
            // server, or callers wiring their own pipeline), so keep the
            // belt-and-suspenders check here.
            if !BackendVisionCapability.openAIChatCompletionsSupportsImageInput(modelName: modelName) {
                throw InferenceError.inferenceFailure(
                    "Model \"\(modelName)\" does not support image input. Switch to a vision-capable OpenAI model (gpt-4o, gpt-4o-mini, gpt-4-turbo, gpt-4.1, o1, o3) and retry."
                )
            }
            messages.append(contentsOf: structured.map { CloudMessageEncoder.openAI.encodeStructuredMessageContent(for: $0) })
        } else if let history = conversationHistory {
            // Reasoning-model asymmetry: OpenAI-compatible providers (DeepSeek,
            // o-series, hosted Qwen reasoning) deliver chain-of-thought via
            // `reasoning_content` / `reasoning` deltas but **don't** require
            // it on multi-turn replay — and most providers reject blocks they
            // didn't emit. ``GenerationQueue`` already collapsed
            // structured history to `(role, content)` text via
            // ``StructuredMessage/textContent``, which drops `.thinking`
            // parts. So thinking is informational only on this backend's
            // replay path. Anthropic's multi-turn signature contract is
            // handled by ``ClaudeBackend`` reading the structured history
            // directly. (#604)
            messages.append(contentsOf: history.map { ["role": $0.role, "content": $0.content] as [String: Any] })
        } else {
            messages.append(["role": "user", "content": prompt])
        }

        var body: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "stream": true,
            "stream_options": ["include_usage": true],
            "temperature": config.temperature,
            "top_p": config.topP,
            "max_tokens": config.maxOutputTokens ?? 2048
        ]
        if config.jsonMode {
            // OpenAI-native providers accept `response_format`; Ollama's
            // OpenAI-compatible adapter looks for the legacy top-level
            // `format: "json"` switch.
            body["format"] = "json"
            body["response_format"] = ["type": "json_object"]
        }

        // Manifest-gated extra parameters. Reasoning models (`o1`/`o3`/`o4`)
        // reject `seed` and most penalties — gating per-model on the
        // manifest avoids HTTP 400s that previously surfaced as cryptic
        // "Unsupported parameter" upstream errors.
        let resolvedManifest = manifest ?? .unknown(modelIdentifier: modelName, producerKind: .cloud)
        if resolvedManifest.supportsSeed, let seed = config.seed {
            // OpenAI accepts `seed` as a 32-bit signed integer in JSON.
            // Truncate the 64-bit storage to that range — matches what the
            // wire format will accept anyway.
            body["seed"] = Int(truncatingIfNeeded: seed)
        }
        if resolvedManifest.supportedSamplingParameters.contains(.presencePenalty),
           let presence = config.presencePenalty {
            body["presence_penalty"] = presence
        }
        if resolvedManifest.supportedSamplingParameters.contains(.frequencyPenalty),
           let frequency = config.frequencyPenalty {
            body["frequency_penalty"] = frequency
        }
        if resolvedManifest.supportedSamplingParameters.contains(.topK),
           let topK = config.topK {
            body["top_k"] = Int(topK)
        }

        // Tool definitions — OpenAI accepts the canonical
        // `[{type:"function", function:{...}}]` envelope. `tool_choice` is
        // applied via the shared encoding helper so the same logic powers
        // ``OpenAIResponsesBackend``.
        if !config.tools.isEmpty {
            body["tools"] = CloudMessageEncoder.openAI.encodeTools(config.tools)
            OpenAIToolEncoding.applyToolChoice(config.toolChoice, into: &body)
        }

        var request = URLRequest(url: completionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if config.streamPrefillProgress {
            request.setValue("true", forHTTPHeaderField: "X-Manifold-Prefill-Progress")
        }

        if let secureKey = resolveAPIKeySecure() {
            let keyString = secureKey.stringValue
            if !keyString.isEmpty {
                request.setValue("Bearer \(keyString)", forHTTPHeaderField: "Authorization")
            }
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Log.network.debug("OpenAI request to \(completionsURL.absoluteString, privacy: .public) model=\(self.modelName, privacy: .public)")

        return request
    }

    // MARK: - Stream Parsing
    //
    // Phase 2/B/iii/δ deleted the inline `parseResponseStream` override and
    // its `process*` step cluster. The adapter routing installed at
    // `init(urlSession:)` time threads stream parsing through
    // `SSECloudBackend.parseResponseStreamRouted`, which drives a fresh
    // `OpenAIStreamEventExtractor` per generation. The extractor (shipped
    // in #1269) owns the per-stream state — open-thinking flag, index-
    // keyed tool-call delta buffer, once-only finalisation guard — that
    // previously lived in `ChatCompletionsStreamState` on this class.

    // MARK: - SSE Payload Handler

    /// OpenAI-specific SSE payload interpreter for use with `SSEStreamParser.streamTokens`.
    ///
    /// Retained as a deprecated alias so external subclasses keep compiling.
    /// New call sites use ``CloudPayloadHandler/openAI``, which dispatches
    /// through ``legacyExtractToken(from:)`` / ``legacyExtractUsage(from:)``
    /// below.
    static let payloadHandler: any SSEPayloadHandler = CloudPayloadHandler.openAI

    /// Internal seam used by ``CloudPayloadHandler/openAI`` to read tokens
    /// without exposing the originally-private parser.
    static func legacyExtractToken(from payload: String) -> String? {
        parseToken(from: payload)
    }

    /// Internal seam used by ``CloudPayloadHandler/openAI`` to read usage
    /// without exposing the originally-private parser.
    static func legacyExtractUsage(from payload: String) -> (promptTokens: Int, completionTokens: Int)? {
        parseUsage(from: payload)
    }

    // MARK: - JSON Parsing

    /// Extracts the content token from an OpenAI streaming response chunk.
    ///
    /// Expected format:
    /// ```json
    /// {"choices":[{"delta":{"content":"token"}}]}
    /// ```
    private static func parseToken(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = parsed["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let delta = firstChoice["delta"] as? [String: Any],
              let content = delta["content"] as? String else {
            return nil
        }
        return content
    }

    /// Extracts reasoning text from an OpenAI-compatible Chat Completions delta.
    ///
    /// Two shapes are recognised:
    /// ```json
    /// {"choices":[{"delta":{"reasoning_content":"..."}}]}
    /// {"choices":[{"delta":{"reasoning":"..."}}]}
    /// ```
    /// The `reasoning_content` field is used by DeepSeek R1 and by OpenAI-
    /// compatible hosts that mirror DeepSeek's convention; `reasoning` is used
    /// by some newer OpenAI-hosted reasoning deployments. Anything else —
    /// including plain `content` — returns `nil` so the caller can fall back
    /// to the standard token extractor.
    static func parseReasoningDelta(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = parsed["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let delta = firstChoice["delta"] as? [String: Any] else {
            return nil
        }
        if let content = delta["reasoning_content"] as? String, !content.isEmpty {
            return content
        }
        if let content = delta["reasoning"] as? String, !content.isEmpty {
            return content
        }
        return nil
    }

    // MARK: - Tool-call delta parsing

    /// Decoded shape of one streaming `tool_calls[]` entry inside a `delta`.
    struct ToolCallDelta {
        let index: Int
        let id: String?
        let name: String?
        let argumentsDelta: String?
    }

    /// Decoded shape of one whole `message.tool_calls[]` entry (non-streaming
    /// path or compat servers that deliver completed calls in a single chunk).
    struct WholeToolCall {
        let id: String
        let name: String
        let arguments: String
    }

    /// Parses `choices[0].delta.tool_calls[]` from a streaming chunk.
    ///
    /// Each entry carries an `index` (required), an `id` and `function.name`
    /// (typically only on the first delta for that index), and a
    /// `function.arguments` fragment (typically on subsequent deltas).
    /// Compat servers vary on whether `id` is repeated; the accumulator
    /// handles that by stickying the first non-empty value seen per index.
    static func parseToolCallDeltas(from json: String) -> [ToolCallDelta] {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = parsed["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let delta = firstChoice["delta"] as? [String: Any],
              let rawCalls = delta["tool_calls"] as? [[String: Any]] else {
            return []
        }

        var result: [ToolCallDelta] = []
        for raw in rawCalls {
            guard let index = raw["index"] as? Int else { continue }
            let id = raw["id"] as? String
            let function = raw["function"] as? [String: Any]
            let name = function?["name"] as? String
            let argumentsDelta = function?["arguments"] as? String
            result.append(ToolCallDelta(
                index: index,
                id: id,
                name: name,
                argumentsDelta: argumentsDelta
            ))
        }
        return result
    }

    /// Parses a whole `choices[0].message.tool_calls[]` array from a
    /// non-streaming response chunk.
    static func parseWholeToolCalls(from json: String) -> [WholeToolCall] {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = parsed["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let rawCalls = message["tool_calls"] as? [[String: Any]] else {
            return []
        }
        var result: [WholeToolCall] = []
        for raw in rawCalls {
            guard let function = raw["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  !name.isEmpty else {
                continue
            }
            let id = (raw["id"] as? String) ?? ""
            let arguments = (function["arguments"] as? String) ?? "{}"
            result.append(WholeToolCall(id: id, name: name, arguments: arguments))
        }
        return result
    }

    /// Parses `choices[0].finish_reason` (e.g. `"stop"`, `"tool_calls"`).
    static func parseFinishReason(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = parsed["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let reason = firstChoice["finish_reason"] as? String,
              !reason.isEmpty else {
            return nil
        }
        return reason
    }

    /// Extracts token usage from an OpenAI streaming response chunk.
    ///
    /// The final chunk includes usage when `stream_options.include_usage` is set:
    /// ```json
    /// {"choices":[...],"usage":{"prompt_tokens":25,"completion_tokens":100,"total_tokens":125}}
    /// ```
    private static func parseUsage(from json: String) -> (promptTokens: Int, completionTokens: Int)? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = parsed["usage"] as? [String: Any],
              let prompt = usage["prompt_tokens"] as? Int,
              let completion = usage["completion_tokens"] as? Int else {
            return nil
        }
        return (prompt, completion)
    }

    struct PrefillProgress {
        let nPast: Int
        let nTotal: Int
        let tokensPerSecond: Double
    }

    static func parsePrefillProgress(from json: String) -> PrefillProgress? {
        guard let data = json.data(using: .utf8) else {
            return nil
        }
        let parsed: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            parsed = object
        } catch {
            return nil
        }
        guard let nPast = parsed["n_past"] as? Int,
              let nTotal = parsed["n_total"] as? Int else {
            return nil
        }
        let tokensPerSecond: Double
        if let value = parsed["tokens_per_second"] as? Double {
            tokensPerSecond = value
        } else if let value = parsed["tokens_per_second"] as? Int {
            tokensPerSecond = Double(value)
        } else {
            return nil
        }
        return PrefillProgress(
            nPast: nPast,
            nTotal: nTotal,
            tokensPerSecond: tokensPerSecond
        )
    }

}

/// Sendable weak reference used by the routing closure to call back into
/// the backend's `buildRequest` without retaining `self`. Matches the
/// `WeakBox` pattern used inside `SSECloudBackend.generate`.
private final class WeakBackendBox: @unchecked Sendable {
    weak var value: OpenAIBackend?
    init(_ value: OpenAIBackend) { self.value = value }
}

#endif
