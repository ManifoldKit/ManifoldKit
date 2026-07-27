import Foundation
import os
import ManifoldInference
import ManifoldCloudCore

/// Anthropic Claude API inference backend.
///
/// Streams completions from the Anthropic Messages API (`/v1/messages`).
/// Handles Claude-specific SSE event types (`content_block_delta`, etc.)
/// and authentication via `x-api-key` header.
public final class ClaudeBackend: SSECloudBackend, TokenUsageProvider, EndpointBackendKeychainConfigurable, @unchecked Sendable {

    // MARK: - Adapter composition (Phase 3/Claude)
    //
    // `ClaudeBackend` composes a `CloudHTTPProviderAdapter` (specifically
    // `ClaudeAdapter`) so the cross-backend audit (`CloudSeamUsageAuditTest`)
    // recognises it as on the unified-adapter path. The adapter holds the
    // per-provider divergences identified by the cross-backend audit
    // (message encoding, payload handling, framing transport, stream
    // finalization, tool-call shape, image input shape, structured-output
    // shape, tool-result encoding, prompt-cache shape, error-body decoding)
    // as composable witnesses.
    //
    // **Routing status — fully flipped (Phase 3/Claude)**: the routing
    // drives `parseResponseStream` through `SSECloudBackend`'s envelope —
    // request building delegates back to `buildRequest` (the backend still
    // owns tool-aware history snapshot/clear, structured-history vision
    // pre-flight, per-turn cache-policy snapshotting, and just-in-time
    // keychain key resolution), framing is `SSETransport`, stream
    // consumption is a fresh-per-stream `ClaudeStreamEventExtractor`,
    // termination is `ClaudeMessageStopFinalizer`, and non-2xx error
    // bodies decode through `DefaultErrorBodyDecoder`. The inline
    // `parseResponseStream` override was removed alongside
    // `ClaudeToolCallAccumulator`.
    public let adapter: any CloudHTTPProviderAdapter

    // MARK: - Init

    /// Creates a Claude backend.
    ///
    /// - Parameter urlSession: Custom URLSession. Pass `nil` to use the default
    ///   session with certificate pinning enabled.
    ///
    /// When `urlSession` is `nil` and the runtime kill-switch
    /// ``URLSessionProvider/networkDisabled`` is set, the underlying property
    /// access traps. Use ``makeChecked(urlSession:)`` for a throwing variant
    /// that surfaces the kill-switch as a recoverable error.
    public init(urlSession: URLSession? = nil) {
        // Adapter capabilities mirror the dynamic `capabilities` property
        // for the default model (`claude-sonnet-4-20250514`) so the adapter
        // composition is valid immediately. The adapter's `requestBuilder`
        // is a no-op placeholder — the backend's `buildRequest` override is
        // the canonical request builder (it owns tool-aware history
        // snapshot/clear, structured-history vision pre-flight, per-turn
        // cache-policy snapshotting, and just-in-time keychain key
        // resolution), and the adapter-routed path threads it through the
        // routing's `buildRequest` closure (which forwards to
        // `self.buildRequest`).
        self.adapter = ClaudeAdapter(
            capabilities: Self.defaultAdapterCapabilities,
            requestBuilder: { _, _, _, _ in
                throw CloudBackendError.invalidURL(
                    "ClaudeAdapter.requestBuilder is not the live path; the ClaudeBackend installs a CloudAdapterRouting that delegates to its own buildRequest override."
                )
            }
        )
        super.init(
            defaultModelName: "claude-sonnet-4-20250514",
            urlSession: urlSession ?? URLSessionProvider.pinned,
            payloadHandler: CloudPayloadHandler.claude
        )

        // Phase 3/Claude — install adapter routing and the per-stream
        // `ClaudeStreamEventExtractor` factory. The envelope
        // (`CloudRoutedStreamParser`) drives event
        // extraction through a fresh consumer per generation, so tool_use
        // accumulator state, the open-thinking flag, and split-usage
        // merging stay isolated. The inline `parseResponseStream`
        // override has been removed; this is the only live path.
        let weakSelfBox = WeakClaudeBackendBox(self)
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
            streamConsumerFactory: { ClaudeStreamEventExtractor() }
        )
        self.configure(adapterRouting: routing)
    }

    /// Static adapter capabilities used at init time. Mirrors the dynamic
    /// `capabilities` property's values for `claude-sonnet-4-20250514` so
    /// the adapter composition is valid immediately. The dynamic property
    /// remains the authoritative source once a real `modelName` is
    /// configured.
    private static let defaultAdapterCapabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP],
        maxContextTokens: 200_000,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true,
        supportsToolCalling: true,
        supportsStructuredOutput: true,
        supportsNativeJSONMode: false,
        cancellationStyle: .cooperative,
        supportsTokenCounting: false,
        memoryStrategy: .external,
        maxOutputTokens: 8192,
        supportsStreaming: true,
        isRemote: true,
        supportsThinking: true,
        supportsVision: true,
        streamsToolCallArguments: true,
        supportsParallelToolCalls: true,
        // Anthropic `structured-outputs-2025-11-13`: strict tools / output_format
        // guarantee schema-valid output (#1918).
        supportsStrictSchema: true,
        // Cloud Messages API sends a structured message array on the wire, so
        // `.promptRendered` carries only the latest user message, not the full
        // post-template prompt — a partial view (#1905).
        rendersFullPrompt: false
    )

    // MARK: - Prompt Cache Policy

    private var _cachePolicy: PromptCachePolicy = .automatic

    /// Controls whether Anthropic prompt-cache breakpoints are inserted into
    /// outbound requests. Defaults to `.automatic`, which tags the system
    /// prompt block and the last tool definition with
    /// `cache_control: {type: "ephemeral"}` — reducing repeat-turn input costs
    /// by 4–10× for large system prompts or tool catalogs. Set to `.disabled`
    /// to restore pre-0.25.0 behaviour.
    public var cachePolicy: PromptCachePolicy {
        get { withStateLock { _cachePolicy } }
        set { withStateLock { _cachePolicy = newValue } }
    }

    /// Throwing factory that propagates ``URLSessionProvider/networkDisabled``
    /// as ``CloudBackendError/networkDisabled`` instead of trapping.
    ///
    /// - Parameter urlSession: Optional custom URLSession.
    /// - Throws: ``CloudBackendError/networkDisabled`` when the runtime
    ///   kill-switch is set and `urlSession` is `nil`.
    public static func makeChecked(urlSession: URLSession? = nil) throws -> ClaudeBackend {
        let session: URLSession
        if let urlSession {
            session = urlSession
        } else {
            session = try URLSessionProvider.throwingPinned()
        }
        return ClaudeBackend(urlSession: session)
    }

    // MARK: - Subclass Hooks

    public override var backendName: String { "Claude" }

    /// Manifest looked up from ``CloudModelManifestTable/claude(modelName:)``
    /// against the configured ``modelName``.
    ///
    /// Returns an `unknown(...)` manifest for any model name that doesn't
    /// prefix-match a table entry — same conservative-by-default policy as
    /// ``OpenAIBackend/manifest``.
    public override var manifest: ModelManifest? {
        CloudModelManifestTable.claude(modelName: modelName)
    }

    public override var capabilities: BackendCapabilities {
        // Manifest is the source of truth for context window + thinking
        // capability. Falls back to Anthropic's mainstream 200k baseline
        // and "extended thinking enabled" until the table covers a model
        // name — Claude 4-class models all support thinking, so the
        // optimistic default is safer than under-reporting and silently
        // hiding the reasoning UI.
        //
        // The 200k fallback applies only when the manifest genuinely has no
        // context window (`nil`). It used to be selected by comparing against
        // the literal `8192` that `ModelManifest.unknown()` fabricated, which
        // reached across a module boundary into another target's magic number:
        // a genuine 8k Claude entry would have been silently inflated to 200k,
        // and moving that constant would have silently shrunk every unknown
        // Claude model to it. Absence is now on the type.
        let resolvedManifest = manifest ?? .unknown(modelIdentifier: modelName, producerKind: .cloud)
        let resolvedContext = Int32(resolvedManifest.contextWindow ?? 200_000)
        return BackendCapabilities(
            supportedParameters: [.temperature, .topP, .topK],
            maxContextTokens: resolvedContext,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            // Anthropic Messages API tool calling: the request encodes BCK
            // ``ToolDefinition``s into the `tools[]` envelope (`{name,
            // description, input_schema}`), the streaming response delivers
            // one `content_block` per tool_use call indexed by `index`, and
            // the backend bridges those blocks into the
            // ``GenerationEvent`` start/delta/toolCall sequence from
            // PR #783. Claude 3.5+ models routinely emit several `tool_use`
            // blocks per turn so parallel calls are supported natively.
            supportsToolCalling: true,
            supportsStructuredOutput: true,
            supportsNativeJSONMode: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false,
            memoryStrategy: .external,
            maxOutputTokens: 8192,
            supportsStreaming: true,
            isRemote: true,
            // Vision is gated on the configured model name — Claude 3, 3.5,
            // 3.7, and 4 families all accept images as content blocks; the
            // Claude 2 family and `claude-instant-*` do not. The
            // GenerationQueue's pre-flight reads this flag and rejects
            // image attachments before we ever build a request body, so an
            // outdated model name surfaces a clear "not vision-capable"
            // error rather than a 400 from Anthropic.
            supportsThinking: resolvedManifest.supportsThinking,
            supportsVision: BackendVisionCapability.claudeMessagesSupportsImageInput(modelName: modelName),
            streamsToolCallArguments: true,
            supportsParallelToolCalls: true,
            // Anthropic `structured-outputs-2025-11-13`: strict tools / output_format
            // guarantee schema-valid output (#1918).
            supportsStrictSchema: true,
            // Structured message array on the wire → partial `.promptRendered` (#1905).
            rendersFullPrompt: false
        )
    }

    /// Anthropic's per-turn cap on inline base64 images. The Messages API
    /// rejects more than this with HTTP 400. Surface a clear local error
    /// instead so callers can prompt the user to drop attachments without
    /// burning a round-trip.
    static let maxImagesPerTurn: Int = 5

    // MARK: - Model Lifecycle

    // Plan is informational for cloud backends.
    public override func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        guard baseURL != nil else {
            throw CloudBackendError.invalidURL("No base URL configured")
        }
        guard let key = resolveAPIKeySecure(), !key.stringValue.isEmpty else {
            throw CloudBackendError.missingAPIKey
        }
        setIsModelLoaded(true)
        Log.inference.info("Claude backend loaded (model: \(self.modelName))")
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
        guard let apiKeySecure = resolveAPIKeySecure(), !apiKeySecure.stringValue.isEmpty else {
            throw CloudBackendError.missingAPIKey
        }
        let apiKey = apiKeySecure.stringValue

        let messagesURL = baseURL.appendingPathComponent("v1/messages")

        // Per-call conversation history, threaded on the stack (#2312) — never
        // read from shared instance state.
        let history = hints.history

        // Precedence:
        //   1. tool-aware history — present during a tool-call loop (any turn
        //      carries a tool call/result part), must win so the model sees the
        //      `tool_use` ↔ `tool_result` pairing it requires.
        //   2. structured history — carries thinking blocks with signatures
        //      for multi-turn extended-thinking replay (#604) and image
        //      content blocks for vision turns.
        //   3. prompt-only single user turn.
        let chatMessages: [[String: Any]]
        if history.containsToolParts {
            chatMessages = CloudMessageEncoder.claude.encodeMessages(
                systemPrompt: nil,
                prompt: "",
                structuredHistory: nil,
                toolAwareHistory: history.toolAwareHistory,
                plainHistory: nil
            )
        } else if !history.isEmpty {
            // Per-turn image cap: Anthropic rejects more than 5 inline
            // base64 images on a single turn. Validate before serialising
            // so the failure message names the offending turn rather than
            // surfacing as an opaque HTTP 400 from Anthropic.
            for message in history {
                let count = CloudImageEncoding.imageCount(in: message.parts)
                if count > Self.maxImagesPerTurn {
                    throw InferenceError.inferenceFailure(
                        "Claude accepts at most \(Self.maxImagesPerTurn) images per message; this \(message.role) turn has \(count). Drop attachments and retry."
                    )
                }
            }
            // Vision pre-flight: if the configured model isn't vision-capable
            // and the structured history carries any image, fail with a
            // clear local error. (GenerationQueue already gates this
            // path on `capabilities.supportsVision`, but the backend may be
            // driven directly — e.g. the OpenAI-compat server — so keep the
            // belt-and-suspenders check here.)
            let totalImages = CloudImageEncoding.imageCount(in: history)
            if totalImages > 0, !BackendVisionCapability.claudeMessagesSupportsImageInput(modelName: modelName) {
                throw InferenceError.inferenceFailure(
                    "Model \"\(modelName)\" does not support image input. Switch to a Claude 3, 3.5, 3.7, or 4 family model and retry."
                )
            }
            chatMessages = history.map { CloudMessageEncoder.claude.encodeStructuredMessageContent(for: $0) }
        } else {
            chatMessages = [["role": "user", "content": prompt]]
        }

        var body: [String: Any] = [
            "model": modelName,
            "max_tokens": config.maxOutputTokens ?? 2048,
            "messages": chatMessages,
            "stream": true,
            "temperature": config.temperature,
            "top_p": config.topP
        ]
        // Anthropic's Messages API accepts `top_k`. Encode it only when the
        // caller set one — leaving it out keeps Anthropic on its own default,
        // and matches the `.topK` entry in `capabilities.supportedParameters`.
        if let topK = config.topK {
            body["top_k"] = Int(topK)
        }
        // User-settable stop sequences (#1944). Anthropic uses `stop_sequences`;
        // emit only when non-empty to preserve the prior payload shape for
        // callers that never set stops.
        if !config.stopSequences.isEmpty {
            body["stop_sequences"] = config.stopSequences
        }

        // Snapshot cache policy under the lock once so the rest of the build
        // is consistent even if another thread toggles it concurrently.
        let resolvedCachePolicy = withStateLock { _cachePolicy }

        if let systemPrompt, !systemPrompt.isEmpty {
            if resolvedCachePolicy == .automatic {
                // Emit as a single-element content-block array so Anthropic can
                // cache the entire prefix up to and including this block. The
                // plain-string form has no slot for cache_control.
                body["system"] = [
                    [
                        "type": "text",
                        "text": systemPrompt,
                        "cache_control": ["type": "ephemeral"],
                    ] as [String: Any]
                ]
            } else {
                body["system"] = systemPrompt
            }
        }

        // Enable extended thinking when the caller asked for a thinking budget.
        // Anthropic requires the budget to be strictly less than max_tokens and
        // temperature to be 1.0 when thinking is enabled; surface a clamped
        // request rather than silently dropping the parameter.
        if let budget = config.maxThinkingTokens, budget > 0 {
            let maxTokens = (body["max_tokens"] as? Int) ?? 2048
            let clampedBudget = min(budget, max(1024, maxTokens - 1))
            body["thinking"] = [
                "type": "enabled",
                "budget_tokens": clampedBudget
            ] as [String: Any]
            body["temperature"] = 1.0
        }

        // Tool definitions — Anthropic's `tools[]` envelope is
        // `[{name, description, input_schema}]`. `tool_choice` accepts
        // `auto` / `any` / `tool(name)`. `.none` is not a wire value on
        // Anthropic's side; the framework-level `.none` suppresses the
        // tools field entirely so the model has nothing to call.
        if !config.tools.isEmpty, config.toolChoice != .none {
            // Strict structured output (#1918): when the caller passes an
            // explicit `.jsonSchema(...)` strategy and this backend advertises
            // strict-schema support, encode each tool's `input_schema` in
            // Anthropic's strict shape and flag `strict: true`.
            let strictRequested = capabilities.supportsStrictSchema
                && StrictSchemaTransform.jsonSchemaString(from: hints.structuredOutput) != nil
            var toolEntries = CloudMessageEncoder.claude.encodeTools(config.tools, strict: strictRequested)
            // Tag the last tool entry with cache_control when automatic so
            // Anthropic caches the entire system+tools prefix. The breakpoint
            // applies to the last block in the tagged sequence — tagging every
            // entry would create redundant breakpoints and potentially conflict
            // with the system-prompt breakpoint already set above.
            if resolvedCachePolicy == .automatic, !toolEntries.isEmpty {
                toolEntries[toolEntries.count - 1]["cache_control"] = ["type": "ephemeral"]
            }
            body["tools"] = toolEntries
            switch config.toolChoice {
            case .required:
                body["tool_choice"] = ["type": "any"]
            case .tool(let name):
                body["tool_choice"] = [
                    "type": "tool",
                    "name": name,
                ]
            case .none:
                // Unreachable: guarded above. The .none case suppresses
                // tools entirely rather than sending a tool_choice value.
                break
            case .auto:
                // Anthropic defaults to auto when tool_choice is omitted.
                break
            @unknown default:
                // Any unknown future ToolChoice mode: omit the field.
                break
            }
        }

        var request = URLRequest(url: messagesURL)
        request.httpMethod = "POST"
        // Generous timeout for streaming — covers inter-packet gaps during slow generation.
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return request
    }

    /// Claude reports usage split across `message_start` (prompt) and
    /// `message_delta` (completion). Two arrival shapes are possible:
    ///   - Routed-consumer path: `ClaudeStreamEventExtractor` merges the
    ///     two halves and yields a single `.usage(TokenUsage)`
    ///     event, which the envelope mirrors here with BOTH halves
    ///     populated.
    ///   - Legacy non-consumer paths (no streamConsumerFactory installed):
    ///     each half arrives in a separate call, so we merge incrementally.
    /// Handle both: when both halves are populated, store them verbatim;
    /// when only one is, fold it into the previously-seen half.
    public override func handleUsage(_ usage: (promptTokens: Int?, completionTokens: Int?)) {
        if let prompt = usage.promptTokens, let completion = usage.completionTokens {
            lastUsage = (promptTokens: prompt, completionTokens: completion)
        } else if let promptTokens = usage.promptTokens {
            let existing = lastUsage?.completionTokens ?? 0
            lastUsage = (promptTokens: promptTokens, completionTokens: existing)
        } else if let completionTokens = usage.completionTokens {
            let existing = lastUsage?.promptTokens ?? 0
            lastUsage = (promptTokens: existing, completionTokens: completionTokens)
        }
    }

    // MARK: - HTTP Status Validation

    public override func checkStatusCode(
        _ response: HTTPURLResponse,
        bytes: URLSession.AsyncBytes
    ) async throws {
        let statusCode = response.statusCode

        switch statusCode {
        case 200...299:
            return
        case 401, 403:
            throw CloudBackendError.authenticationFailed(provider: "Claude")
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap { TimeInterval($0) }
            throw CloudBackendError.rateLimited(retryAfter: retryAfter)
        case 529:
            // Claude-specific "overloaded" status — provider is temporarily at
            // capacity. Distinct from 503 Service Unavailable; signals a known
            // operational state rather than a generic server fault, so callers
            // can apply purpose-built backoff rather than the generic 5xx path.
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap { TimeInterval($0) }
            throw CloudBackendError.providerOverloaded(provider: "Claude", retryAfter: retryAfter)
        default:
            let sanitized = await drainAndSanitizeErrorBody(bytes)
            throw CloudBackendError.sanitizedServerError(
                statusCode: statusCode,
                rawMessage: sanitized
            )
        }
    }

}

/// Sendable weak reference used by the routing closure to call back into
/// the backend's `buildRequest` without retaining `self`. Matches the
/// `WeakBackendBox` pattern used by `OpenAIBackend`.
private final class WeakClaudeBackendBox: @unchecked Sendable {
    weak var value: ClaudeBackend?
    init(_ value: ClaudeBackend) { self.value = value }
}

