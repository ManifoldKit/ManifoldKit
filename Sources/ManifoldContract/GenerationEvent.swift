/// Events emitted by inference backends during text generation.
///
/// Replaces the raw `String` token stream to support usage reporting and
/// future structured output without breaking the `InferenceBackend`
/// contract again.
///
/// ## Vocabulary freeze (1.0)
///
/// The tool-call event vocabulary is locked as of the 1.0 release. Key design
/// decisions recorded here for Wave 3 consumers:
///
/// ### Queue-emitted lifecycle events
///
/// ``toolDispatchStarted(callId:name:attempt:)`` and
/// ``toolDispatchCompleted(callId:durationMilliseconds:errorKind:)`` are emitted by the
/// **queue** (`GenerationQueue`), not by individual backends.
/// Backends emit only ``toolCall(_:)`` (and, when
/// streaming, ``toolCallStart(callId:name:)`` and
/// ``toolCallArgumentsDelta(callId:textDelta:)``). Consumers driving generation
/// through `InferenceService` / `GenerationQueue` that reconstruct
/// timelines or present per-call spinners should key on these queue events,
/// not on the backend streaming events.
///
/// ### `.toolCallNameDelta` is intentionally absent
///
/// There is no streaming name-delta event. Backends **must** emit the tool name
/// up-front and complete in ``toolCallStart(callId:name:)`` and
/// ``toolCall(_:)``. Grammar-constrained backends (Llama/Gemma-4 GBNF) are
/// required to buffer output until the name token sequence is complete before
/// emitting. This keeps consumers simple: the name is always final on first
/// observation.
///
/// ### Source compatibility for pattern-match consumers
///
/// Adding new cases to this enum is source-breaking for exhaustive `switch`
/// statements. New lifecycle payloads should prefer associated structs (as
/// ``ToolProgressEvent`` does) so adding fields later can be source-compatible,
/// but the initial enum case still requires exhaustive switches to add a case,
/// `default:`, or `@unknown default:` arm.
public enum GenerationEvent: Sendable, Equatable {
    /// Progress update while the backend is evaluating prompt tokens before the
    /// first generated content token is available.
    ///
    /// `tokensProcessed` is how many prompt tokens have been evaluated so far,
    /// `tokensTotal` is the total prompt-token count for this request, and
    /// `tokensPerSecond` is the backend-reported prompt-eval throughput.
    case prefillProgress(tokensProcessed: Int, tokensTotal: Int, tokensPerSecond: Double)

    /// A fragment of generated text (typically one token).
    case token(String)

    /// Token usage reported by the backend (cloud backends only today).
    case usage(prompt: Int, completion: Int)

    /// A tool invocation requested by the model.
    ///
    /// Backends that support tool calling (``BackendCapabilities/supportsToolCalling``)
    /// emit this event when the model decides to call a tool defined in
    /// ``GenerationConfig/tools``.  The host is responsible for executing the
    /// call and feeding a ``ToolResult`` back into the conversation.
    case toolCall(ToolCall)

    /// Streaming start of a tool call. `callId` matches ``ToolCall/id`` of the
    /// corresponding ``toolCall(_:)`` event later in this round; `name` is
    /// final (no `.toolCallNameDelta` exists — providers emit name up front).
    ///
    /// Backends only emit this when
    /// ``BackendCapabilities/streamsToolCallArguments`` is `true`. Backends
    /// that produce whole calls (MLX inline parser, Ollama non-streaming)
    /// skip start/delta and emit only ``toolCall(_:)``.
    ///
    /// Contract: `callId` is non-empty, unique within a turn, and matches
    /// the id of the ``toolCall(_:)`` event that closes this stream.
    case toolCallStart(callId: String, name: String)

    /// JSON-arguments fragment for an in-flight call, emitted in
    /// concatenation order. Consumers may attempt forgiving partial-JSON
    /// parsing for progressive UI; the authoritative arguments string lands
    /// on the final ``toolCall(_:)`` event.
    case toolCallArgumentsDelta(callId: String, textDelta: String)

    /// A fragment of model reasoning (inside a thinking block). Streamed during generation.
    case thinkingToken(String)

    /// Reasoning block complete (depth 1→0 transition). Finalize accumulated thinking content.
    case thinkingCompleted

    /// Provider-supplied opaque signature attached to the most recent
    /// thinking block. Emitted by backends (Anthropic) whose APIs require
    /// the signature verbatim on multi-turn replay.
    ///
    /// Fired between the block's `content_block_start` and the first
    /// `content_block_delta`, before any ``thinkingToken`` events for the
    /// same block. Consumers attach the signature to the in-flight
    /// reasoning accumulator so it lands on the persisted
    /// ``MessagePart/thinking(_:signature:)`` part once
    /// ``thinkingCompleted`` arrives. Backends without a signature concept
    /// (MLX inline `<think>`, OpenAI `reasoning_content`, Llama) never
    /// emit this event.
    case thinkingSignature(String)

    /// The orchestrator terminated a tool-dispatch loop because the per-request
    /// iteration budget (``GenerationConfig/maxToolIterations``) was reached.
    ///
    /// Emitted exactly once per turn when the loop stops for this reason. The
    /// associated value is the iteration count that ran before termination, so
    /// UI surfaces can differentiate a budget hit from an organic stop.
    case toolIterationLimitExceeded(iterations: Int)

    /// Result of a tool dispatched by the orchestrator in response to a
    /// ``toolCall(_:)`` event.
    ///
    /// Emitted after the coordinator has routed a ``ToolCall`` through the
    /// registered ``ToolRegistry`` and produced a ``ToolResult``. Downstream
    /// consumers (chat UIs, transcripts) use this to append the tool result to
    /// the assistant turn before the next generation round begins.
    case toolResult(ToolResult)

    /// Interim progress from a streaming tool executor.
    ///
    /// Emitted between ``toolDispatchStarted(callId:name:attempt:)`` and the
    /// terminal ``toolResult(_:)`` when the registered ``ToolExecutor`` yields
    /// ``ToolExecutionEvent/progress(message:fraction:)`` values from
    /// ``ToolExecutor/executeStreaming(arguments:)``. `callId` and `name` are
    /// stamped by the orchestrator from the model-emitted ``ToolCall`` so
    /// progress remains attributable even when an executor emits an empty or
    /// stale terminal result id.
    case toolProgress(ToolProgressEvent)

    /// Emitted at the start of a turn when the backend reused a KV-cache prefix
    /// from the previous turn. `promptTokensReused` is the number of prompt tokens
    /// whose KV state was preserved, saving their re-decode cost.
    case kvCacheReuse(promptTokensReused: Int)

    /// Emitted by the orchestrator when generation has been paused for a
    /// runtime-side condition (e.g. `ProcessInfo.thermalState == .critical`).
    ///
    /// Fired exactly once per pause cycle — on entry into the wait loop, not
    /// on every re-check tick. UI surfaces can use this to show a "device
    /// throttling — paused" hint while the loop blocks between tokens.
    /// `reason` is a short, human-readable string the UI may display verbatim.
    case throttleDiagnostic(reason: String)

    /// Emitted by the orchestrator immediately before it begins handling a
    /// model-emitted ``ToolCall``.
    ///
    /// Fires after the corresponding ``toolCall(_:)`` event and before the
    /// matching ``toolResult(_:)``, giving UI surfaces a precise "running"
    /// boundary they can pin a spinner / start timer to without scraping
    /// logs. This lifecycle covers the coordinator's full handling path for
    /// the call, not only successful routing through the registered
    /// ``ToolRegistry``: approval gating, registry execution, and synthesized
    /// non-dispatch outcomes (for example approval denial, identical-call
    /// short-circuiting, or byte-budget exhaustion) are all included.
    /// `callId` matches ``ToolCall/id``; `name` is the tool name; `attempt`
    /// is the 1-based handling attempt for this call (always `1` today —
    /// reserved for future retry semantics).
    case toolDispatchStarted(callId: String, name: String, attempt: Int)

    /// Emitted by the orchestrator at the moment a model-emitted tool call
    /// clears the approval gate and is about to be executed.
    ///
    /// Fires after ``toolDispatchStarted(callId:name:attempt:)`` and before the
    /// matching ``toolResult(_:)``, but ONLY on paths where the call is
    /// genuinely approved: auto-approval (the tool does not require approval)
    /// or an explicit `.approved` verdict from the ``ToolApprovalGate``. It is
    /// deliberately NOT emitted for non-approval outcomes —
    /// approval-gate denial, pre-tool-use-hook block, identical-call
    /// short-circuiting, or byte-budget exhaustion — so consumers can treat
    /// this as the authoritative "approved, executing" signal rather than
    /// scraping it out of `.toolDispatchStarted` (which also covers denied
    /// calls). `callId` matches ``ToolCall/id``.
    case toolCallApproved(callId: String)

    /// Emitted by the orchestrator after tool-call handling settles,
    /// regardless of outcome.
    ///
    /// Fires after the matching ``toolResult(_:)`` event. `durationMilliseconds` is the
    /// monotonic handling latency in milliseconds (>= 0), measured from
    /// ``toolDispatchStarted(callId:name:attempt:)`` to this event with a
    /// monotonic clock so wall-clock adjustments (NTP, user time changes) do
    /// not skew the value. It covers the full orchestrator-managed lifecycle
    /// for the call, including any approval-gate wait time and paths that do
    /// not invoke the registered ``ToolRegistry`` because the coordinator
    /// synthesized the result. `errorKind` carries the failure classification
    /// when handling produced an error result and `nil` on success — its
    /// value matches the ``ToolResult/errorKind`` of the `.toolResult` event
    /// with the same `callId`.
    case toolDispatchCompleted(callId: String, durationMilliseconds: Int, errorKind: ToolResult.ErrorKind?)

    /// The orchestrator detected a synthetic `transfer_to_<agent>` tool call
    /// and classified it as an agent handoff. Emitted in lieu of the regular
    /// ``toolCall(_:)`` / ``toolResult(_:)`` pair — the dispatch loop
    /// short-circuits regular tool dispatch and lets the runtime swap the
    /// active agent and inject a boundary message into the next turn.
    ///
    /// Only emitted by ``GenerationToolDispatchLoop`` when it has been
    /// configured with a session-aware handoff detector; backends never emit
    /// this case directly.
    case handoffRequested(AgentHandoff)
}

/// Payload for ``GenerationEvent/toolProgress(_:)``.
///
/// Kept as a struct rather than several enum associated values so future
/// additive fields can grow through defaulted initializer parameters without
/// forcing every consumer that already handles `.toolProgress(let progress)` to
/// rewrite its pattern.
public struct ToolProgressEvent: Sendable, Equatable, Hashable {
    /// ``ToolCall/id`` of the in-flight call.
    public let callId: String

    /// ``ToolCall/toolName`` for display and grouping.
    public let name: String

    /// Human-readable status from the executor.
    public let message: String

    /// Optional 0.0...1.0 completion fraction, or `nil` when the total is
    /// unknown.
    public let fraction: Double?

    public init(
        callId: String,
        name: String,
        message: String,
        fraction: Double? = nil
    ) {
        self.callId = callId
        self.name = name
        self.message = message
        self.fraction = fraction
    }
}
