#if Ollama
import Foundation
import os
import BaseChatInference

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
    private var effectiveNumCtx: Int = defaultNumCtxFloor

    // MARK: - Init

    /// Creates an Ollama backend.
    ///
    /// - Parameter urlSession: Custom URLSession for testing. Pass `nil` to use the default.
    ///
    /// When `urlSession` is `nil` and the runtime kill-switch
    /// ``URLSessionProvider/networkDisabled`` is set, the underlying property
    /// access traps. Use ``makeChecked(urlSession:)`` for a throwing variant
    /// that surfaces the kill-switch as a recoverable error.
    @available(*, deprecated, message: "Ollama remains in default traits this minor; in the next major it moves to opt-in. Add the `Ollama` trait to your .package(...) entry, or register via DefaultBackends.register(_:). See README 'Build modes' and #714.")
    public init(urlSession: URLSession? = nil) {
        super.init(
            defaultModelName: "llama3.2",
            urlSession: urlSession ?? URLSessionProvider.unpinned,
            payloadHandler: OllamaPayloadHandler()
        )
    }

    /// Throwing factory that propagates ``URLSessionProvider/networkDisabled``
    /// as ``CloudBackendError/networkDisabled`` instead of trapping.
    @available(*, deprecated, message: "Ollama remains in default traits this minor; in the next major it moves to opt-in. Add the `Ollama` trait to your .package(...) entry, or register via DefaultBackends.register(_:). See README 'Build modes' and #714.")
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
        BackendCapabilities(
            supportedParameters: [.temperature, .topP, .topK, .repeatPenalty],
            maxContextTokens: 128_000,
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
        // BaseChatKit positions itself as local-first, so silently sending
        // prompts off-device would violate the caller's expectation — throw a
        // descriptive error at load time rather than leak conversation content
        // to a remote endpoint the user didn't consciously opt into.
        if modelName.hasSuffix(":cloud") {
            throw CloudBackendError.invalidURL(
                "Ollama model '\(modelName)' is a :cloud-suffixed tag that routes to remote inference. BaseChatKit is local-first — strip the :cloud suffix or switch to a cloud backend (ClaudeBackend, OpenAIBackend) if remote inference is intended."
            )
        }

        // Honour the plan's effective context size so Ollama's `num_ctx`
        // matches what BCK's `ContextWindowManager` budgets against. If the
        // caller used the `.cloud()` factory (which defaults to 1), fall back
        // to the floor — Ollama's own 2048 default is a documented footgun
        // that silently truncates multi-turn conversations.
        let planned = plan.effectiveContextSize
        effectiveNumCtx = planned > Self.defaultNumCtxFloor ? planned : Self.defaultNumCtxFloor

        self.isThinkingModel = (try? await detectThinkingCapability()) ?? false

        setIsModelLoaded(true)
        Log.inference.info("OllamaBackend configured for \(self.modelName, privacy: .public) at \(self.baseURL?.host() ?? "unknown", privacy: .public) thinking=\(self.isThinkingModel, privacy: .public) num_ctx=\(self.effectiveNumCtx, privacy: .public)")
    }

    /// Calls Ollama's `/api/show` endpoint and classifies the model as
    /// thinking-capable or not.
    ///
    /// Detection prefers `capabilities: ["thinking", ...]` (surfaced by modern
    /// Ollama releases) and falls back to scanning the Jinja `template` field
    /// for `<think>`, `</think>`, or `{{ if .Thinking }}` markers that
    /// reasoning models ship by convention.
    ///
    /// Returns `false` (not `nil`) on HTTP failures other than thrown network
    /// errors so callers get a clean boolean; `throws` so internal bugs (bad
    /// URL, serialization failure) still surface for the test harness.
    private func detectThinkingCapability() async throws -> Bool {
        guard let baseURL else { return false }
        let showURL = baseURL.appendingPathComponent("api/show")

        var request = URLRequest(url: showURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": modelName])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            Log.network.info("OllamaBackend /api/show probe failed (\(error.localizedDescription, privacy: .public)) — treating \(self.modelName, privacy: .public) as non-thinking")
            return false
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            Log.network.info("OllamaBackend /api/show returned HTTP \(http.statusCode, privacy: .public) for \(self.modelName, privacy: .public) — treating as non-thinking")
            return false
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Log.network.info("OllamaBackend /api/show returned non-JSON for \(self.modelName, privacy: .public) — treating as non-thinking")
            return false
        }

        // Preferred: structured capabilities list.
        if let caps = json["capabilities"] as? [String],
           caps.contains(where: { $0.lowercased() == "thinking" }) {
            return true
        }

        // Fallback: scan the template for thinking markers.
        if let template = json["template"] as? String {
            let markers = ["<think>", "</think>", "{{ if .Thinking }}", "{{if .Thinking}}"]
            if markers.contains(where: { template.contains($0) }) {
                return true
            }
        }

        return false
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
            messages.append(contentsOf: toolHistory.map(Self.encodeToolAwareEntry))
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

        let options: [String: Any] = [
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
            "num_ctx": effectiveNumCtx,
        ]

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
            body["tools"] = config.tools.map(Self.encodeToolDefinition)
            switch config.toolChoice {
            case .auto:
                break
            case .none:
                body["tool_choice"] = "none"
            case .required:
                body["tool_choice"] = "required"
            case .tool(let name):
                body["tool_choice"] = [
                    "type": "function",
                    "function": ["name": name],
                ]
            }
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
    ///
    /// Applies the same ``SSEStreamLimits`` caps as the SSE parser so a
    /// hostile Ollama-compatible server cannot exhaust memory with oversized
    /// lines, total volume, or an event flood.
    ///
    /// Reasoning models (qwen3, qwen3.5:4b, deepseek-r1) surface chain-of-thought
    /// tokens in a separate `thinking` field — `message.thinking` on the
    /// `/api/chat` endpoint and top-level `thinking` on `/api/generate`. We
    /// emit ``GenerationEvent/thinkingToken(_:)`` while a line carries
    /// non-empty thinking, and ``GenerationEvent/thinkingComplete`` exactly
    /// once — either on the transition from "thinking was non-empty" to
    /// "thinking is now empty", or on `"done":true` when a thinking
    /// accumulator is still open. ``GenerationConfig/maxThinkingTokens``
    /// caps reasoning emission; once exceeded subsequent thinking content is
    /// dropped and only visible ``GenerationEvent/token(_:)`` events continue.
    ///
    /// Fallback for models that leak reasoning into content: some Ollama
    /// models (e.g. Qwen3 tags that don't populate `message.thinking` on this
    /// server) emit `<think>…</think>` blocks inline in `content` instead.
    /// When we never see a populated `thinking` field on the stream and a
    /// content chunk contains the opening marker, content is routed through
    /// ``ThinkingParser`` so callers still receive
    /// ``GenerationEvent/thinkingToken(_:)`` /
    /// ``GenerationEvent/thinkingComplete`` events rather than the raw tags.
    /// The ``GenerationConfig/maxThinkingTokens`` cap still applies; visible
    /// content emerges from the parser as ``GenerationEvent/token(_:)``.
    ///
    /// Limitation: engagement is per-chunk, so an opening marker split across
    /// two NDJSON content chunks (e.g. `<th` + `ink>`) would miss detection
    /// and yield raw tag fragments as visible tokens. In practice Ollama
    /// emits `message.content` in coarse line-sized chunks, so the opening
    /// tag lands in a single chunk. Once engaged, the parser's own buffering
    /// correctly reassembles a closing tag split across chunks.
    public override func parseResponseStream(
        bytes: URLSession.AsyncBytes,
        config: GenerationConfig,
        continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation
    ) async throws {
        let limits = effectiveSSEStreamLimits
        var lineBuffer = Data()
        var totalBytes = 0
        var rateWindowStart = ContinuousClock.now
        var rateWindowCount = 0

        // Tracks whether we've emitted any thinking content on this stream,
        // so we know when to fire the single .thinkingComplete event.
        var thinkingOpen = false
        var thinkingTokenCount = 0
        let thinkingLimit = config.maxThinkingTokens
        // Fallback per-line counter for servers that don't emit `eval_count`
        // until the done-line. When a line carries `eval_count`, we prefer it
        // over this counter for an exact cap.
        var visibleLineCount = 0
        let visibleLimit = config.maxOutputTokens

        // Inline `<think>` fallback state. Engaged only when the server never
        // populates `message.thinking` / top-level `thinking` and a content
        // chunk carries `<think>`. Once engaged it stays engaged for the rest
        // of the stream so partial tags split across chunks are held back
        // correctly by the parser's own buffering.
        var sawThinkingField = false
        let fallbackMarkers = config.thinkingMarkers ?? .qwen3
        var contentParser: ThinkingParser?

        func noteEventYielded() throws {
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

        // Yield a single parser-produced event while honouring the per-stream
        // caps used elsewhere. Returns `false` when the visible-token cap was
        // hit and the caller should stop producing further output on this
        // line. Only handles the events `ThinkingParser` actually emits
        // (`.token`, `.thinkingToken`, `.thinkingComplete`); anything else is
        // forwarded verbatim.
        func emit(_ event: GenerationEvent) throws -> Bool {
            switch event {
            case .thinkingToken(let text):
                if let limit = thinkingLimit, thinkingTokenCount >= limit {
                    return true // Drop silently — cap reached.
                }
                try noteEventYielded()
                continuation.yield(.thinkingToken(text))
                thinkingOpen = true
                thinkingTokenCount += 1
                return true
            case .thinkingComplete:
                try noteEventYielded()
                continuation.yield(.thinkingComplete)
                thinkingOpen = false
                return true
            case .token(let text):
                if let limit = visibleLimit, visibleLineCount >= limit {
                    continuation.finish()
                    return false
                }
                try noteEventYielded()
                continuation.yield(.token(text))
                visibleLineCount += 1
                return true
            default:
                continuation.yield(event)
                return true
            }
        }

        // Tool calls first: Ollama can emit multiple tool_calls in a single
        // assistant message. Dispatch them in emission order so the
        // coordinator's serial dispatch loop sees them in the same order
        // the model produced them.
        //
        // Event-shape contract (PR #783): every tool call surfaces as a
        // uniform start + single arguments-delta + toolCall triple, even
        // for whole-call backends like Ollama. That keeps consumers
        // (orchestrator, UI) on a single code path regardless of whether
        // the underlying transport streams arguments incrementally.
        //
        // TODO(#753): Some Ollama configs (notably `qwen2.5:7b` against
        // newer servers) reportedly emit incremental tool_call deltas
        // across multiple NDJSON lines. v1 treats Ollama as whole-call
        // only; if we observe incremental deltas in the wild, lift
        // `StreamingToolCallAccumulator` from `OpenAIToolEncoding.swift`
        // and key by tool-call index here. `streamsToolCallArguments`
        // would flip to `true` at the same time.
        // Returns `false` when `Task.isCancelled` is observed at any point
        // during this helper so `handleLine` can skip the remaining
        // sub-handlers (`processThinking` / `processContent`) for the same
        // NDJSON line. Pre-#970 the equivalent in-loop `if Task.isCancelled
        // { return }` exited `handleLine` directly; after the decomposition
        // a bare `return` exits only this helper, which would let
        // post-cancel thinking and content events surface — the regression
        // #972 fixes by mirroring `processContent`'s `Bool` convention.
        func processToolCalls(_ parsed: ParsedLine) throws -> Bool {
            guard let toolCalls = parsed.toolCalls, !toolCalls.isEmpty else {
                // Even with no tool_calls on this line, a cancel that
                // arrived between sub-handlers must short-circuit
                // downstream emission for the same line.
                return !Task.isCancelled
            }
            for call in toolCalls {
                // Cancellation contract: a consumer that drops the stream
                // mid-flight must NOT observe `.toolCall` events for
                // entries the orchestrator never agreed to dispatch. Honour
                // `Task.isCancelled` at the emit boundary so a single-line
                // tool_calls payload arriving alongside the cancel doesn't
                // fire a phantom dispatch.
                if Task.isCancelled { return false }
                try noteEventYielded()
                continuation.yield(.toolCallStart(callId: call.id, name: call.toolName))
                if !call.arguments.isEmpty {
                    try noteEventYielded()
                    continuation.yield(.toolCallArgumentsDelta(
                        callId: call.id,
                        textDelta: call.arguments
                    ))
                }
                try noteEventYielded()
                continuation.yield(.toolCall(call))
            }
            // Post-loop cancellation: if the cancel arrived after the last
            // tool_call was emitted but before this helper returned, still
            // bail so thinking/content on the same line don't surface.
            return !Task.isCancelled
        }

        // Route thinking field (if any) first so downstream consumers see
        // reasoning before visible content for a given NDJSON record.
        func processThinking(_ parsed: ParsedLine) throws {
            if let thinking = parsed.thinking, !thinking.isEmpty {
                sawThinkingField = true
                if let limit = thinkingLimit, thinkingTokenCount >= limit {
                    return // Cap reached — drop this thinking chunk silently.
                }
                try noteEventYielded()
                continuation.yield(.thinkingToken(thinking))
                thinkingOpen = true
                // Count each thinking-bearing NDJSON line as one "token"
                // for cap purposes. Ollama ships whole-blob thinking per
                // line rather than per-token, so this matches the coarser
                // grain of the wire format.
                thinkingTokenCount += 1
                return
            }
            // Transition from thinking → content. Fire .thinkingComplete
            // exactly once on the first empty-thinking line we see after
            // any non-empty thinking was emitted. Skipped when the fallback
            // parser is driving state — the parser closes its own thinking
            // block via its own `.thinkingComplete`.
            if thinkingOpen && contentParser == nil {
                try noteEventYielded()
                continuation.yield(.thinkingComplete)
                thinkingOpen = false
            }
        }

        // Returns `false` when the stream should stop (visible-token cap hit
        // or the fallback parser surfaced a stop signal); `true` to keep
        // processing further fields on the same line.
        func processContent(_ parsed: ParsedLine) throws -> Bool {
            guard let content = parsed.content, !content.isEmpty else { return true }
            // Prefer the server's running `eval_count` when present for an
            // exact token-count cap; otherwise fall back to the NDJSON line
            // counter which is an upper bound but may overshoot by one line.
            if let limit = visibleLimit {
                let observed = parsed.evalCount ?? visibleLineCount
                if observed >= limit {
                    continuation.finish()
                    return false
                }
            }
            // Engage the fallback `<think>`-in-content parser when the
            // server has never populated a dedicated thinking field on this
            // stream and the incoming content carries the opening tag. Once
            // engaged, every subsequent content chunk flows through the
            // parser so a tag split across two NDJSON lines is held in the
            // parser's own buffer.
            if contentParser == nil,
               !sawThinkingField,
               content.contains(fallbackMarkers.open) {
                contentParser = ThinkingParser(markers: fallbackMarkers)
            }
            if var parser = contentParser {
                for event in parser.process(content) {
                    if try !emit(event) {
                        contentParser = parser
                        return false
                    }
                }
                contentParser = parser
            } else {
                try noteEventYielded()
                continuation.yield(.token(content))
                visibleLineCount += 1
            }
            return true
        }

        // Returns `false` when the fallback parser surfaced a stop signal
        // mid-flush (visible-token cap hit while draining held-back bytes).
        func processDoneFlush() throws -> Bool {
            // Flush any remaining buffered content from the fallback parser
            // first — held-back bytes (e.g. an unmatched prefix of `<`)
            // must be emitted before we decide whether thinking is still
            // open.
            if var parser = contentParser {
                for event in parser.finalize() {
                    if try !emit(event) {
                        contentParser = parser
                        return false
                    }
                }
                contentParser = parser
            }
            // Ollama can terminate with `"done":true` while thinking is
            // still the only content emitted (e.g. reasoning model hits
            // num_predict mid-think). Flush .thinkingComplete so downstream
            // consumers don't leave the thinking block open.
            if thinkingOpen {
                try noteEventYielded()
                continuation.yield(.thinkingComplete)
                thinkingOpen = false
            }
            return true
        }

        // Surface usage from the done-line (`eval_count`,
        // `prompt_eval_count`). Wires into `handleUsage` (populating
        // `lastUsage` for `TokenUsageProvider` consumers) and emits a
        // `.usage` event on the stream, mirroring the SSE path in
        // `SSECloudBackend.parseResponseStream`.
        func processUsage(_ parsed: ParsedLine) throws {
            guard parsed.evalCount != nil || parsed.promptEvalCount != nil else { return }
            let usage: (promptTokens: Int?, completionTokens: Int?) = (
                promptTokens: parsed.promptEvalCount,
                completionTokens: parsed.evalCount
            )
            handleUsage(usage)
            if let prompt = usage.promptTokens,
               let completion = usage.completionTokens {
                try noteEventYielded()
                continuation.yield(.usage(prompt: prompt, completion: completion))
            }
        }

        func handleLine(_ line: String) throws {
            guard let parsed = Self.parseLine(line) else { return }
            guard try processToolCalls(parsed) else { return }
            try processThinking(parsed)
            guard try processContent(parsed) else { return }
            if parsed.done {
                guard try processDoneFlush() else { return }
                try processUsage(parsed)
            }
        }

        for try await byte in bytes {
            if Task.isCancelled { break }

            totalBytes += 1
            if totalBytes > limits.maxTotalBytes {
                throw SSEStreamError.streamTooLarge(totalBytes)
            }

            if byte == UInt8(ascii: "\n") {
                if !lineBuffer.isEmpty {
                    if let line = String(data: lineBuffer, encoding: .utf8) {
                        try handleLine(line)
                    }
                    lineBuffer.removeAll(keepingCapacity: true)
                }
            } else {
                lineBuffer.append(byte)
                if lineBuffer.count > limits.maxEventBytes {
                    throw SSEStreamError.eventTooLarge(lineBuffer.count)
                }
            }
        }

        // Flush any final line without a trailing newline.
        if !lineBuffer.isEmpty,
           let line = String(data: lineBuffer, encoding: .utf8) {
            try handleLine(line)
        }

        // Drain any bytes still held back inside the fallback parser. A stream
        // that ends without a trailing done-chunk (network cut, malformed
        // last line) would otherwise swallow the final held-back suffix.
        if var parser = contentParser {
            for event in parser.finalize() {
                _ = try emit(event)
            }
            contentParser = parser
        }

        // Safety net: if the stream ends while thinking is still "open"
        // (no done-chunk, no empty-thinking transition), still close it out
        // so consumers don't hang in a thinking-only state.
        if thinkingOpen {
            try noteEventYielded()
            continuation.yield(.thinkingComplete)
        }
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
                Self.extractErrorMessage(from: errorBody),
                host: host
            )
            throw CloudBackendError.serverError(statusCode: statusCode, message: message)
        }
    }

    // MARK: - NDJSON Parsing

    /// Decoded shape of a single Ollama NDJSON record.
    ///
    /// Ollama's two endpoints carry data in different places:
    /// - `/api/chat` streams put content in `message.content` and reasoning in
    ///   `message.thinking`.
    /// - `/api/generate` (non-chat) uses top-level `response` and top-level
    ///   `thinking`.
    /// `parseLine` normalises both shapes; consumers read `content` and
    /// `thinking` without caring which endpoint produced the line.
    ///
    /// `evalCount` / `promptEvalCount` are the exact token counts reported by
    /// the Ollama server. Per Ollama's documented API, these appear on the
    /// terminal `"done":true` line — `eval_count` is the number of tokens the
    /// model produced this turn and `prompt_eval_count` is the number of tokens
    /// in the prompt. Some Ollama-compatible servers also emit a running
    /// `eval_count` on intermediate lines; parsing it unconditionally lets the
    /// stream cap visible output precisely when available and falls back to a
    /// line counter when not.
    struct ParsedLine {
        var content: String?
        var thinking: String?
        var done: Bool
        var evalCount: Int?
        var promptEvalCount: Int?
        /// Tool calls emitted by the assistant this line, in emission order.
        /// `nil` when the line carries no `tool_calls` field; an empty array
        /// is normalised to `nil` so downstream callers can short-circuit on
        /// `parsed.toolCalls != nil`.
        var toolCalls: [ToolCall]?
    }

    /// Parses a single Ollama NDJSON line into a normalised shape.
    ///
    /// Returns `nil` for malformed lines so the stream parser can skip them
    /// the same way it historically skipped unparseable JSON.
    static func parseLine(_ json: String) -> ParsedLine? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let done = (parsed["done"] as? Bool) ?? false

        var content: String?
        var thinking: String?
        var toolCalls: [ToolCall]?

        if let message = parsed["message"] as? [String: Any] {
            // `/api/chat` shape.
            content = message["content"] as? String
            thinking = message["thinking"] as? String
            if let rawCalls = message["tool_calls"] as? [[String: Any]], !rawCalls.isEmpty {
                toolCalls = rawCalls.compactMap(Self.decodeToolCall)
                if toolCalls?.isEmpty == true { toolCalls = nil }
            }
        }

        // `/api/generate` shape — top-level `response` and `thinking`. If both
        // `message.content` and top-level `response` are present (shouldn't
        // happen in practice), chat-shape wins because it arrived first.
        if content == nil, let response = parsed["response"] as? String {
            content = response
        }
        if thinking == nil, let topThinking = parsed["thinking"] as? String {
            thinking = topThinking
        }

        // Usage fields — `eval_count` (output tokens) and `prompt_eval_count`
        // (prompt tokens). Documented as done-line fields but we parse them
        // unconditionally so a running-count-emitting server is handled too.
        let evalCount = parsed["eval_count"] as? Int
        let promptEvalCount = parsed["prompt_eval_count"] as? Int

        return ParsedLine(
            content: content,
            thinking: thinking,
            done: done,
            evalCount: evalCount,
            promptEvalCount: promptEvalCount,
            toolCalls: toolCalls
        )
    }

    // MARK: - Tool-Call Encoding / Decoding Helpers

    /// Serialise a ``ToolDefinition`` into the OpenAI `tools` envelope shape
    /// Ollama accepts:
    ///
    /// ```json
    /// { "type": "function",
    ///   "function": { "name": "...", "description": "...", "parameters": {...} } }
    /// ```
    ///
    /// `parameters` round-trips through a JSON encode/decode so the
    /// `JSONSchemaValue` tree emerges as a plain dictionary/array graph —
    /// `JSONSerialization` accepts only Foundation primitives and chokes on
    /// the enum otherwise.
    static func encodeToolDefinition(_ tool: ToolDefinition) -> [String: Any] {
        var function: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
        ]
        if let parameters = Self.foundationJSON(from: tool.parameters) {
            function["parameters"] = parameters
        } else {
            function["parameters"] = ["type": "object", "properties": [String: Any]()]
        }
        return [
            "type": "function",
            "function": function,
        ]
    }

    /// Serialise a ``ToolAwareHistoryEntry`` into Ollama's message shape.
    ///
    /// Assistant entries with `toolCalls` get a `tool_calls` array; tool-role
    /// entries get `tool_call_id`. Plain turns collapse to the same
    /// `{role, content}` shape the classic history path produces.
    static func encodeToolAwareEntry(_ entry: ToolAwareHistoryEntry) -> [String: Any] {
        var obj: [String: Any] = [
            "role": entry.role,
            "content": entry.content,
        ]
        if let calls = entry.toolCalls, !calls.isEmpty {
            obj["tool_calls"] = calls.map(Self.encodeToolCall)
        }
        if let callId = entry.toolCallId {
            obj["tool_call_id"] = callId
        }
        return obj
    }

    /// Serialise a single ``ToolCall`` into the OpenAI streaming-compatible
    /// shape Ollama uses in `message.tool_calls`.
    ///
    /// Ollama's server validator parses `arguments` as a JSON object when the
    /// tool call is fed back in an assistant history entry, so we
    /// re-hydrate the stored JSON string into a Foundation dictionary before
    /// emitting. When parsing fails we fall back to an empty object rather
    /// than shipping a malformed payload — the server will reject the
    /// request either way, and a clean empty-args call surfaces a more
    /// actionable error for the host.
    static func encodeToolCall(_ call: ToolCall) -> [String: Any] {
        let argumentsValue: Any = Self.parseArgumentString(call.arguments)
        return [
            "id": call.id,
            "type": "function",
            "function": [
                "name": call.toolName,
                "arguments": argumentsValue,
            ] as [String: Any],
        ]
    }

    /// Parse a `ToolCall.arguments` JSON string into the primitive graph
    /// Ollama expects inside an assistant `tool_calls[]` entry. Falls back
    /// to an empty object with a log warning on malformed input rather than
    /// swallowing the error.
    static func parseArgumentString(_ arguments: String) -> Any {
        guard let data = arguments.data(using: .utf8) else {
            Log.inference.warning(
                "OllamaBackend: tool arguments string was not valid UTF-8 — substituting empty object in history."
            )
            return [String: Any]()
        }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            Log.inference.warning(
                "OllamaBackend: tool arguments string was not valid JSON — substituting empty object in history. error=\(error.localizedDescription, privacy: .public)"
            )
            return [String: Any]()
        }
    }

    /// Decode one `tool_calls[]` entry from a parsed NDJSON line.
    ///
    /// Ollama's streaming format follows the OpenAI shape:
    /// `{id, type: "function", function: {name, arguments}}`. The `arguments`
    /// field is sometimes a JSON string (the documented wire shape) and
    /// sometimes a pre-parsed dictionary (observed on some Ollama builds);
    /// the decoder handles both and always produces a ``ToolCall`` whose
    /// `arguments` property is a valid JSON string.
    ///
    /// `id` is optional on the wire — some Ollama builds omit it for the
    /// first tool call in a turn. Synthesise a deterministic fallback from
    /// the tool name plus a counter suffix when absent so downstream
    /// call/result pairing still works.
    static func decodeToolCall(_ raw: [String: Any]) -> ToolCall? {
        // Two observed shapes on the wire:
        //   A) {id, type: "function", function: {name, arguments}}  — documented
        //   B) {id, name, arguments}                                 — some 0.3.x builds
        // Prefer the nested `function` envelope; fall back to the flat shape
        // when it's absent so lenient Ollama forks still produce tool events.
        let nameSource: [String: Any]
        if let function = raw["function"] as? [String: Any] {
            nameSource = function
        } else {
            nameSource = raw
        }
        guard let name = nameSource["name"] as? String, !name.isEmpty else {
            return nil
        }

        let id: String
        if let wireId = raw["id"] as? String, !wireId.isEmpty {
            id = wireId
        } else {
            // Deterministic fallback: ids are only used for id→result pairing
            // inside one turn, so a name-based placeholder is sufficient.
            id = "ollama-\(name)-\(UUID().uuidString.prefix(8))"
        }

        let argumentsString: String
        if let raw = nameSource["arguments"] as? String {
            argumentsString = raw
        } else if let dict = nameSource["arguments"] as? [String: Any] {
            argumentsString = Self.serialiseArgumentDictionary(dict)
        } else {
            argumentsString = "{}"
        }

        return ToolCall(id: id, toolName: name, arguments: argumentsString)
    }

    /// Encode a ``JSONSchemaValue`` into the primitive graph
    /// `JSONSerialization` accepts. Returns `nil` if encoding fails — callers
    /// are expected to substitute a conservative default.
    ///
    /// Delegates to `encodeJSONSchemaToFoundation(_:)` in `BaseChatInference`
    /// so all backends share one implementation.
    static func foundationJSON(from value: JSONSchemaValue) -> Any? {
        encodeJSONSchemaToFoundation(value)
    }

    /// Serialise an already-parsed arguments dictionary to a JSON string,
    /// normalising Ollama builds that emit structured `arguments` instead of
    /// the documented stringified form. Falls back to `"{}"` when
    /// serialisation fails so ``ToolCall/arguments`` always contains valid
    /// JSON the registry can decode.
    static func serialiseArgumentDictionary(_ dict: [String: Any]) -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: dict)
            if let text = String(data: data, encoding: .utf8) {
                return text
            }
            Log.inference.warning(
                "OllamaBackend: tool arguments dictionary serialised to non-UTF8 bytes — substituting empty object."
            )
            return "{}"
        } catch {
            Log.inference.warning(
                "OllamaBackend: failed to serialise parsed tool arguments — substituting empty object. error=\(error.localizedDescription, privacy: .public)"
            )
            return "{}"
        }
    }

    // MARK: - ToolCallingHistoryReceiver

    public func setToolAwareHistory(_ messages: [ToolAwareHistoryEntry]) {
        withStateLock { self.toolAwareHistory = messages }
    }

    /// Extracts the assistant content token from an Ollama NDJSON line.
    ///
    /// Ollama streaming format (one JSON object per line, no `data:` prefix):
    /// ```json
    /// {"model":"llama3","message":{"role":"assistant","content":"Hello"},"done":false}
    /// ```
    /// Final chunk has `"done":true` and empty or absent content — we skip it.
    ///
    /// This method only surfaces visible content; reasoning-model `thinking`
    /// fields are handled inline by ``parseResponseStream(bytes:config:continuation:)``
    /// so they can be emitted as ``GenerationEvent/thinkingToken(_:)`` with
    /// proper ``GenerationEvent/thinkingComplete`` bracketing. Kept for the
    /// ``SSEPayloadHandler`` protocol conformance and external callers.
    static func extractToken(from json: String) -> String? {
        guard let parsed = parseLine(json) else { return nil }
        // Skip the final "done" chunk.
        if parsed.done { return nil }
        guard let content = parsed.content, !content.isEmpty else { return nil }
        return content
    }

    /// Extracts reasoning content from an Ollama NDJSON line, if any.
    ///
    /// Returns `nil` when the line carries no `thinking` field or an empty
    /// one. Exposed for symmetry with ``extractToken(from:)``; streaming
    /// callers use the inline logic in
    /// ``parseResponseStream(bytes:config:continuation:)`` to bracket
    /// thinking emissions with ``GenerationEvent/thinkingComplete``.
    static func extractThinking(from json: String) -> String? {
        guard let parsed = parseLine(json),
              let thinking = parsed.thinking,
              !thinking.isEmpty else {
            return nil
        }
        return thinking
    }

    /// Extracts an error message from an Ollama error response body.
    ///
    /// Ollama error format: `{"error":"model not found"}`
    private static func extractErrorMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = parsed["error"] as? String else {
            return nil
        }
        return message
    }

    // MARK: - SSE Payload Handler

    /// Ollama-specific ``SSEPayloadHandler`` for use with ``SSEStreamParser``.
    ///
    /// ``OllamaBackend`` overrides ``parseResponseStream(bytes:continuation:)``
    /// to handle NDJSON directly, so these methods are not called during normal
    /// operation. They are provided for completeness and external reuse.
    struct OllamaPayloadHandler: SSEPayloadHandler {
        func extractToken(from payload: String) -> String? {
            OllamaBackend.extractToken(from: payload)
        }

        /// Extracts Ollama's per-turn usage from a single NDJSON payload.
        ///
        /// Ollama's documented API places `eval_count` (completion tokens) and
        /// `prompt_eval_count` (prompt tokens) on the terminal `"done":true`
        /// line. Returns `nil` when neither field is present so partial/running
        /// lines don't pollute a consumer that expects "final usage only".
        func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? {
            guard let parsed = OllamaBackend.parseLine(payload) else { return nil }
            guard parsed.evalCount != nil || parsed.promptEvalCount != nil else {
                return nil
            }
            return (
                promptTokens: parsed.promptEvalCount,
                completionTokens: parsed.evalCount
            )
        }

        func isStreamEnd(_ payload: String) -> Bool { false }
        func extractStreamError(from payload: String) -> Error? { nil }
    }

    // MARK: - Unload

    public override func unloadModel() {
        super.unloadModel()
    }
}
#endif

