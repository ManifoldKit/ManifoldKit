#if CloudSaaS
import Foundation
import os
import ManifoldInference
import ManifoldCloudCore

/// Anthropic Claude API inference backend.
///
/// Streams completions from the Anthropic Messages API (`/v1/messages`).
/// Handles Claude-specific SSE event types (`content_block_delta`, etc.)
/// and authentication via `x-api-key` header.
public final class ClaudeBackend: SSECloudBackend, TokenUsageProvider, CloudBackendKeychainConfigurable, StructuredHistoryReceiver, ToolCallingHistoryReceiver, @unchecked Sendable {

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
        super.init(
            defaultModelName: "claude-sonnet-4-20250514",
            urlSession: urlSession ?? URLSessionProvider.pinned,
            payloadHandler: ClaudePayloadHandler()
        )
    }

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

    // MARK: - Structured History

    /// Structured replay history. Set by the coordinator when the caller
    /// uses ``InferenceService/enqueue(structuredMessages:...)``; carries
    /// the prior assistant turns' ``MessagePart/thinking(_:signature:)``
    /// blocks so the request body can include them with their signatures
    /// verbatim. Anthropic rejects multi-turn extended-thinking requests
    /// that drop or alter the signature.
    private var _structuredHistory: [StructuredMessage]?
    public var structuredHistory: [StructuredMessage]? {
        get { withStateLock { _structuredHistory } }
        set { withStateLock { _structuredHistory = newValue } }
    }

    public func setStructuredHistory(_ messages: [StructuredMessage]) {
        withStateLock { _structuredHistory = messages }
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
        let resolvedManifest = manifest ?? .unknown(modelIdentifier: modelName, producerKind: .cloud)
        let resolvedContext = Int32(resolvedManifest.contextWindow == 8192
            ? 200_000
            : resolvedManifest.contextWindow)
        return BackendCapabilities(
            supportedParameters: [.temperature, .topP],
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
            supportsParallelToolCalls: true
        )
    }

    /// Anthropic's per-turn cap on inline base64 images. The Messages API
    /// rejects more than this with HTTP 400. Surface a clear local error
    /// instead so callers can prompt the user to drop attachments without
    /// burning a round-trip.
    static let maxImagesPerTurn: Int = 5

    // MARK: - Tool-Aware Conversation History

    /// Cached tool-aware history from the most recent
    /// ``setToolAwareHistory(_:)`` call. Consumed once by ``buildRequest``
    /// and cleared after use so a subsequent non-tool generation falls back
    /// to the plain string history in ``conversationHistory`` (or the
    /// structured history when present). Same one-shot snapshot pattern
    /// used by ``OllamaBackend`` and ``OpenAIBackend``.
    private var _toolAwareHistory: [ToolAwareHistoryEntry]?

    public func setToolAwareHistory(_ messages: [ToolAwareHistoryEntry]) {
        withStateLock { self._toolAwareHistory = messages }
    }

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
        config: GenerationConfig
    ) throws -> URLRequest {
        guard let baseURL else {
            throw CloudBackendError.invalidURL("No base URL configured")
        }
        guard let apiKeySecure = resolveAPIKeySecure(), !apiKeySecure.stringValue.isEmpty else {
            throw CloudBackendError.missingAPIKey
        }
        let apiKey = apiKeySecure.stringValue

        let messagesURL = baseURL.appendingPathComponent("v1/messages")

        // Snapshot and clear: tool-aware history is a one-shot payload
        // supplied by the orchestrator during a tool-call loop. If a
        // subsequent non-tool generation runs on the same backend instance,
        // it must fall back to the structured/plain history rather than
        // replaying stale tool-result messages.
        let snapshotToolHistory: [ToolAwareHistoryEntry]? = withStateLock {
            let snapshot = self._toolAwareHistory
            self._toolAwareHistory = nil
            return snapshot
        }

        // Precedence:
        //   1. tool-aware history — only set during a tool-call loop, must
        //      win over the structured/plain replay so the model sees the
        //      `tool_use` ↔ `tool_result` pairing it requires.
        //   2. structured history — carries thinking blocks with signatures
        //      for multi-turn extended-thinking replay (#604) and image
        //      content blocks for vision turns.
        //   3. plain (role, content) history — legacy fallback.
        //   4. prompt-only single user turn.
        let chatMessages: [[String: Any]]
        if let toolHistory = snapshotToolHistory, !toolHistory.isEmpty {
            chatMessages = toolHistory.map(ClaudeMessageEncoder.encodeToolAwareEntry)
        } else if let structured = structuredHistory, !structured.isEmpty {
            // Per-turn image cap: Anthropic rejects more than 5 inline
            // base64 images on a single turn. Validate before serialising
            // so the failure message names the offending turn rather than
            // surfacing as an opaque HTTP 400 from Anthropic.
            for message in structured {
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
            let totalImages = CloudImageEncoding.imageCount(in: structured)
            if totalImages > 0, !BackendVisionCapability.claudeMessagesSupportsImageInput(modelName: modelName) {
                throw InferenceError.inferenceFailure(
                    "Model \"\(modelName)\" does not support image input. Switch to a Claude 3, 3.5, 3.7, or 4 family model and retry."
                )
            }
            chatMessages = structured.map(ClaudeMessageEncoder.encodeMessageContent(for:))
        } else if let history = conversationHistory {
            chatMessages = history.map { ["role": $0.role, "content": $0.content] }
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
            var toolEntries = config.tools.map(ClaudeMessageEncoder.encodeToolDefinition)
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
            case .auto:
                // Anthropic defaults to auto when tool_choice is omitted.
                break
            case .none:
                // Unreachable: guarded above. The .none case suppresses
                // tools entirely rather than sending a tool_choice value.
                break
            case .required:
                body["tool_choice"] = ["type": "any"]
            case .tool(let name):
                body["tool_choice"] = [
                    "type": "tool",
                    "name": name,
                ]
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
    /// `message_delta` (completion), so we merge incrementally.
    public override func handleUsage(_ usage: (promptTokens: Int?, completionTokens: Int?)) {
        if let promptTokens = usage.promptTokens {
            lastUsage = (promptTokens: promptTokens, completionTokens: 0)
        } else if let completionTokens = usage.completionTokens {
            let existing = lastUsage?.promptTokens ?? 0
            lastUsage = (promptTokens: existing, completionTokens: completionTokens)
        }
    }

    // MARK: - Stream Parsing

    /// Parses Claude's SSE response with extended-thinking support.
    ///
    /// Anthropic interleaves reasoning and visible content via typed content
    /// blocks. A typical extended-thinking response looks like:
    ///
    /// ```
    /// content_block_start {index:0, content_block:{type:"thinking"}}
    /// content_block_delta {index:0, delta:{type:"thinking_delta", thinking:"..."}}
    /// content_block_stop  {index:0}
    /// content_block_start {index:1, content_block:{type:"text"}}
    /// content_block_delta {index:1, delta:{type:"text_delta",     text:"..."}}
    /// content_block_stop  {index:1}
    /// message_stop
    /// ```
    ///
    /// We route `thinking_delta` chunks to ``GenerationEvent/thinkingToken(_:)``
    /// and emit a single ``GenerationEvent/thinkingComplete`` exactly once — on
    /// the first transition from a thinking block to any non-thinking event
    /// (text block start, token, usage, or terminal stop). Non-reasoning
    /// responses never fire `.thinkingComplete` because no thinking chunk was
    /// ever observed.
    ///
    /// Anthropic's extended-thinking blocks also carry an opaque
    /// `signature` — required verbatim on multi-turn replay. We surface it
    /// as ``GenerationEvent/thinkingSignature(_:)``, captured from either
    /// the `content_block_start` payload or a nested
    /// `signature_delta` (the path real production streams use today).
    /// See #604.
    public override func parseResponseStream(
        bytes: URLSession.AsyncBytes,
        config: GenerationConfig,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        let tokenStream = SSEStreamParser.parse(bytes: bytes, limits: effectiveSSEStreamLimits)

        // `thinking` flips to open the first time we see a thinking_delta.
        // It flushes — and fires .thinkingComplete exactly once — the first
        // time we see anything that clearly isn't thinking anymore.
        // Signature events bypass open/close entirely.
        var thinking = ThinkingBlockManager()

        let toolAccumulator = ClaudeToolCallAccumulator()

        do {
            for try await payload in tokenStream {
                if Task.isCancelled {
                    toolAccumulator.markCancelled()
                    break
                }

                let eventType = ClaudePayloadParser.parseEventType(from: payload)

                // Thinking-block start: opportunistically capture the signature
                // if Anthropic shipped one inline on the start event. Real
                // streams more commonly carry the signature on a later
                // `signature_delta`, but a couple of beta endpoints attach it
                // here, and the redundant emission is harmless — UI consumers
                // overwrite stored signatures rather than appending.
                if eventType == "content_block_start", let signature = ClaudePayloadParser.parseThinkingBlockStartSignature(from: payload) {
                    continuation.yield(.thinkingSignature(signature))
                    continue
                }

                // tool_use content_block_start — capture id + name and emit
                // `.toolCallStart`. Anthropic always carries id and name on
                // the start event itself, so we don't need the accumulator's
                // lazy-emit pattern.
                if eventType == "content_block_start", let toolStart = ClaudePayloadParser.parseToolUseBlockStart(from: payload) {
                    thinking.flushIfOpen(into: continuation)
                    toolAccumulator.handleToolUseBlockStart(toolStart, continuation: continuation)
                    continue
                }

                // input_json_delta — append to the accumulator and emit a
                // streaming `.toolCallArgumentsDelta` under the resolved call id.
                if eventType == "content_block_delta", let inputDelta = ClaudePayloadParser.parseInputJSONDelta(from: payload) {
                    toolAccumulator.handleInputJSONDelta(inputDelta, continuation: continuation)
                    continue
                }

                // content_block_stop on a tool_use index — finalize that one
                // call now so per-block latency is preserved. (Sibling text /
                // thinking blocks pass through this branch as a no-op.)
                if eventType == "content_block_stop", let stopIndex = ClaudePayloadParser.parseContentBlockIndex(from: payload),
                   toolAccumulator.isToolUseIndex(stopIndex) {
                    toolAccumulator.finalizeToolUse(at: stopIndex, continuation: continuation)
                    continue
                }

                // Signature delta inside the thinking block. Primary path
                // Anthropic uses today for extended-thinking signatures.
                if eventType == "content_block_delta", let signature = ClaudePayloadParser.parseSignatureDelta(from: payload) {
                    continuation.yield(.thinkingSignature(signature))
                    continue
                }

                // Thinking + plain text deltas: route via the handler's
                // `extractEvents`, which classifies thinking_delta vs.
                // text_delta in one place. Tool-use / signature / message_*
                // shapes return `[]` from the handler and are handled inline
                // above because they need cross-payload state the handler
                // cannot model.
                let payloadEvents = extractEvents(from: payload)
                for event in payloadEvents {
                    switch event {
                    case .thinkingToken:
                        continuation.yield(event)
                        thinking.open()
                    case .token:
                        thinking.flushIfOpen(into: continuation)
                        continuation.yield(event)
                    default:
                        continuation.yield(event)
                    }
                }

                // Non-streaming whole-message tool_use shape. Some callers
                // (synthesised replay fixtures, future non-streaming endpoint
                // variants) deliver the entire `content:[]` array on a single
                // payload. Treat each tool_use block as a uniform start +
                // single delta + toolCall triple so consumers don't have to
                // special-case the path.
                if let wholeCalls = ClaudePayloadParser.parseWholeMessageToolUseBlocks(from: payload), !wholeCalls.isEmpty {
                    thinking.flushIfOpen(into: continuation)
                    toolAccumulator.handleWholeMessageToolUseBlocks(wholeCalls, continuation: continuation)
                    continue
                }

                if let usage = extractUsage(from: payload) {
                    handleUsage(usage)
                    if let prompt = usage.promptTokens,
                       let completion = usage.completionTokens {
                        continuation.yield(.usage(prompt: prompt, completion: completion))
                    }
                }

                // Log prompt-cache activity from the message_start event so
                // operators can verify that breakpoints are being hit without
                // needing a structured extension to TokenUsage.
                if let cacheUsage = ClaudePayloadParser.parseCacheUsage(from: payload) {
                    Log.inference.debug(
                        "Claude prompt cache: creation=\(cacheUsage.cacheCreationInputTokens) read=\(cacheUsage.cacheReadInputTokens)"
                    )
                }

                if isStreamEnd(payload) {
                    thinking.flushIfOpen(into: continuation)
                    break
                }

                if let error = extractStreamError(from: payload) {
                    throw error
                }
            }
        } catch {
            // Close any open thinking block before rethrowing so consumers
            // don't hang in a thinking-only state on parser failure.
            thinking.flushIfOpen(into: continuation)
            throw error
        }

        if Task.isCancelled {
            toolAccumulator.markCancelled()
        }

        // Safety net: stream ended without a text block or message_stop while
        // still inside a thinking block (truncated upstream). Close the block
        // so consumers don't hang in a thinking-only state.
        thinking.flushIfOpen(into: continuation)
        // Stream end fallback: if the upstream closed without `message_stop`
        // (truncated, server hangup), emit any buffered tool calls now so
        // the orchestrator can still dispatch them. Cancellation suppresses
        // this branch via ClaudeToolCallAccumulator.
        toolAccumulator.finalizePendingToolUses(continuation: continuation)
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
        default:
            let errorBody = await Self.readErrorBody(from: bytes)
            Log.network.debug("Claude upstream error body: \(errorBody, privacy: .private)")
            let host = self.baseURL?.host()
            let sanitized = CloudErrorSanitizer.sanitize(
                extractErrorMessage(from: errorBody),
                host: host
            )
            throw CloudBackendError.serverError(
                statusCode: statusCode,
                message: sanitized
            )
        }
    }

    /// Reads up to 1000 characters from the byte stream for error diagnostics.
    private static func readErrorBody(from bytes: URLSession.AsyncBytes) async -> String {
        var body = ""
        do {
            for try await byte in bytes {
                body.append(Character(UnicodeScalar(byte)))
                if body.count > 1000 { break }
            }
        } catch {
            // Best-effort — partial body is fine for error messages.
        }
        return body
    }

}
#endif

