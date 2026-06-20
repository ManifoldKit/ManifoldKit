/// Events emitted by inference backends during text generation.
///
/// Replaces the raw `String` token stream to support usage reporting and
/// future structured output without breaking the `InferenceBackend`
/// contract again.
///
/// ## Vocabulary freeze (1.0)
///
/// **The entire `GenerationEvent` vocabulary is frozen as of the 1.0 release** —
/// not just the tool-call sub-vocabulary. The set of cases is the stable cross-
/// module contract every backend emits and every consumer switches over; adding
/// a case is source-breaking for exhaustive `switch` statements (see "Source
/// compatibility for pattern-match consumers" below), so new cases land only in
/// a major (`feat!:`) release. Public-facing / cross-module consumers should add
/// an `@unknown default:` arm to stay resilient to a future major.
///
/// The two non-fatal tool-call diagnostics —
/// ``toolCallParseFailed(rawBody:)`` and ``toolCallTruncated(rawBody:)`` — are
/// part of this frozen vocabulary. They were the last pre-1.0 additions
/// (`feat!:`, #1857 / #1858): a delimited tool-call body that fails to parse,
/// and an unterminated tool block surfaced at finalize, are now observable
/// instead of being silently dropped. Both follow the
/// ``throttleDiagnostic(reason:)`` precedent — advisory metadata with no
/// chat-message state mutation.
///
/// Payloads that are expected to grow are modelled as **associated structs**
/// rather than bare enum parameters so their fields can grow non-breakingly
/// after the freeze:
///
/// - ``ToolProgressEvent`` — payload of ``toolProgress(_:)``.
/// - ``TokenUsage`` — payload of ``usage(_:)``. Carried as a struct precisely so
///   future token-accounting fields (cached-prompt tokens, reasoning tokens,
///   tool-overhead tokens) can arrive as defaulted init parameters without
///   forcing every `.usage(let usage)` consumer to rewrite its pattern.
///
/// Key design decisions recorded here for Wave 3 consumers:
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

    /// The fully-assembled prompt text that was submitted to the backend for
    /// this generation turn, including the system prompt, conversation history,
    /// and any tool definitions that were injected.
    ///
    /// **Opt-in only.** Emitted by the orchestration layer immediately before
    /// the first ``prefillProgress`` or ``token`` event, and only when
    /// ``GenerationConfig/captureRenderedPrompt`` is `true`. Off by default to
    /// avoid unintentional retention of sensitive prompt content.
    ///
    /// For backends that use a prompt-template (local GGUF, MLX), `text` is
    /// the formatted string passed to
    /// ``InferenceBackend/generate(prompt:systemPrompt:config:)``.
    /// For cloud backends (which receive history as a message array on the wire),
    /// `text` is the most-recent user message content — the value passed as
    /// `prompt:`. The full conversation history is encoded on the wire and is
    /// not available as a single rendered string.
    ///
    /// Consumers that do not opt in will never observe this case. This is
    /// advisory metadata with no chat-message state mutation.
    case promptRendered(text: String)

    /// A fragment of generated text (typically one token).
    case token(String)

    /// Token usage reported by the backend (cloud backends only today).
    ///
    /// Carries a ``TokenUsage`` struct rather than bare `prompt`/`completion`
    /// parameters so future token-accounting fields can grow without breaking
    /// exhaustive consumers — see the "Vocabulary freeze (1.0)" note above.
    case usage(TokenUsage)

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
    /// `content_block_delta`, before any `thinkingToken` events for the
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

    /// The orchestrator terminated a tool-dispatch loop because the cumulative
    /// token spend across iterations reached the per-request run-level budget
    /// (``GenerationConfig/maxRunTokens``).
    ///
    /// Emitted at most once per turn, at the tool-iteration boundary (after a
    /// generation's terminal usage lands, before the next generation is
    /// dispatched). `tokensUsed` is the running prompt + completion total that
    /// met or exceeded the ceiling; `limit` is the configured budget. UI
    /// surfaces can use this to distinguish a budget abort from an organic stop
    /// or an iteration-count abort (``toolIterationLimitExceeded(iterations:)``).
    case runTokenBudgetExceeded(tokensUsed: Int, limit: Int)

    /// Result of a tool dispatched by the orchestrator in response to a
    /// ``toolCall(_:)`` event.
    ///
    /// Emitted after the coordinator has routed a ``ToolCall`` through the
    /// registered `ToolRegistry` and produced a ``ToolResult``. Downstream
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
    ///
    /// The byte-exact reuse semantics (and the #1382 stale-snapshot race
    /// regression guards, formerly `KVCacheReuseRaceRegressionTests` in
    /// `ManifoldBackendsTests`) are owned by the backend families: see the
    /// manifold-mlx / manifold-llama companion packages (v0.48, PR C2,
    /// #1749). Core only defines the event shape.
    case kvCacheReuse(promptTokensReused: Int)

    /// Emitted by the orchestrator when generation has been paused for a
    /// runtime-side condition (e.g. `ProcessInfo.thermalState == .critical`).
    ///
    /// Fired exactly once per pause cycle — on entry into the wait loop, not
    /// on every re-check tick. UI surfaces can use this to show a "device
    /// throttling — paused" hint while the loop blocks between tokens.
    /// `reason` is a short, human-readable string the UI may display verbatim.
    case throttleDiagnostic(reason: String)

    /// Non-fatal diagnostic: a delimited tool-call block closed, but its body
    /// failed to parse into a ``ToolCall`` (the dialect's `parseBody` returned
    /// `nil`).
    ///
    /// Emitted by ``ToolCallTransform`` in lieu of a ``toolCall(_:)`` event when
    /// a well-formed open/close marker pair surrounds a body the dialect parser
    /// rejects (malformed JSON, unknown shape, empty name). Without this event a
    /// broken tool call vanishes silently and the host cannot distinguish
    /// "model emitted a broken tool call" from "model emitted no tool call".
    /// `rawBody` is the exact buffered body text between the open and close
    /// markers so hosts can log, surface, or attempt their own recovery. This is
    /// advisory metadata — like ``throttleDiagnostic(reason:)`` it carries no
    /// chat-message state mutation and consumers that do not care may ignore it.
    case toolCallParseFailed(rawBody: String)

    /// Non-fatal diagnostic: the stream ended while a tool-call block was still
    /// open (no matching close marker arrived before `finalize()`).
    ///
    /// Emitted by ``ToolCallTransform/finalize()`` **only when the transform was
    /// constructed with `surfaceTruncatedToolBody: true`** (the default keeps
    /// the historical silent-discard behavior). `rawBody` is the partial body
    /// buffered since the open marker, so a mid-tool-call stream truncation is
    /// observable rather than lost. Like ``toolCallParseFailed(rawBody:)`` this
    /// is advisory metadata with no chat-message state mutation.
    case toolCallTruncated(rawBody: String)

    /// Emitted by the orchestrator immediately before it begins handling a
    /// model-emitted ``ToolCall``.
    ///
    /// Fires after the corresponding ``toolCall(_:)`` event and before the
    /// matching ``toolResult(_:)``, giving UI surfaces a precise "running"
    /// boundary they can pin a spinner / start timer to without scraping
    /// logs. This lifecycle covers the coordinator's full handling path for
    /// the call, not only successful routing through the registered
    /// `ToolRegistry`: approval gating, registry execution, and synthesized
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
    /// or an explicit `.approved` verdict from the `ToolApprovalGate`. It is
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
    /// not invoke the registered `ToolRegistry` because the coordinator
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
    /// Only emitted by `GenerationToolDispatchLoop` when it has been
    /// configured with a session-aware handoff detector; backends never emit
    /// this case directly.
    case handoffRequested(AgentHandoff)

    /// Terminal "response finished" signal, emitted by the orchestrator exactly
    /// once per turn as the **last** event before the generation stream finishes.
    ///
    /// Today completion is observable only by the `AsyncThrowingStream` finishing
    /// or by polling `phase == .done`, which is awkward to race against the event
    /// iterator. This case gives UI / accessibility layers a single in-band
    /// "finished" signal they can drive a "response complete" announcement off of
    /// without racing the iterator against phase observation.
    ///
    /// Emitted by the orchestration layer in `ManifoldInference` (the same layer
    /// that emits ``toolDispatchStarted(callId:name:attempt:)`` and
    /// ``toolIterationLimitExceeded(iterations:)``), **not** by individual
    /// backends — companion backend families (MLX, llama.cpp) never emit it. The
    /// payload's ``GenerationCompletion/reason`` classifies why the turn ended;
    /// it is carried as a struct (per the "Vocabulary freeze (1.0)" note above)
    /// so future completion metadata can grow through defaulted initializer
    /// parameters without breaking exhaustive consumers.
    case generationCompleted(GenerationCompletion)
}

/// Payload for ``GenerationEvent/generationCompleted(_:)``.
///
/// Kept as a struct rather than a bare enum parameter so future additive
/// completion metadata (final token counts, stop-sequence text, finish
/// timestamps) can grow through defaulted initializer parameters without forcing
/// every consumer that already handles `.generationCompleted(let completion)` to
/// rewrite its pattern — see the "Vocabulary freeze (1.0)" note on
/// ``GenerationEvent``.
public struct GenerationCompletion: Sendable, Equatable {
    /// Why the turn ended.
    ///
    /// Modelled as a nested enum so the reason vocabulary is closed and
    /// exhaustively switchable by consumers that want to differentiate, for
    /// example, a budget hit from an organic stop.
    public enum Reason: Sendable, Equatable {
        /// The model reached a natural end of generation (stop token / organic
        /// completion). This is the default when no more specific reason applies.
        case stop

        /// Generation stopped because it hit the token / length limit.
        ///
        /// Only emitted where the orchestrator genuinely has length-stop
        /// information; otherwise an organic stop is reported as ``stop``.
        case length

        /// The orchestrator terminated a tool-dispatch loop because the
        /// per-request iteration budget (``GenerationConfig/maxToolIterations``)
        /// was reached. Pairs with the
        /// ``GenerationEvent/toolIterationLimitExceeded(iterations:)`` event
        /// emitted earlier in the same turn.
        case toolIterationLimit

        /// The orchestrator terminated a tool-dispatch loop because the
        /// cumulative token spend reached the per-request run-level budget
        /// (``GenerationConfig/maxRunTokens``). Pairs with the
        /// ``GenerationEvent/runTokenBudgetExceeded(tokensUsed:limit:)`` event
        /// emitted earlier in the same turn.
        case runTokenBudget

        /// Generation was cancelled (cooperative cancellation of the turn).
        case cancelled

        /// Generation terminated because an error was thrown during the turn.
        case error
    }

    /// Why the turn ended.
    public let reason: Reason

    public init(reason: Reason = .stop) {
        self.reason = reason
    }
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
