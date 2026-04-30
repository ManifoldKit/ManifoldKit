#if CloudSaaS
import Foundation
import os
import BaseChatInference

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

    public override var capabilities: BackendCapabilities {
        BackendCapabilities(
            supportedParameters: [.temperature, .topP],
            maxContextTokens: 200_000,
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
            streamsToolCallArguments: true,
            supportsParallelToolCalls: true
        )
    }

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
        //      for multi-turn extended-thinking replay (#604).
        //   3. plain (role, content) history — legacy fallback.
        //   4. prompt-only single user turn.
        let chatMessages: [[String: Any]]
        if let toolHistory = snapshotToolHistory, !toolHistory.isEmpty {
            chatMessages = toolHistory.map(Self.encodeToolAwareEntry)
        } else if let structured = structuredHistory, !structured.isEmpty {
            chatMessages = structured.map(Self.encodeMessageContent(for:))
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

        if let systemPrompt, !systemPrompt.isEmpty {
            body["system"] = systemPrompt
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
            body["tools"] = config.tools.map(Self.encodeToolDefinition)
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

    // MARK: - Structured Content Encoding

    /// Encodes one ``StructuredMessage`` as an Anthropic Messages API
    /// `messages[]` entry.
    ///
    /// - User turns collapse to a plain string `content` for simplicity —
    ///   Anthropic accepts either a string or a structured array on user
    ///   role.
    /// - Assistant turns serialize to a structured `content` array. Thinking
    ///   blocks are emitted **before** any text block, with their
    ///   ``MessagePart/thinkingSignature`` carried verbatim. Anthropic's
    ///   multi-turn extended-thinking contract requires the signature to
    ///   match what the model emitted on the previous turn, so any
    ///   thinking block missing a signature is dropped rather than sent
    ///   with a blank one (which would 400).
    /// - System / tool turns fall back to plain string content.
    static func encodeMessageContent(for message: StructuredMessage) -> [String: Any] {
        if message.role == "assistant" {
            var blocks: [[String: Any]] = []

            // Thinking blocks first — Anthropic requires thinking content to
            // precede any text/tool_use within the same assistant turn.
            for part in message.parts {
                if case .thinking(let text, let signature) = part {
                    // Signature-less thinking blocks (legacy persisted rows
                    // that pre-date #604, or local backends like MLX/Llama
                    // where Anthropic never issued one) are dropped from the
                    // replay payload. Sending them blank would fail the
                    // server-side signature check and 400 the request.
                    guard let signature else { continue }
                    blocks.append([
                        "type": "thinking",
                        "thinking": text,
                        "signature": signature
                    ])
                }
            }

            // Then text. Concatenated into a single block to match how the
            // model originally emitted its visible content.
            let visible = message.textContent
            if !visible.isEmpty {
                blocks.append([
                    "type": "text",
                    "text": visible
                ])
            }

            // An assistant turn with neither thinking nor text would 400.
            // Emit a single empty text block in that pathological case so
            // the wire shape is still valid and the server returns a normal
            // error rather than a stream-level parse failure.
            if blocks.isEmpty {
                return ["role": "assistant", "content": ""]
            }
            return ["role": "assistant", "content": blocks]
        }

        // User and other roles: collapse to plain text.
        return ["role": message.role, "content": message.textContent]
    }

    // MARK: - Tool Encoding

    /// Encodes a ``ToolDefinition`` into Anthropic's `tools[]` envelope:
    /// `{name, description, input_schema}`. `input_schema` is the same
    /// JSON Schema graph the rest of BCK uses; we round-trip it through
    /// `JSONSerialization` via the shared
    /// ``OpenAIToolEncoding/foundationJSON(from:)`` helper so the
    /// resulting body is JSONSerialization-compatible.
    static func encodeToolDefinition(_ tool: ToolDefinition) -> [String: Any] {
        var entry: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
        ]
        if let schema = encodeJSONSchemaToFoundation(tool.parameters) {
            entry["input_schema"] = schema
        } else {
            entry["input_schema"] = ["type": "object", "properties": [String: Any]()]
        }
        return entry
    }

    /// Encodes one ``ToolAwareHistoryEntry`` for the Anthropic Messages
    /// API `messages[]` array.
    ///
    /// Anthropic represents both tool calls and tool results as content
    /// blocks rather than message roles:
    ///
    /// - Assistant turns that requested tools serialise as
    ///   `{role:"assistant", content:[{type:"text",...}, {type:"tool_use",
    ///   id, name, input}, ...]}`. Visible text (if any) precedes the
    ///   tool_use blocks; an empty assistant turn collapses to a single
    ///   tool_use block with no preamble.
    /// - Tool-role turns (the orchestrator's tool-result feedback) collapse
    ///   to a `user` role message carrying a `tool_result` content block:
    ///   `{role:"user", content:[{type:"tool_result", tool_use_id, content}]}`.
    /// - Plain text turns fall back to the simple `{role, content}` shape.
    static func encodeToolAwareEntry(_ entry: ToolAwareHistoryEntry) -> [String: Any] {
        // Tool-result feedback → user-role tool_result block.
        if entry.role == "tool", let callId = entry.toolCallId {
            return [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": callId,
                        "content": entry.content,
                    ] as [String: Any]
                ],
            ]
        }

        // Assistant turn carrying tool_use blocks.
        if entry.role == "assistant", let calls = entry.toolCalls, !calls.isEmpty {
            var blocks: [[String: Any]] = []
            if !entry.content.isEmpty {
                blocks.append([
                    "type": "text",
                    "text": entry.content,
                ])
            }
            for call in calls {
                let inputObj = decodeArgumentsForReplay(call.arguments)
                blocks.append([
                    "type": "tool_use",
                    "id": call.id,
                    "name": call.toolName,
                    "input": inputObj,
                ])
            }
            return ["role": "assistant", "content": blocks]
        }

        // Plain message turn (user / system / assistant-text-only).
        return ["role": entry.role, "content": entry.content]
    }

    /// Decodes a stored arguments-JSON string for replay inside a
    /// `tool_use` content block. The Anthropic wire contract requires
    /// `input` to be a JSON object (not a stringified blob), unlike
    /// OpenAI Chat Completions where `arguments` is a string.
    ///
    /// On parse failure — or if the parsed value is not a JSON object
    /// (e.g. an array, string, or number snuck into the stored
    /// arguments) — we fall back to an empty object so we never send a
    /// `tool_use.input` shape Anthropic will 400 on. Mirrors the MLX
    /// replay fallback for corrupted tool-call history.
    private static func decodeArgumentsForReplay(_ arguments: String) -> [String: Any] {
        guard let data = arguments.data(using: .utf8) else {
            return [:]
        }
        do {
            let decoded = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            if let object = decoded as? [String: Any] {
                return object
            }
            Log.inference.warning(
                "ClaudeBackend: tool_use input parsed but is not a JSON object — substituting empty object to satisfy Anthropic schema."
            )
            return [:]
        } catch {
            Log.inference.warning(
                "ClaudeBackend: tool_use input could not be re-parsed for replay — substituting empty object. error=\(error.localizedDescription, privacy: .public)"
            )
            return [:]
        }
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

        // Tool-use content blocks are keyed by `index` (the integer
        // content-block index Anthropic assigns within an assistant turn).
        // The accumulator stores entries keyed by the stringified index;
        // the public call id lives in `entry.id` so downstream events
        // expose the call id, not the index.
        let toolAccumulator = StreamingToolCallAccumulator()
        // Tracks indexes whose `content_block_start` declared `type:"tool_use"`
        // so we can route subsequent `content_block_delta` / `content_block_stop`
        // events to the accumulator — Anthropic interleaves tool_use blocks
        // with text/thinking blocks in the same numbering space.
        var toolUseIndexes: Set<Int> = []
        // Tracks indexes for which we've emitted at least one
        // `.toolCallArgumentsDelta`. `content_block_stop` falls back to a
        // synthetic `"{}"` delta when the index never received any
        // `input_json_delta`.
        var toolUseEmittedDelta: Set<Int> = []
        // Tracks indexes already finalized via `content_block_stop` so we
        // don't double-emit `.toolCall` from the message_stop fallback.
        var toolUseFinalized: Set<Int> = []
        // Whether to skip finalising any pending tool blocks at stream end
        // (cancellation contract: dropped consumers must not see phantom
        // `.toolCall` events for incomplete blocks).
        var cancelled = false

        // Finalize one tool_use block. Emits a synthetic empty-input delta
        // when no `input_json_delta` was ever observed so the event surface
        // (start → ≥1 delta → toolCall) stays uniform with OpenAI's shape.
        func finalizeToolUse(at index: Int) {
            guard toolUseIndexes.contains(index), !toolUseFinalized.contains(index) else { return }
            let key = "\(index)"
            guard let entry = toolAccumulator.entriesByKey[key], !entry.name.isEmpty else { return }
            let resolvedId = !entry.id.isEmpty ? entry.id : "claude-call-\(key)"
            if !toolUseEmittedDelta.contains(index) {
                continuation.yield(.toolCallArgumentsDelta(callId: resolvedId, textDelta: "{}"))
                toolUseEmittedDelta.insert(index)
            }
            let args = entry.arguments.isEmpty ? "{}" : entry.arguments
            continuation.yield(.toolCall(ToolCall(
                id: resolvedId,
                toolName: entry.name,
                arguments: args
            )))
            toolUseFinalized.insert(index)
        }

        // Finalize all pending tool_use blocks in `index` order. Used by
        // both `message_stop` and end-of-stream fallback so callers always
        // see `.toolCall` events emitted in the order the model produced
        // the underlying content blocks.
        func finalizePendingToolUses() {
            guard !cancelled else { return }
            for idx in toolUseIndexes.sorted() {
                finalizeToolUse(at: idx)
            }
        }

        do {
            for try await payload in tokenStream {
                if Task.isCancelled {
                    cancelled = true
                    break
                }

                let eventType = Self.parseEventType(from: payload)

                // Thinking-block start: opportunistically capture the signature
                // if Anthropic shipped one inline on the start event. Real
                // streams more commonly carry the signature on a later
                // `signature_delta`, but a couple of beta endpoints attach it
                // here, and the redundant emission is harmless — UI consumers
                // overwrite stored signatures rather than appending.
                if eventType == "content_block_start", let signature = Self.parseThinkingBlockStartSignature(from: payload) {
                    continuation.yield(.thinkingSignature(signature))
                    continue
                }

                // tool_use content_block_start — capture id + name and emit
                // `.toolCallStart`. Anthropic always carries id and name on
                // the start event itself, so we don't need the accumulator's
                // lazy-emit pattern.
                if eventType == "content_block_start", let toolStart = Self.parseToolUseBlockStart(from: payload) {
                    thinking.flushIfOpen(into: continuation)
                    let key = "\(toolStart.index)"
                    toolAccumulator.upsert(
                        key: key,
                        id: toolStart.id,
                        name: toolStart.name,
                        argumentsDelta: nil
                    )
                    toolUseIndexes.insert(toolStart.index)
                    continuation.yield(.toolCallStart(callId: toolStart.id, name: toolStart.name))
                    toolAccumulator.markStarted(key: key)
                    continue
                }

                // input_json_delta — append to the accumulator and emit a
                // streaming `.toolCallArgumentsDelta` under the resolved call id.
                if eventType == "content_block_delta", let inputDelta = Self.parseInputJSONDelta(from: payload) {
                    let key = "\(inputDelta.index)"
                    toolAccumulator.upsert(
                        key: key,
                        id: nil,
                        name: nil,
                        argumentsDelta: inputDelta.partialJSON
                    )
                    let resolvedId = toolAccumulator.resolvedId(forKey: key)
                    if !inputDelta.partialJSON.isEmpty {
                        continuation.yield(.toolCallArgumentsDelta(
                            callId: resolvedId,
                            textDelta: inputDelta.partialJSON
                        ))
                        toolUseEmittedDelta.insert(inputDelta.index)
                    }
                    continue
                }

                // content_block_stop on a tool_use index — finalize that one
                // call now so per-block latency is preserved. (Sibling text /
                // thinking blocks pass through this branch as a no-op.)
                if eventType == "content_block_stop", let stopIndex = Self.parseContentBlockIndex(from: payload),
                   toolUseIndexes.contains(stopIndex) {
                    finalizeToolUse(at: stopIndex)
                    continue
                }

                // Signature delta inside the thinking block. Primary path
                // Anthropic uses today for extended-thinking signatures.
                if eventType == "content_block_delta", let signature = Self.parseSignatureDelta(from: payload) {
                    continuation.yield(.thinkingSignature(signature))
                    continue
                }

                // Thinking delta: emit as thinkingToken, keep the block open.
                if eventType == "content_block_delta", let thinkingDelta = Self.parseThinkingDelta(from: payload) {
                    continuation.yield(.thinkingToken(thinkingDelta))
                    thinking.open()
                    continue
                }

                // Plain text delta: close any open thinking block first, then yield.
                if let token = extractToken(from: payload) {
                    thinking.flushIfOpen(into: continuation)
                    continuation.yield(.token(token))
                }

                // Non-streaming whole-message tool_use shape. Some callers
                // (synthesised replay fixtures, future non-streaming endpoint
                // variants) deliver the entire `content:[]` array on a single
                // payload. Treat each tool_use block as a uniform start +
                // single delta + toolCall triple so consumers don't have to
                // special-case the path.
                if let wholeCalls = Self.parseWholeMessageToolUseBlocks(from: payload), !wholeCalls.isEmpty {
                    thinking.flushIfOpen(into: continuation)
                    for call in wholeCalls {
                        let key = "whole-\(call.id.isEmpty ? UUID().uuidString : call.id)"
                        toolAccumulator.upsert(
                            key: key,
                            id: call.id,
                            name: call.name,
                            argumentsDelta: call.serializedInput
                        )
                        let resolvedId = toolAccumulator.resolvedId(forKey: key)
                        continuation.yield(.toolCallStart(callId: resolvedId, name: call.name))
                        toolAccumulator.markStarted(key: key)
                        continuation.yield(.toolCallArgumentsDelta(
                            callId: resolvedId,
                            textDelta: call.serializedInput
                        ))
                        continuation.yield(.toolCall(ToolCall(
                            id: resolvedId,
                            toolName: call.name,
                            arguments: call.serializedInput
                        )))
                    }
                    continue
                }

                if let usage = extractUsage(from: payload) {
                    handleUsage(usage)
                    if let prompt = usage.promptTokens,
                       let completion = usage.completionTokens {
                        continuation.yield(.usage(prompt: prompt, completion: completion))
                    }
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
            cancelled = true
        }

        // Safety net: stream ended without a text block or message_stop while
        // still inside a thinking block (truncated upstream). Close the block
        // so consumers don't hang in a thinking-only state.
        thinking.flushIfOpen(into: continuation)
        // Stream end fallback: if the upstream closed without `message_stop`
        // (truncated, server hangup), emit any buffered tool calls now so
        // the orchestrator can still dispatch them. Cancellation suppresses
        // this branch — see `cancelled`.
        finalizePendingToolUses()
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

    // MARK: - SSE Payload Handler

    /// Claude-specific SSE payload interpreter for use with `SSEStreamParser.streamTokens`.
    static let payloadHandler = ClaudePayloadHandler()

    struct ClaudePayloadHandler: SSEPayloadHandler {
        func extractToken(from payload: String) -> String? {
            ClaudeBackend.parseToken(from: payload)
        }
        func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
            ClaudeBackend.parseUsage(from: payload)
        }
        func isStreamEnd(_ payload: String) -> Bool {
            ClaudeBackend.parseIsStreamEnd(payload)
        }
        func extractStreamError(from payload: String) -> Error? {
            ClaudeBackend.parseStreamError(from: payload)
        }
    }

    // MARK: - JSON Parsing

    /// Returns the `type` field of an Anthropic SSE event payload, if any.
    static func parseEventType(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parsed["type"] as? String
    }

    // MARK: - Tool-call parsing

    /// Decoded shape of a `content_block_start` event whose
    /// `content_block.type == "tool_use"`.
    struct ToolUseBlockStart {
        let index: Int
        let id: String
        let name: String
    }

    /// Decoded shape of a `content_block_delta` event whose
    /// `delta.type == "input_json_delta"`.
    struct InputJSONDelta {
        let index: Int
        let partialJSON: String
    }

    /// Decoded shape of one whole `tool_use` block delivered inside a
    /// non-streaming-style `message.content[]` payload.
    struct WholeToolUseBlock {
        let id: String
        let name: String
        /// The block's `input` object re-serialised back into a stable
        /// JSON string. Stored as the canonical arguments value so the
        /// streaming and non-streaming paths produce a uniform
        /// `.toolCallArgumentsDelta` / `.toolCall` shape.
        let serializedInput: String
    }

    /// Extracts a tool_use block-start payload, if the event carries one.
    ///
    /// Shape: `{type:"content_block_start", index:N, content_block:{type:"tool_use", id, name, input}}`.
    /// `input` is conventionally an empty object `{}` on the start event;
    /// the actual arguments stream in via `input_json_delta` events.
    static func parseToolUseBlockStart(from json: String) -> ToolUseBlockStart? {
        guard let data = json.data(using: .utf8) else { return nil }
        let parsed: [String: Any]?
        do {
            parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            // Malformed JSON on a probe is a non-event — skip the payload
            // and let the next valid one drive state. Same shape as the
            // Chat Completions handlers; covered by silent-catch allowlist.
            return nil
        }
        guard let parsed,
              parsed["type"] as? String == "content_block_start",
              let index = parsed["index"] as? Int,
              let block = parsed["content_block"] as? [String: Any],
              block["type"] as? String == "tool_use",
              let id = block["id"] as? String, !id.isEmpty,
              let name = block["name"] as? String, !name.isEmpty else {
            return nil
        }
        return ToolUseBlockStart(index: index, id: id, name: name)
    }

    /// Extracts an `input_json_delta` payload, if the event carries one.
    ///
    /// Shape: `{type:"content_block_delta", index:N, delta:{type:"input_json_delta", partial_json:"..."}}`.
    static func parseInputJSONDelta(from json: String) -> InputJSONDelta? {
        guard let data = json.data(using: .utf8) else { return nil }
        let parsed: [String: Any]?
        do {
            parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
        guard let parsed,
              parsed["type"] as? String == "content_block_delta",
              let index = parsed["index"] as? Int,
              let delta = parsed["delta"] as? [String: Any],
              delta["type"] as? String == "input_json_delta",
              let partial = delta["partial_json"] as? String else {
            return nil
        }
        return InputJSONDelta(index: index, partialJSON: partial)
    }

    /// Extracts the `index` field from a `content_block_*` payload (used
    /// to route `content_block_stop` events to the right tool_use index).
    static func parseContentBlockIndex(from json: String) -> Int? {
        guard let data = json.data(using: .utf8) else { return nil }
        let parsed: [String: Any]?
        do {
            parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
        return parsed?["index"] as? Int
    }

    /// Extracts a non-streaming-style `content:[{type:"tool_use",...}, ...]`
    /// array from a single-shot payload, when present. Returns `nil` if
    /// the payload is not a whole-message envelope, or an empty array if
    /// the envelope contains no tool_use blocks.
    ///
    /// Shape:
    /// ```json
    /// {"type":"message", "content":[
    ///   {"type":"tool_use", "id":"...", "name":"...", "input":{...}},
    ///   ...
    /// ]}
    /// ```
    static func parseWholeMessageToolUseBlocks(from json: String) -> [WholeToolUseBlock]? {
        guard let data = json.data(using: .utf8) else { return nil }
        let parsed: [String: Any]?
        do {
            parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
        guard let parsed else { return nil }
        // Only treat top-level `{type:"message", content:[...]}` envelopes
        // as whole-message payloads. The streaming events
        // `content_block_*`, `message_delta`, `message_stop`, `error`
        // never carry a top-level `content` array, so this guard prevents
        // accidental double-emission against streaming chunks.
        guard parsed["type"] as? String == "message",
              let content = parsed["content"] as? [[String: Any]] else {
            return nil
        }
        var result: [WholeToolUseBlock] = []
        for block in content {
            guard block["type"] as? String == "tool_use",
                  let id = block["id"] as? String, !id.isEmpty,
                  let name = block["name"] as? String, !name.isEmpty else {
                continue
            }
            let input = block["input"] ?? [String: Any]()
            let serialized = serializeInputObject(input)
            result.append(WholeToolUseBlock(id: id, name: name, serializedInput: serialized))
        }
        return result
    }

    /// Re-serialises a `tool_use.input` value back to a JSON string for
    /// the canonical `ToolCall.arguments` storage. Falls back to `"{}"`
    /// for anything that fails to re-encode — same conservative empty
    /// default the OpenAI helpers use.
    private static func serializeInputObject(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value) else {
            return "{}"
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [])
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            Log.inference.warning(
                "ClaudeBackend: tool_use.input could not be re-serialised — falling back to empty object. error=\(error.localizedDescription, privacy: .public)"
            )
            return "{}"
        }
    }

    /// Extracts the `.signature` field from a thinking-block
    /// `content_block_start` payload, when present.
    ///
    /// Shape: `{type:"content_block_start", content_block:{type:"thinking", signature:"..."}}`.
    /// Returns `nil` for non-thinking blocks or starts that don't carry a
    /// signature.
    static func parseThinkingBlockStartSignature(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              parsed["type"] as? String == "content_block_start",
              let block = parsed["content_block"] as? [String: Any],
              block["type"] as? String == "thinking",
              let signature = block["signature"] as? String,
              !signature.isEmpty else {
            return nil
        }
        return signature
    }

    /// Extracts the `.signature` from a `signature_delta` event nested
    /// inside a `content_block_delta`. Anthropic emits the extended-thinking
    /// signature via this path on most production responses.
    ///
    /// Shape: `{type:"content_block_delta", delta:{type:"signature_delta", signature:"..."}}`.
    static func parseSignatureDelta(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              parsed["type"] as? String == "content_block_delta",
              let delta = parsed["delta"] as? [String: Any],
              delta["type"] as? String == "signature_delta",
              let signature = delta["signature"] as? String,
              !signature.isEmpty else {
            return nil
        }
        return signature
    }

    /// Extracts the `.thinking` text from a `thinking_delta` content-block delta.
    ///
    /// Anthropic extended-thinking responses carry reasoning as a separate
    /// content-block type. The delta shape is
    /// `{type:"content_block_delta", delta:{type:"thinking_delta", thinking:"..."}}`.
    static func parseThinkingDelta(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              parsed["type"] as? String == "content_block_delta",
              let delta = parsed["delta"] as? [String: Any],
              delta["type"] as? String == "thinking_delta",
              let thinking = delta["thinking"] as? String else {
            return nil
        }
        return thinking
    }

    /// Extracts a text token from a `content_block_delta` event payload.
    static func parseToken(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              parsed["type"] as? String == "content_block_delta",
              let delta = parsed["delta"] as? [String: Any],
              let text = delta["text"] as? String else {
            return nil
        }
        return text
    }

    /// Returns `true` if the SSE payload signals end of stream.
    private static func parseIsStreamEnd(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = parsed["type"] as? String else {
            return false
        }
        return type == "message_stop"
    }

    /// Extracts token usage from Claude SSE event payloads.
    ///
    /// `message_start` contains `input_tokens`, `message_delta` contains `output_tokens`.
    private static func parseUsage(from json: String) -> (promptTokens: Int?, completionTokens: Int?)? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = parsed["type"] as? String else {
            return nil
        }

        switch type {
        case "message_start":
            guard let message = parsed["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let inputTokens = usage["input_tokens"] as? Int else {
                return nil
            }
            return (promptTokens: inputTokens, completionTokens: nil)

        case "message_delta":
            guard let usage = parsed["usage"] as? [String: Any],
                  let outputTokens = usage["output_tokens"] as? Int else {
                return nil
            }
            return (promptTokens: nil, completionTokens: outputTokens)

        default:
            return nil
        }
    }

    /// Extracts an error from an SSE `error` event payload.
    private static func parseStreamError(from json: String) -> CloudBackendError? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              parsed["type"] as? String == "error",
              let error = parsed["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return .parseError(message)
    }
}
#endif

