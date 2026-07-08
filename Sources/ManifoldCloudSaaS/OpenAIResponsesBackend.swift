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
/// values, with a single ``GenerationEvent/thinkingCompleted`` injected on
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
public final class OpenAIResponsesBackend: SSECloudBackend, TokenUsageProvider, EndpointBackendURLModelConfigurable, EndpointBackendKeychainConfigurable, ToolCallingHistoryReceiver, @unchecked Sendable {

    // MARK: - Adapter composition (Phase 3/Responses)
    //
    // `OpenAIResponsesBackend` composes a ``CloudHTTPProviderAdapter``
    // (specifically ``OpenAIResponsesAdapter``) so the cross-backend
    // audit (`CloudSeamUsageAuditTest`) recognises it as on the unified
    // adapter path. The adapter holds the per-provider divergences as
    // composable witnesses (item-id tool-call shape, function-call-item
    // tool-result encoding, named-SSE framing, `response.completed`
    // finalizer; everything else mirrors Chat Completions).
    public let adapter: any CloudHTTPProviderAdapter

    // MARK: - Init

    /// Creates an OpenAI Responses-API backend.
    ///
    /// - Parameter urlSession: Custom URLSession. Pass `nil` to use the
    ///   default pinned session.
    public init(urlSession: URLSession? = nil) {
        self.adapter = OpenAIResponsesAdapter(
            capabilities: Self.defaultAdapterCapabilities,
            requestBuilder: { _, _, _, _ in
                throw CloudBackendError.invalidURL(
                    "OpenAIResponsesAdapter.requestBuilder is not the live path; the OpenAIResponsesBackend installs a CloudAdapterRouting that delegates to its own buildRequest override."
                )
            }
        )
        super.init(
            defaultModelName: "gpt-5",
            urlSession: urlSession ?? URLSessionProvider.pinned,
            // Payload handler classifies wrapped `NamedSSETransport`
            // envelopes for in-stream error surfacing
            // (`response.error`); event extraction itself is driven by
            // ``OpenAIResponsesStreamEventExtractor`` via the routing's
            // `streamConsumerFactory`.
            payloadHandler: CloudPayloadHandler.openAIResponses
        )

        // Phase 3/Responses — install adapter routing so the stream loop
        // runs in `CloudRoutedStreamParser` and event
        // extraction is driven by a fresh per-stream
        // `OpenAIResponsesStreamEventExtractor`. The previous inline
        // `parseResponseStream(bytes:config:continuation:)` override is
        // deleted; the routing carries the same per-stream state — open
        // thinking flag, item-id → call-id accumulator, once-only
        // finalisation guard — that previously lived as locals in the
        // inline loop.
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
            streamConsumerFactory: { OpenAIResponsesStreamEventExtractor() }
        )
        self.configure(adapterRouting: routing)
    }

    /// Static adapter capabilities used at init time. Mirrors the dynamic
    /// `capabilities` property's values for `gpt-5` so the adapter
    /// composition is valid immediately; the dynamic property remains
    /// authoritative once a real `modelName` is configured.
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
        maxOutputTokens: 16_384,
        supportsStreaming: true,
        isRemote: true,
        supportsThinking: true,
        supportsVision: false,
        streamsToolCallArguments: true,
        supportsParallelToolCalls: true,
        // The Responses API honors `text.format: {type: "json_schema",
        // strict: true}` the same way Chat Completions honors
        // `response_format` — see the strict-structured-output block in
        // `buildRequest` below.
        supportsStrictSchema: true,
        // Responses API sends structured input items on the wire, so
        // `.promptRendered` carries only the latest user message — partial (#1905).
        rendersFullPrompt: false
    )

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
            supportsParallelToolCalls: true,
            // See `defaultAdapterCapabilities` — the Responses API honors
            // `text.format: {type: "json_schema", strict: true}`.
            supportsStrictSchema: true,
            // Structured input items on the wire → partial `.promptRendered` (#1905).
            rendersFullPrompt: false
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
        // User-settable stop sequences (#1944) are deliberately NOT emitted here.
        // The OpenAI Responses API does not support a stop-sequence parameter:
        // sending top-level `stop` returns 400 "Unknown parameter: 'stop'. Did you
        // mean 'store'?" (verified against the OpenAI Responses reference + the
        // "Does Responses API support `stop` parameter or not?" developer-forum
        // thread, 2026-06). Chat Completions keeps `stop`; Responses callers that
        // set GenerationConfig.stopSequences simply get no stop field on the wire
        // rather than an invalid one that 400s on strict providers.

        // Tools — same `[{type:"function", function:{...}}]` envelope as Chat
        // Completions, plus the matching `tool_choice` policy.
        if !config.tools.isEmpty {
            body["tools"] = CloudMessageEncoder.openAIResponses.encodeTools(config.tools)
            OpenAIToolEncoding.applyToolChoice(config.toolChoice, into: &body)
        }

        // Strict structured output — the Responses API equivalent of Chat
        // Completions' `response_format` (see `OpenAIBackend.buildRequest`).
        // `GenerationQueue`'s `StructuredOutputRouter` selects `.jsonSchema`
        // whenever `capabilities.supportsStructuredOutput` is true and leaves
        // the schema on `activeHints.structuredOutput` for the backend to honor on
        // the wire; this backend previously never read it back, silently
        // dropping the caller's schema. The Responses API expects the format
        // nested under `text.format` rather than a top-level
        // `response_format` key.
        let strictSchemaString = StrictSchemaTransform.jsonSchemaString(from: activeHints.structuredOutput)
        let strictRequested = capabilities.supportsStrictSchema && strictSchemaString != nil
        if strictRequested,
           let schemaString = strictSchemaString,
           let strictSchema = OpenAIBackend.strictResponseFormatSchema(from: schemaString) {
            body["text"] = [
                "format": [
                    "type": "json_schema",
                    "name": "response",
                    "strict": true,
                    "schema": strictSchema,
                ] as [String: Any],
            ]
        } else if activeHints.jsonMode {
            body["text"] = ["format": ["type": "json_object"]]
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
    //
    // Phase 3/Responses deleted the inline `parseResponseStream` override
    // and its `handleEvent` / `handleReasoningDelta` / `handleOutputTextDelta`
    // / `handleFunctionCallItemAdded` / `handleFunctionCallArgumentsDelta`
    // / `handleCompleted` cluster. The adapter routing installed at
    // `init(urlSession:)` time threads stream parsing through
    // ``CloudRoutedStreamParser``,
    // which drives a fresh ``OpenAIResponsesStreamEventExtractor`` per
    // generation. The extractor owns the per-stream state — open
    // thinking flag, item-id → call-id accumulator, once-only
    // finalisation guard — that previously lived as locals in the
    // inline loop.
    //
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
        guard let parsed = JSONValue.parse(string: json) else { return nil }
        return parseDelta(from: parsed)
    }

    static func parseDelta(from json: JSONValue) -> String? {
        json["delta"]?.stringValue
    }

    /// Extracts a usage tuple from a `response.completed` payload.
    ///
    /// Shape:
    /// ```json
    /// {"response":{"usage":{"input_tokens":12,"output_tokens":8}}}
    /// ```
    static func parseUsage(from json: String) -> (promptTokens: Int?, completionTokens: Int?)? {
        guard let parsed = JSONValue.parse(string: json) else { return nil }
        return parseUsage(from: parsed)
    }

    static func parseUsage(from json: JSONValue) -> (promptTokens: Int?, completionTokens: Int?)? {
        // The usage block can sit at the top level (`{"usage":{...}}`) or
        // nested under `response` — accept either.
        let usage: [String: JSONValue]?
        if let top = json["usage"]?.objectValue {
            usage = top
        } else if let nested = json["response"]?.objectValue?["usage"]?.objectValue {
            usage = nested
        } else {
            usage = nil
        }
        guard let usage else { return nil }
        let prompt = usage["input_tokens"]?.intValue ?? usage["prompt_tokens"]?.intValue
        let completion = usage["output_tokens"]?.intValue ?? usage["completion_tokens"]?.intValue
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
        guard let parsed = JSONValue.parse(string: json) else { return nil }
        return parseFunctionCallItem(from: parsed)
    }

    static func parseFunctionCallItem(from json: JSONValue) -> FunctionCallItemInfo? {
        guard let item = json["item"]?.objectValue else { return nil }
        guard item["type"]?.stringValue == "function_call" else { return nil }
        // item.id is the streaming-internal handle; call_id is the value the
        // model used to refer to this call (and what we feed back to the
        // server in `function_call_output.call_id`). Both are required.
        guard let itemId = item["id"]?.stringValue, !itemId.isEmpty,
              let callId = item["call_id"]?.stringValue, !callId.isEmpty else {
            return nil
        }
        let name = item["name"]?.stringValue ?? ""
        return FunctionCallItemInfo(itemId: itemId, callId: callId, name: name)
    }

    /// Parsed `response.function_call_arguments.delta` payload.
    struct FunctionCallArgumentsDelta {
        let itemId: String
        let delta: String
    }

    static func parseFunctionCallArgumentsDelta(from json: String) -> FunctionCallArgumentsDelta? {
        guard let parsed = JSONValue.parse(string: json) else { return nil }
        return parseFunctionCallArgumentsDelta(from: parsed)
    }

    static func parseFunctionCallArgumentsDelta(from json: JSONValue) -> FunctionCallArgumentsDelta? {
        guard let itemId = json["item_id"]?.stringValue, !itemId.isEmpty else {
            return nil
        }
        let delta = json["delta"]?.stringValue ?? ""
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
    /// Thin shim retained so `OpenAIResponsesPayloadHandlerTests` (until it
    /// migrates to the unified contract suite in Phase 2) keeps compiling.
    /// New call sites use ``CloudPayloadHandler/openAIResponses`` directly.
    struct OpenAIResponsesPayloadHandler: SSEPayloadHandler {
        private let inner: CloudPayloadHandler = .openAIResponses
        func extractToken(from payload: String) -> String? { inner.extractToken(from: payload) }
        func extractEvents(from payload: String) -> [GenerationEvent] { inner.extractEvents(from: payload) }
        func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
            inner.extractUsage(from: payload)
        }
        func isStreamEnd(_ payload: String) -> Bool { inner.isStreamEnd(payload) }
        func extractStreamError(from payload: String) -> Error? { inner.extractStreamError(from: payload) }
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

    static func eventsForReasoningDelta(data: JSONValue) -> [GenerationEvent] {
        guard let delta = parseDelta(from: data), !delta.isEmpty else { return [] }
        return [.thinkingToken(delta)]
    }

    /// Maps a `response.output_text.delta` payload to the events the
    /// dispatcher should yield.
    static func eventsForOutputTextDelta(data: String) -> [GenerationEvent] {
        guard let delta = parseDelta(from: data), !delta.isEmpty else { return [] }
        return [.token(delta)]
    }

    static func eventsForOutputTextDelta(data: JSONValue) -> [GenerationEvent] {
        guard let delta = parseDelta(from: data), !delta.isEmpty else { return [] }
        return [.token(delta)]
    }
}

/// Sendable weak reference used by the routing closure to call back into
/// the backend's `buildRequest` without retaining `self`. Mirrors the
/// `WeakBackendBox` pattern in `OpenAIBackend`.
private final class WeakBackendBox: @unchecked Sendable {
    weak var value: OpenAIResponsesBackend?
    init(_ value: OpenAIResponsesBackend) { self.value = value }
}
