#if CloudSaaS
import Foundation
import os
import ManifoldInference
import ManifoldCloudCore

/// Cloud inference backend targeting OpenAI's Responses API
/// (`POST /v1/responses`).
///
/// Unlike ``OpenAIBackend`` (Chat Completions), the Responses API is a
/// named-event SSE stream that exposes reasoning summaries as first-class
/// events:
///
/// ```
/// event: response.output_item.added
/// data: {"type":"response.output_item.added","item":{"type":"reasoning"}}
///
/// event: response.reasoning_summary_text.delta
/// data: {"delta":"Let me think..."}
///
/// event: response.reasoning_summary_text.done
/// data: {}
///
/// event: response.output_text.delta
/// data: {"delta":"The answer is 42."}
///
/// event: response.completed
/// data: {"response":{"usage":{"input_tokens":12,"output_tokens":8}}}
/// ```
///
/// Reasoning summaries surface as ``GenerationEvent/thinkingToken(_:)``
/// values, with a single ``GenerationEvent/thinkingComplete`` injected on
/// the transition to visible output. This routing mirrors the convention
/// used by ``ClaudeBackend`` and ``OpenAIBackend`` so consumers can stay
/// agnostic of the wire format.
///
/// Usage:
/// ```swift
/// let backend = OpenAIResponsesBackend()
/// backend.configure(
///     baseURL: URL(string: "https://api.openai.com")!,
///     apiKey: "sk-...",
///     modelName: "gpt-5"
/// )
/// try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
/// let stream = try backend.generate(prompt: "Hello", systemPrompt: nil, config: .init())
/// for try await event in stream.events {
///     switch event {
///     case .thinkingToken(let t): print("[reasoning]", t)
///     case .token(let t): print(t, terminator: "")
///     default: break
///     }
/// }
/// ```
public final class OpenAIResponsesBackend: SSECloudBackend, TokenUsageProvider, CloudBackendURLModelConfigurable, CloudBackendKeychainConfigurable, ToolCallingHistoryReceiver, @unchecked Sendable {

    // MARK: - Init

    /// Creates an OpenAI Responses-API backend.
    ///
    /// - Parameter urlSession: Custom URLSession. Pass `nil` to use the
    ///   default pinned session.
    public init(urlSession: URLSession? = nil) {
        super.init(
            defaultModelName: "gpt-5",
            urlSession: urlSession ?? URLSessionProvider.pinned,
            // The payload handler classifies `data:` payloads for the named-
            // event SSE stream. This backend overrides `parseResponseStream`
            // to dispatch on `event:` names, but routes the per-payload
            // reasoning / text classification through the handler so the
            // mapping lives in one place — see `OpenAIResponsesPayloadHandler`.
            payloadHandler: OpenAIResponsesPayloadHandler()
        )
    }

    /// Throwing factory that propagates ``URLSessionProvider/networkDisabled``
    /// as ``CloudBackendError/networkDisabled`` instead of trapping.
    public static func makeChecked(urlSession: URLSession? = nil) throws -> OpenAIResponsesBackend {
        let session: URLSession
        if let urlSession {
            session = urlSession
        } else {
            session = try URLSessionProvider.throwingPinned()
        }
        return OpenAIResponsesBackend(urlSession: session)
    }

    // MARK: - Subclass Hooks

    public override var backendName: String { "OpenAIResponses" }

    public override var capabilities: BackendCapabilities {
        BackendCapabilities(
            supportedParameters: [.temperature, .topP],
            maxContextTokens: 200_000,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            // Responses API tool calling: function-call arguments stream via
            // `response.function_call_arguments.delta` (keyed by `item_id`)
            // after a `response.output_item.added` event for the matching
            // function_call item. The backend bridges item_id → call_id so
            // consumers see consistent `.toolCallStart` →
            // N×`.toolCallArgumentsDelta` → `.toolCall` sequences regardless
            // of which OpenAI surface produced them.
            supportsToolCalling: true,
            supportsStructuredOutput: true,
            supportsNativeJSONMode: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false,
            memoryStrategy: .external,
            maxOutputTokens: 16_384,
            supportsStreaming: true,
            isRemote: true,
            supportsThinking: true,
            // Responses API image input stays disabled until this backend encodes
            // MessagePart.image as input_image content items.
            supportsVision: BackendVisionCapability.openAIResponsesSupportsImageInput(modelName: modelName),
            streamsToolCallArguments: true,
            supportsParallelToolCalls: true
        )
    }

    // MARK: - Tool-Aware Conversation History

    /// One-shot tool-aware history payload supplied by the orchestrator.
    /// Consumed and cleared by ``buildRequest(prompt:systemPrompt:config:)``
    /// so subsequent non-tool generations fall back to the plain string
    /// history.
    private var toolAwareHistory: [ToolAwareHistoryEntry]?

    public func setToolAwareHistory(_ messages: [ToolAwareHistoryEntry]) {
        withStateLock { self.toolAwareHistory = messages }
    }

    // MARK: - Model Lifecycle

    public override func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        guard baseURL != nil else {
            throw CloudBackendError.invalidURL(
                "No base URL configured. Call configure(baseURL:apiKey:modelName:) first."
            )
        }
        setIsModelLoaded(true)
        Log.inference.info("OpenAI Responses backend configured for \(self.modelName, privacy: .public) at \(self.baseURL?.host() ?? "unknown", privacy: .public)")
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

        let responsesURL = baseURL.appendingPathComponent("v1/responses")

        // Snapshot and clear: tool-aware history is one-shot.
        let snapshotToolHistory: [ToolAwareHistoryEntry]? = withStateLock {
            let snapshot = self.toolAwareHistory
            self.toolAwareHistory = nil
            return snapshot
        }

        var input: [[String: Any]] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            input.append(["role": "system", "content": systemPrompt])
        }
        if let toolHistory = snapshotToolHistory {
            // Responses API encodes tool turns as `function_call` /
            // `function_call_output` items rather than role-tagged messages.
            for entry in toolHistory {
                input.append(contentsOf: OpenAIToolEncoding.encodeResponsesEntries(entry))
            }
        } else if let history = conversationHistory {
            // The Responses API accepts the same `(role, content)` shape as
            // Chat Completions for plain text turns; reasoning items are
            // server-managed and not replayed by the client.
            input.append(contentsOf: history.map { ["role": $0.role, "content": $0.content] as [String: Any] })
        } else {
            input.append(["role": "user", "content": prompt])
        }

        var body: [String: Any] = [
            "model": modelName,
            "input": input,
            "stream": true,
            "temperature": config.temperature,
            "top_p": config.topP,
            "max_output_tokens": config.maxOutputTokens ?? 2048
        ]

        // Tools — same `[{type:"function", function:{...}}]` envelope as Chat
        // Completions, plus the matching `tool_choice` policy.
        if !config.tools.isEmpty {
            body["tools"] = CloudMessageEncoder.openAIResponses.encodeTools(config.tools)
            OpenAIToolEncoding.applyToolChoice(config.toolChoice, into: &body)
        }

        // Only request a reasoning summary when the caller asks for thinking
        // output. Sending `reasoning` to non-reasoning models is rejected by
        // the API, so we omit it unless the caller signals intent. A value
        // of `0` is the documented "disable thinking entirely" sentinel
        // (see `GenerationConfig.maxThinkingTokens`), so treat it like nil.
        if let maxThinkingTokens = config.maxThinkingTokens, maxThinkingTokens > 0 {
            body["reasoning"] = ["effort": "medium"]
        }

        var request = URLRequest(url: responsesURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let secureKey = resolveAPIKeySecure() {
            let keyString = secureKey.stringValue
            if !keyString.isEmpty {
                request.setValue("Bearer \(keyString)", forHTTPHeaderField: "Authorization")
            }
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Log.network.debug("OpenAI Responses request to \(responsesURL.absoluteString, privacy: .public) model=\(self.modelName, privacy: .public)")

        return request
    }

    // MARK: - Stream Parsing

    /// Parses the Responses-API named-event SSE stream.
    ///
    /// Uses named-event parsing so `event:` and `data:` fields stay paired.
    public override func parseResponseStream(
        bytes: URLSession.AsyncBytes,
        config: GenerationConfig,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        let limits = effectiveSSEStreamLimits
        var rateWindowStart = ContinuousClock.now
        var rateWindowCount = 0

        // Tracks whether any reasoning_summary delta has been emitted on
        // this stream. We flush a single `.thinkingComplete` on the
        // transition to visible content so consumers see a clean handoff.
        var thinking = ThinkingBlockManager()

        // Tool-call accumulator keyed by `item_id` (Responses API's stable
        // identifier across the streamed deltas of a single function_call).
        // The accumulator stores the call_id under `entry.id` so we always
        // emit `.toolCallStart` / `.toolCallArgumentsDelta` / `.toolCall`
        // with the *call_id* downstream tool dispatch will need.
        let toolAccumulator = StreamingToolCallAccumulator()
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

        // Rate-limits every `data:` line received from the upstream,
        // regardless of whether we yield a `GenerationEvent` for it. This
        // closes the DoS hole where a hostile/buggy server could spam
        // structural events (`response.output_item.added`, etc.) we ignore
        // and bypass the per-stream cap entirely.
        func noteDataLineReceived() throws {
            let now = ContinuousClock.now
            if now - rateWindowStart >= .seconds(1) {
                rateWindowStart = now
                rateWindowCount = 1
                return
            }
            rateWindowCount += 1
            if rateWindowCount > limits.maxEventsPerSecond {
                throw SSEStreamError.eventRateExceeded(rateWindowCount)
            }
        }

        // Returns `true` if the caller should break out of the byte loop
        // (terminal event observed).
        //
        // The named-event SSE stream from OpenAI's Responses API has a
        // discrete vocabulary; this routes each event name to a focused
        // handler so the dispatcher itself stays under the per-method CC
        // ceiling.
        func handleEvent(name: String, data: String) throws -> Bool {
            switch ResponsesEventKind(name: name) {
            case .reasoningDelta:
                handleReasoningDelta(data: data, thinking: &thinking)
                return false
            case .reasoningDone:
                thinking.flushIfOpen(into: continuation)
                return false
            case .outputTextDelta:
                handleOutputTextDelta(data: data, thinking: &thinking)
                return false
            case .outputItemAdded:
                handleFunctionCallItemAdded(data: data, thinking: &thinking, accumulator: toolAccumulator)
                return false
            case .functionCallArgumentsDelta:
                handleFunctionCallArgumentsDelta(data: data, accumulator: toolAccumulator)
                return false
            case .functionCallArgumentsDone:
                // No-op here — we batch-emit `.toolCall` from
                // `response.completed` so multiple parallel calls emit in
                // insertion order. If `response.completed` never arrives the
                // outer loop's stream-end fallback finalises calls.
                return false
            case .completed:
                handleCompleted(data: data, thinking: &thinking)
                finaliseToolCalls()
                return true
            case .error:
                let message = Self.parseErrorMessage(from: data) ?? "unknown error"
                throw CloudBackendError.serverError(statusCode: 500, message: message)
            case .unknown:
                // Unknown event names (e.g. `response.content_part.added`)
                // are accepted silently — they carry structural metadata we
                // don't need today.
                return false
            }
        }

        func handleReasoningDelta(data: String, thinking: inout ThinkingBlockManager) {
            for event in Self.eventsForReasoningDelta(data: data) {
                continuation.yield(event)
                if case .thinkingToken = event { thinking.open() }
            }
        }

        func handleOutputTextDelta(data: String, thinking: inout ThinkingBlockManager) {
            let events = Self.eventsForOutputTextDelta(data: data)
            if !events.isEmpty {
                thinking.flushIfOpen(into: continuation)
                for event in events { continuation.yield(event) }
            }
        }

        // Function-call lifecycle:
        //   response.output_item.added (item.type == "function_call")
        //     → carries item.id, item.call_id, item.name; emit .toolCallStart
        //   response.function_call_arguments.delta
        //     → carries item_id + delta; emit .toolCallArgumentsDelta
        //   response.function_call_arguments.done
        //     → terminal for one call; we wait for response.completed to
        //       fire all .toolCall events together so they emit in
        //       insertion order.
        //   response.output_item.done (item.type == "function_call")
        //     → not currently parsed — `response.completed` is the
        //       authoritative finaliser. If a server stops emitting
        //       `response.completed`, the stream-end fallback in the
        //       outer loop still flushes accumulated tool calls.
        func handleFunctionCallItemAdded(
            data: String,
            thinking: inout ThinkingBlockManager,
            accumulator: StreamingToolCallAccumulator
        ) {
            guard let info = Self.parseFunctionCallItem(from: data) else { return }
            thinking.flushIfOpen(into: continuation)
            accumulator.upsert(
                key: info.itemId,
                id: info.callId,
                name: info.name,
                argumentsDelta: nil
            )
            guard !info.name.isEmpty else { return }
            continuation.yield(.toolCallStart(callId: info.callId, name: info.name))
            accumulator.markStarted(key: info.itemId)
        }

        func handleFunctionCallArgumentsDelta(
            data: String,
            accumulator: StreamingToolCallAccumulator
        ) {
            guard let info = Self.parseFunctionCallArgumentsDelta(from: data) else { return }
            accumulator.upsert(
                key: info.itemId,
                id: nil,
                name: nil,
                argumentsDelta: info.delta
            )
            guard !info.delta.isEmpty else { return }
            let resolvedId = accumulator.resolvedId(forKey: info.itemId)
            continuation.yield(.toolCallArgumentsDelta(
                callId: resolvedId,
                textDelta: info.delta
            ))
        }

        func handleCompleted(data: String, thinking: inout ThinkingBlockManager) {
            thinking.flushIfOpen(into: continuation)
            guard let usage = Self.parseUsage(from: data) else { return }
            handleUsage(usage)
            if let prompt = usage.promptTokens,
               let completion = usage.completionTokens {
                continuation.yield(.usage(prompt: prompt, completion: completion))
            }
        }

        do {
            for try await event in SSEStreamParser.parseNamed(bytes: bytes, limits: limits) {
                if Task.isCancelled { break }

                // Count each yielded named event against the per-second cap
                // before we look at the event name — unknown/ignored events
                // still consume budget.
                try noteDataLineReceived()
                guard let name = event.name else { continue }
                if try handleEvent(name: name, data: event.data) {
                    break
                }
            }
        } catch {
            // Close any open thinking block before rethrowing so consumers
            // don't hang in a thinking-only state on parser failure.
            thinking.flushIfOpen(into: continuation)
            throw error
        }

        thinking.flushIfOpen(into: continuation)
        // Stream-end fallback for tool calls. If the upstream closed without
        // a `response.completed` event (rare, but possible on truncation),
        // emit any buffered tool calls so the orchestrator can dispatch them.
        // On cancellation we deliberately skip this: dropping the consumer
        // mid-stream must not produce phantom `.toolCall` events.
        if !Task.isCancelled {
            finaliseToolCalls()
        }
    }

    // MARK: - Event Vocabulary

    /// Discrete vocabulary of named events the OpenAI Responses API emits
    /// over SSE. Centralising the name → kind mapping keeps the dispatcher
    /// in ``parseResponseStream(bytes:config:continuation:)`` a flat switch
    /// instead of a chain of `if name == ...` branches.
    enum ResponsesEventKind {
        case reasoningDelta
        case reasoningDone
        case outputTextDelta
        case outputItemAdded
        case functionCallArgumentsDelta
        case functionCallArgumentsDone
        case completed
        case error
        case unknown

        init(name: String) {
            // Providers vary on the suffix for reasoning events: some emit
            // `response.reasoning_summary_text.delta`, others use the shorter
            // `response.reasoning_summary.delta`. Accept both.
            switch name {
            case "response.reasoning_summary_text.delta",
                 "response.reasoning_summary.delta":
                self = .reasoningDelta
            case "response.reasoning_summary_text.done",
                 "response.reasoning_summary.done":
                self = .reasoningDone
            case "response.output_text.delta":
                self = .outputTextDelta
            case "response.output_item.added":
                self = .outputItemAdded
            case "response.function_call_arguments.delta":
                self = .functionCallArgumentsDelta
            case "response.function_call_arguments.done":
                self = .functionCallArgumentsDone
            case "response.completed":
                self = .completed
            case "response.error":
                self = .error
            default:
                self = .unknown
            }
        }
    }

    // MARK: - JSON Parsing

    /// Extracts a `delta` string from a Responses-API event payload.
    static func parseDelta(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parsed["delta"] as? String
    }

    /// Extracts a usage tuple from a `response.completed` payload.
    ///
    /// Shape:
    /// ```json
    /// {"response":{"usage":{"input_tokens":12,"output_tokens":8}}}
    /// ```
    static func parseUsage(from json: String) -> (promptTokens: Int?, completionTokens: Int?)? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // The usage block can sit at the top level (`{"usage":{...}}`) or
        // nested under `response` — accept either.
        let usage: [String: Any]?
        if let top = parsed["usage"] as? [String: Any] {
            usage = top
        } else if let response = parsed["response"] as? [String: Any],
                  let nested = response["usage"] as? [String: Any] {
            usage = nested
        } else {
            usage = nil
        }
        guard let usage else { return nil }
        let prompt = usage["input_tokens"] as? Int ?? usage["prompt_tokens"] as? Int
        let completion = usage["output_tokens"] as? Int ?? usage["completion_tokens"] as? Int
        if prompt == nil && completion == nil { return nil }
        return (prompt, completion)
    }

    // MARK: - Tool-call parsing

    /// Parsed metadata from a `response.output_item.added` event whose item
    /// is a `function_call`.
    struct FunctionCallItemInfo {
        let itemId: String
        let callId: String
        let name: String
    }

    /// Parses a `response.output_item.added` payload, returning the
    /// function-call metadata when the embedded item carries
    /// `type == "function_call"`. Returns `nil` for unrelated items
    /// (e.g. reasoning, message).
    static func parseFunctionCallItem(from json: String) -> FunctionCallItemInfo? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = parsed["item"] as? [String: Any] else {
            return nil
        }
        guard (item["type"] as? String) == "function_call" else { return nil }
        // item.id is the streaming-internal handle; call_id is the value the
        // model used to refer to this call (and what we feed back to the
        // server in `function_call_output.call_id`). Both are required.
        guard let itemId = item["id"] as? String, !itemId.isEmpty,
              let callId = item["call_id"] as? String, !callId.isEmpty else {
            return nil
        }
        let name = (item["name"] as? String) ?? ""
        return FunctionCallItemInfo(itemId: itemId, callId: callId, name: name)
    }

    /// Parsed `response.function_call_arguments.delta` payload.
    struct FunctionCallArgumentsDelta {
        let itemId: String
        let delta: String
    }

    static func parseFunctionCallArgumentsDelta(from json: String) -> FunctionCallArgumentsDelta? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let itemId = parsed["item_id"] as? String, !itemId.isEmpty else {
            return nil
        }
        let delta = (parsed["delta"] as? String) ?? ""
        return FunctionCallArgumentsDelta(itemId: itemId, delta: delta)
    }

    /// Extracts an error message from a `response.error` payload.
    static func parseErrorMessage(from json: String) -> String? {
        parseCloudErrorMessage(from: json)
    }

    // MARK: - SSE Payload Handler

    /// Classifies a single Responses-API SSE payload into the
    /// reasoning/text events it carries.
    ///
    /// The named-event dispatcher in
    /// ``parseResponseStream(bytes:config:continuation:)`` already routes
    /// on `event:` names; the handler centralises the per-payload
    /// `delta` extraction so reasoning vs. visible-text classification
    /// lives in one place.
    ///
    /// - `delta` payload (any of the reasoning summary or output text
    ///   delta event names) shapes as `{"delta":"..."}`. The handler
    ///   distinguishes thinking vs. plain by inspecting the named-event
    ///   `event:` line, which the dispatcher passes alongside the data.
    ///   When the dispatcher routes a reasoning-delta `data:` line in
    ///   isolation (e.g. unit tests against `extractEvents` directly),
    ///   the handler returns `.token` for any `delta` payload because the
    ///   wire shape is indistinguishable without the surrounding
    ///   `event:` field; callers that need the thinking classification
    ///   use ``OpenAIResponsesBackend/eventsForReasoningDelta(data:)``
    ///   and ``OpenAIResponsesBackend/eventsForOutputTextDelta(data:)``
    ///   helpers, which are what the dispatcher itself calls.
    struct OpenAIResponsesPayloadHandler: SSEPayloadHandler {
        func extractToken(from payload: String) -> String? {
            OpenAIResponsesBackend.parseDelta(from: payload)
        }

        /// Default `extractEvents` returns `.token(...)` for any payload
        /// carrying a `delta` field. The named-event dispatcher overrides
        /// this classification when it knows the surrounding `event:` is
        /// a reasoning event — see the helpers in
        /// ``OpenAIResponsesBackend``.
        func extractEvents(from payload: String) -> [GenerationEvent] {
            if let delta = OpenAIResponsesBackend.parseDelta(from: payload), !delta.isEmpty {
                return [.token(delta)]
            }
            return []
        }

        func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
            OpenAIResponsesBackend.parseUsage(from: payload)
        }
        func isStreamEnd(_ payload: String) -> Bool { false }
        func extractStreamError(from payload: String) -> Error? { nil }
    }

    // MARK: - Per-event-name classification helpers

    /// Maps a `response.reasoning_summary*.delta` payload to the events the
    /// dispatcher should yield. Always emits `.thinkingToken` for non-empty
    /// deltas. Centralised so the unit test for the named-event dispatcher
    /// has a single classification surface to assert against.
    static func eventsForReasoningDelta(data: String) -> [GenerationEvent] {
        guard let delta = parseDelta(from: data), !delta.isEmpty else { return [] }
        return [.thinkingToken(delta)]
    }

    /// Maps a `response.output_text.delta` payload to the events the
    /// dispatcher should yield.
    static func eventsForOutputTextDelta(data: String) -> [GenerationEvent] {
        guard let delta = parseDelta(from: data), !delta.isEmpty else { return [] }
        return [.token(delta)]
    }
}
#endif
