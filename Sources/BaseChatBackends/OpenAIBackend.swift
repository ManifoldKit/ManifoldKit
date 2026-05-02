#if CloudSaaS
import Foundation
import os
import BaseChatInference

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
        super.init(
            defaultModelName: "gpt-4o-mini",
            urlSession: urlSession ?? URLSessionProvider.pinned,
            payloadHandler: OpenAIPayloadHandler()
        )
    }

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

    public override var capabilities: BackendCapabilities {
        BackendCapabilities(
            supportedParameters: [.temperature, .topP],
            maxContextTokens: 128_000,
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
            // do not. ``GenerationCoordinator``'s pre-flight reads this flag
            // and rejects image attachments before we ever build a request,
            // so a non-vision model surfaces a clear local error rather than
            // a 400 from upstream.
            supportsVision: Self.isVisionCapableModel(modelName),
            streamsToolCallArguments: true,
            supportsParallelToolCalls: true
        )
    }

    /// Returns `true` when `modelName` belongs to an OpenAI family that
    /// accepts `image_url` content parts on the Chat Completions API.
    ///
    /// Two matcher styles are used together:
    ///
    /// - **Substring tokens** (`gpt-4o`, `gpt-4-turbo`, `gpt-4.1`) — long
    ///   enough to be unambiguous on their own, so a `contains` check
    ///   picks up dated-suffix variants (`gpt-4o-2024-08-06`) and vendor
    ///   aliases (`openai/gpt-4o`) automatically.
    /// - **Anchored prefixes** (`o1`, `o3`) — too short to be safe as a
    ///   substring (a name like `gpt-foo1bar` would accidentally match),
    ///   so we require the token at the start of the name or
    ///   immediately after a `/` or `:` separator (vendor namespaces like
    ///   `openai/o1-mini`), and the token must either end the string or
    ///   be followed by a `-`.
    ///
    /// Allowlist source: OpenAI's "Models with vision" docs as of 2026.
    /// Update ``OpenAIVisionModels`` when OpenAI ships a new family.
    static func isVisionCapableModel(_ modelName: String) -> Bool {
        let lowered = modelName.lowercased()
        if OpenAIVisionModels.substringTokens.contains(where: lowered.contains) {
            return true
        }
        for prefix in OpenAIVisionModels.anchoredPrefixes {
            if matchesAnchoredPrefix(lowered, prefix: prefix) {
                return true
            }
        }
        return false
    }

    /// Returns `true` when `prefix` appears at the start of `name` or
    /// immediately after a `/` or `:` separator, and is followed either by
    /// the end of the string or by a `-`. Used by ``isVisionCapableModel``
    /// for short tokens (`o1`, `o3`) where a bare substring match would
    /// produce false positives.
    static func matchesAnchoredPrefix(_ name: String, prefix: String) -> Bool {
        let chars = Array(name)
        let prefixChars = Array(prefix)
        guard prefixChars.count <= chars.count else { return false }
        // Walk every plausible start position: index 0 or right after a `/`/`:`.
        var startIndices: [Int] = [0]
        for (i, c) in chars.enumerated() where c == "/" || c == ":" {
            startIndices.append(i + 1)
        }
        for start in startIndices {
            guard start + prefixChars.count <= chars.count else { continue }
            if Array(chars[start..<start + prefixChars.count]) == prefixChars {
                let after = start + prefixChars.count
                if after == chars.count || chars[after] == "-" {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Structured History

    /// Structured replay history. Set by ``GenerationCoordinator`` when the
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
            // doesn't advertise vision support. ``GenerationCoordinator``
            // already gates this path on `capabilities.supportsVision`, but
            // the backend may be driven directly (e.g. the OpenAI-compat
            // server, or callers wiring their own pipeline), so keep the
            // belt-and-suspenders check here.
            if !Self.isVisionCapableModel(modelName) {
                throw InferenceError.inferenceFailure(
                    "Model \"\(modelName)\" does not support image input. Switch to a vision-capable OpenAI model (gpt-4o, gpt-4o-mini, gpt-4-turbo, gpt-4.1, o1, o3) and retry."
                )
            }
            messages.append(contentsOf: structured.map(Self.encodeChatCompletionsContent(for:)))
        } else if let history = conversationHistory {
            // Reasoning-model asymmetry: OpenAI-compatible providers (DeepSeek,
            // o-series, hosted Qwen reasoning) deliver chain-of-thought via
            // `reasoning_content` / `reasoning` deltas but **don't** require
            // it on multi-turn replay — and most providers reject blocks they
            // didn't emit. ``GenerationCoordinator`` already collapsed
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

        // Tool definitions — OpenAI accepts the canonical
        // `[{type:"function", function:{...}}]` envelope. `tool_choice` is
        // applied via the shared encoding helper so the same logic powers
        // ``OpenAIResponsesBackend``.
        if !config.tools.isEmpty {
            body["tools"] = config.tools.map(OpenAIToolEncoding.encodeToolDefinition)
            OpenAIToolEncoding.applyToolChoice(config.toolChoice, into: &body)
        }

        var request = URLRequest(url: completionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if config.streamPrefillProgress {
            request.setValue("true", forHTTPHeaderField: "X-BaseChat-Prefill-Progress")
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

    /// Parses OpenAI Chat Completions SSE with reasoning-model support.
    ///
    /// OpenAI-compatible reasoning models (o1/o3, DeepSeek R1, xAI Grok
    /// reasoning, hosted Qwen reasoning) expose chain-of-thought text alongside
    /// visible content via one of two Chat Completions delta shapes:
    ///
    /// ```json
    /// {"choices":[{"delta":{"reasoning_content":"..."}}]}   // DeepSeek / compat
    /// {"choices":[{"delta":{"reasoning":"..."}}]}           // OpenAI-native
    /// ```
    ///
    /// We route reasoning fragments to ``GenerationEvent/thinkingToken(_:)``
    /// and emit a single ``GenerationEvent/thinkingComplete`` on the first
    /// transition from reasoning to visible `content` (or on stream end if
    /// reasoning never handed off to content — truncated upstream). Streams
    /// from non-reasoning models (plain gpt-4o-mini, etc.) never observe a
    /// reasoning chunk and therefore never fire `.thinkingComplete`.
    public override func parseResponseStream(
        bytes: URLSession.AsyncBytes,
        config: GenerationConfig,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        let tokenStream = SSEStreamParser.parse(bytes: bytes, limits: effectiveSSEStreamLimits)

        var thinking = ThinkingBlockManager()
        let toolAccumulator = StreamingToolCallAccumulator()
        // Tracks whether we've finalised tool calls already (for non-streaming
        // whole responses delivered as a single chunk, where `finish_reason`
        // and the final `tool_calls[]` arrive in the same payload).
        var finalisedToolCalls = false

        func finaliseToolCalls() {
            guard !finalisedToolCalls else { return }
            finalisedToolCalls = true
            for entry in toolAccumulator.finalizedEntries() {
                continuation.yield(.toolCall(ToolCall(
                    id: entry.callId,
                    toolName: entry.name,
                    arguments: entry.arguments
                )))
            }
        }

        do {
            for try await payload in tokenStream {
                if Task.isCancelled { break }

                if let progress = Self.parsePrefillProgress(from: payload) {
                    continuation.yield(.prefillProgress(
                        nPast: progress.nPast,
                        nTotal: progress.nTotal,
                        tokensPerSecond: progress.tokensPerSecond
                    ))
                    continue
                }

                // Reasoning delta: emit as thinkingToken, keep the block open.
                if let reasoning = Self.parseReasoningDelta(from: payload) {
                    continuation.yield(.thinkingToken(reasoning))
                    thinking.open()
                    // Fall through — a single chunk may legally carry both
                    // reasoning and content (edge case on some providers), and
                    // usage may still need emitting.
                }

                // Visible content delta: close thinking first so consumers see a
                // clean handoff before the first visible token.
                if let token = extractToken(from: payload) {
                    thinking.flushIfOpen(into: continuation)
                    continuation.yield(.token(token))
                }

                // Tool-call deltas (streaming) — keyed by `index`. The first delta
                // for each `index` carries `id` + `function.name`; subsequent
                // deltas carry `function.arguments` fragments. Some compat servers
                // do not re-emit `id` on later deltas, so we sticky-buffer it.
                let toolDeltas = Self.parseToolCallDeltas(from: payload)
                for delta in toolDeltas {
                    let key = "\(delta.index)"
                    let isNew = toolAccumulator.upsert(
                        key: key,
                        id: delta.id,
                        name: delta.name,
                        argumentsDelta: delta.argumentsDelta
                    )
                    if isNew {
                        thinking.flushIfOpen(into: continuation)
                    }
                    // Emit `.toolCallStart` once we have both an id and a name.
                    if let entry = toolAccumulator.entriesByKey[key],
                       !entry.started, !entry.name.isEmpty {
                        let resolvedId = toolAccumulator.resolvedId(forKey: key)
                        continuation.yield(.toolCallStart(callId: resolvedId, name: entry.name))
                        toolAccumulator.markStarted(key: key)
                    }
                    // Stream argument fragments under the resolved (sticky) id.
                    if let fragment = delta.argumentsDelta, !fragment.isEmpty {
                        let resolvedId = toolAccumulator.resolvedId(forKey: key)
                        continuation.yield(.toolCallArgumentsDelta(callId: resolvedId, textDelta: fragment))
                    }
                }

                // Non-streaming whole-message tool_calls (`message.tool_calls[]`).
                if !finalisedToolCalls {
                    let wholeCalls = Self.parseWholeToolCalls(from: payload)
                    if !wholeCalls.isEmpty {
                        thinking.flushIfOpen(into: continuation)
                        for call in wholeCalls {
                            let key = call.id.isEmpty ? UUID().uuidString : call.id
                            toolAccumulator.upsert(
                                key: key,
                                id: call.id,
                                name: call.name,
                                argumentsDelta: call.arguments
                            )
                            let resolvedId = toolAccumulator.resolvedId(forKey: key)
                            continuation.yield(.toolCallStart(callId: resolvedId, name: call.name))
                            toolAccumulator.markStarted(key: key)
                            if !call.arguments.isEmpty {
                                continuation.yield(.toolCallArgumentsDelta(
                                    callId: resolvedId,
                                    textDelta: call.arguments
                                ))
                            }
                        }
                    }
                }

                if let usage = extractUsage(from: payload) {
                    handleUsage(usage)
                    if let prompt = usage.promptTokens,
                       let completion = usage.completionTokens {
                        continuation.yield(.usage(prompt: prompt, completion: completion))
                    }
                }

                // `finish_reason: "tool_calls"` finalises any buffered streaming
                // tool calls. When the assistant turn ends with `stop` we still
                // flush any accumulated tool calls so callers in the non-stream
                // path see a uniform shape.
                if let reason = Self.parseFinishReason(from: payload) {
                    if reason == "tool_calls" || !toolAccumulator.entriesByKey.isEmpty {
                        finaliseToolCalls()
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
            // see a clean handoff and don't hang in a thinking-only state.
            thinking.flushIfOpen(into: continuation)
            throw error
        }

        thinking.flushIfOpen(into: continuation)
        // Stream end fallback: if the upstream closed without a `finish_reason`
        // (some compat servers omit it), emit any buffered tool calls now so
        // the orchestrator can dispatch them. On cancellation we deliberately
        // skip this — dropping the consumer mid-stream must not produce
        // phantom `.toolCall` events.
        if !Task.isCancelled {
            finaliseToolCalls()
        }
    }

    // MARK: - Structured Content Encoding

    /// Encodes one ``StructuredMessage`` as a Chat Completions
    /// `messages[]` entry.
    ///
    /// - Text-only turns collapse to a plain string `content` to keep the
    ///   wire shape minimal — every existing OpenAI-compatible compat
    ///   server (Ollama, LM Studio, etc.) accepts both shapes and the
    ///   string form is the lower-friction default.
    /// - Image-bearing turns emit a structured `content[]` array with one
    ///   `text` part (when present) followed by `image_url` parts for each
    ///   image. The text-first ordering matches OpenAI's vision examples in
    ///   the docs and keeps the prompt visible at the top of the array.
    /// - Non-`user` roles (assistant, system, tool) collapse to plain
    ///   string content. The model never emits `image_url` parts on
    ///   assistant turns, and the persisted-row case where an assistant row
    ///   somehow carries an image is rare enough that dropping the image
    ///   silently — rather than emitting an `image_url` part the API will
    ///   reject — is the safer choice.
    static func encodeChatCompletionsContent(for message: StructuredMessage) -> [String: Any] {
        let hasImage = message.parts.contains { part in
            if case .image = part { return true }
            return false
        }
        guard message.role == "user", hasImage else {
            return ["role": message.role, "content": message.textContent]
        }

        var contentParts: [[String: Any]] = []
        let text = message.textContent
        if !text.isEmpty {
            contentParts.append(["type": "text", "text": text])
        }
        for part in message.parts {
            if case .image(let data, let mimeType) = part {
                contentParts.append([
                    "type": "image_url",
                    "image_url": [
                        "url": CloudImageEncoding.dataURI(data: data, mimeType: mimeType),
                    ] as [String: Any],
                ])
            }
        }
        return ["role": "user", "content": contentParts]
    }

    // MARK: - SSE Payload Handler

    /// OpenAI-specific SSE payload interpreter for use with `SSEStreamParser.streamTokens`.
    static let payloadHandler = OpenAIPayloadHandler()

    struct OpenAIPayloadHandler: SSEPayloadHandler {
        func extractToken(from payload: String) -> String? {
            OpenAIBackend.parseToken(from: payload)
        }
        func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
            guard let usage = OpenAIBackend.parseUsage(from: payload) else { return nil }
            return (promptTokens: usage.promptTokens, completionTokens: usage.completionTokens)
        }
        func isStreamEnd(_ payload: String) -> Bool { false }
        func extractStreamError(from payload: String) -> Error? { nil }
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

/// Allowlist of OpenAI model-name family tokens that accept `image_url`
/// content parts on the Chat Completions API.
///
/// Lives next to ``OpenAIBackend`` so the matcher stays a one-line
/// substring check. Adding a new token here is the single edit required
/// when OpenAI ships a new vision-capable family — the dated-suffix
/// variants (e.g. `gpt-4o-2024-08-06`) and vendor aliases (e.g.
/// `openai/gpt-4o`) match automatically because the classifier uses
/// substring containment.
///
/// Kept here (rather than as a public type) because it is an
/// implementation detail of one backend's capability gating; promoting it
/// would invite host apps to take a dependency on a list that needs to
/// move whenever OpenAI updates their model lineup.
enum OpenAIVisionModels {
    /// Tokens long enough to be safe as substring matches. A name like
    /// `gpt-4o-2024-08-06` or `openai/gpt-4o-mini` lights these up.
    /// Tokens are lowercase; the classifier lowercases its input first.
    static let substringTokens: [String] = [
        "gpt-4o",       // gpt-4o, gpt-4o-mini, gpt-4o-2024-* — full vision family
        "gpt-4-turbo",  // gpt-4-turbo, gpt-4-turbo-2024-* — original vision turbo
        "gpt-4.1",      // gpt-4.1 family — vision-capable per the 2025 refresh
    ]

    /// Tokens that are too short for a bare `contains` check (a name like
    /// `gpt-foo1bar` would otherwise accidentally match `o1`). Matched via
    /// ``OpenAIBackend/matchesAnchoredPrefix(_:prefix:)`` which requires
    /// the token at a name boundary (start or after `/` / `:`) and either
    /// ending the string or followed by a `-`.
    static let anchoredPrefixes: [String] = [
        "o1",           // o1, o1-preview, o1-mini-* — reasoning family with vision
        "o3",           // o3, o3-mini-* — newer reasoning family with vision
    ]
}
#endif
