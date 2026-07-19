import Foundation

// MARK: - Supporting Protocols for Backend Opt-In Capabilities

/// Adopted by backends that can vend a synchronous ``TokenizerProvider``.
///
/// Use this when a backend has an efficient, thread-safe tokenizer available after
/// model load. Backends whose tokenizer requires `async` access should not conform.
public protocol TokenizerVendor: AnyObject {
    var tokenizer: any TokenizerProvider { get }
}

/// One turn in a structured conversation history — a role plus an ordered
/// list of ``MessagePart`` values.
///
/// This is the inference-layer companion to `ChatMessage`: it strips
/// persistence-only fields (timestamp, sessionID, token counts) and exposes
/// just what the generation pipeline needs to format prompts and serialize
/// provider-specific request bodies. Crucially, ``parts`` retains
/// ``MessagePart/thinking(_:signature:)`` blocks with their provider
/// signatures intact so multi-turn replay against APIs that require the
/// signature verbatim (Anthropic extended thinking) works on the second
/// turn and beyond.
///
/// Text-only backends collapse a ``StructuredMessage`` back to
/// `(role, content)` at their boundary — see
/// `GenerationQueue` for the flattening rule (text parts joined,
/// thinking parts dropped from the prompt).
public struct StructuredMessage: Sendable, Hashable {

    /// `"user"`, `"assistant"`, `"system"`, or `"tool"`.
    public let role: String

    /// Ordered content parts for this turn. May contain text, thinking
    /// blocks (with optional signatures), images, and tool calls / results.
    public let parts: [MessagePart]

    public init(role: String, parts: [MessagePart]) {
        self.role = role
        self.parts = parts
    }

    /// Convenience constructor for a plain text turn.
    public init(role: String, content: String) {
        self.role = role
        self.parts = [.text(content)]
    }

    /// Plain-text projection used by text-only backends. Concatenates every
    /// `.text` part in order and drops every other part type.
    ///
    /// Thinking blocks are intentionally excluded: they would either be
    /// double-counted against the context window or leak provider-internal
    /// reasoning into prompts that the wire format does not natively
    /// support. Backends that want to replay thinking read ``parts`` directly
    /// off the ``GenerationRuntimeHints/history`` entries instead.
    public var textContent: String {
        parts.compactMap(\.textContent).joined()
    }
}

/// One entry in a tool-aware conversation history.
///
/// Extends the plain `(role, content)` history shape with the tool-calling
/// fields the Ollama and OpenAI-compatible `/api/chat` wire contracts require:
///
/// - `toolCalls` — attached to `role: "assistant"` entries that preceded a
///   tool invocation. Each element carries the backend-assigned call id,
///   the tool name, and the raw JSON arguments string the model emitted.
/// - `toolCallId` — attached to `role: "tool"` entries that feed a
///   ``ToolResult`` back into the conversation. Must match the corresponding
///   ``ToolCall/id`` so the server can thread the result into the right slot.
///
/// Plain text turns leave both fields `nil`; the adapter collapses back to
/// the classic `(role, content)` shape when no tool context is present.
public struct ToolAwareHistoryEntry: Sendable, Equatable, Hashable {

    /// `"user"`, `"assistant"`, `"system"`, or `"tool"`.
    public let role: String

    /// Visible message content. Tool calls still carry an empty string here
    /// (the model's textual preamble, if any); tool results carry the
    /// serialised result payload.
    public let content: String

    /// Tool calls emitted by the model in this assistant turn, in emission
    /// order. `nil` on non-assistant turns or assistant turns without calls.
    public let toolCalls: [ToolCall]?

    /// Call id this tool-role entry responds to. `nil` on non-tool turns.
    public let toolCallId: String?

    public init(
        role: String,
        content: String,
        toolCalls: [ToolCall]? = nil,
        toolCallId: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }
}

// MARK: - History Projections

extension Array where Element == StructuredMessage {

    /// Flattens structured history to the legacy `(role, content)` shape for
    /// text-only wire encoders.
    ///
    /// **Lossy by design**: carries only `.text` parts. Thinking parts are
    /// dropped (they would bloat the prompt with provider-internal reasoning or
    /// fail validation on providers that don't accept replayed thinking);
    /// tool-call / tool-result / image parts are dropped because the string
    /// shape cannot represent them. Backends that need those shapes read the
    /// structured `self` or ``toolAwareHistory`` instead.
    public var flattenedHistory: [(role: String, content: String)] {
        map { (role: $0.role, content: $0.textContent) }
    }

    /// Projects structured history to the tool-aware wire shape
    /// (``ToolAwareHistoryEntry``) for the Ollama / OpenAI-compatible
    /// `/api/chat` contracts.
    ///
    /// A `StructuredMessage` reaching this projection can carry a tool turn in
    /// either of two shapes:
    ///
    /// - **Split** — a dedicated `role: "assistant"` message holding only
    ///   `.toolCall` part(s), and a separate `role: "tool"` message holding one
    ///   `.toolResult` part. This is what the in-process tool-dispatch loop and
    ///   the server's per-request wire messages produce.
    /// - **Combined** — one `role: "assistant"` message carrying its
    ///   `.toolCall`(s), the resulting `.toolResult`(s), and the model's final
    ///   `.text` answer together. This is what a *persisted* tool turn replays
    ///   as: ``TurnStreamFinalizer`` appends call/result parts onto the same
    ///   ``ChatMessage`` as it streams, then writes the turn's one accumulated
    ///   answer as a single trailing `.text` part.
    ///
    /// Both shapes fan out to the same wire-correct sequence — one
    /// `role: "assistant"` entry carrying every `toolCalls` in the message
    /// (content empty; a combined message's own text is not a pre-call
    /// preamble, it is the *post-result* answer, see below), one
    /// `role: "tool"` entry per `.toolResult` (content = the result payload,
    /// `toolCallId` = the result's ``ToolResult/callId``), and — only for a
    /// combined message whose accumulated text is non-empty — a trailing
    /// `role: message.role` entry carrying that text. A message with neither
    /// calls nor results projects 1:1 to `(role, textContent)` as before.
    ///
    /// Emitting the tool_calls entry and the tool-result entry(ies) as
    /// *separate* wire messages (rather than one entry carrying both
    /// `toolCalls` and `toolCallId`) is required for correctness: OpenAI /
    /// Claude / OpenAI Responses reject an assistant message whose
    /// `tool_calls` aren't followed by matching `tool`-role messages, and
    /// stuffing the result payload into the same entry's `content` overwrites
    /// the model's real answer with the tool's raw output (#2312 follow-up).
    public var toolAwareHistory: [ToolAwareHistoryEntry] {
        flatMap { message -> [ToolAwareHistoryEntry] in
            var toolCalls: [ToolCall] = []
            var toolResults: [ToolResult] = []
            for part in message.parts {
                switch part {
                case .toolCall(let call):
                    toolCalls.append(call)
                case .toolResult(let result):
                    toolResults.append(result)
                case .text, .thinking, .image, .audio, .generatedMedia:
                    break
                }
            }

            guard !toolResults.isEmpty else {
                // No results on this turn: a plain turn, or a split-shape
                // assistant turn that only issued calls. One entry, as before.
                return [
                    ToolAwareHistoryEntry(
                        role: message.role,
                        content: message.textContent,
                        toolCalls: toolCalls.isEmpty ? nil : toolCalls,
                        toolCallId: nil
                    )
                ]
            }

            var entries: [ToolAwareHistoryEntry] = []
            if !toolCalls.isEmpty {
                entries.append(
                    ToolAwareHistoryEntry(
                        role: message.role,
                        content: "",
                        toolCalls: toolCalls,
                        toolCallId: nil
                    )
                )
            }
            entries.append(contentsOf: toolResults.map { result in
                ToolAwareHistoryEntry(
                    role: "tool",
                    content: result.content,
                    toolCalls: nil,
                    toolCallId: result.callId
                )
            })
            let finalText = message.textContent
            if !finalText.isEmpty {
                entries.append(
                    ToolAwareHistoryEntry(
                        role: message.role,
                        content: finalText,
                        toolCalls: nil,
                        toolCallId: nil
                    )
                )
            }
            return entries
        }
    }

    /// True when any turn carries a tool call or tool result part — i.e. the
    /// history needs the tool-aware wire encoding rather than the plain
    /// `(role, content)` fallback.
    public var containsToolParts: Bool {
        contains { message in
            message.parts.contains { part in
                switch part {
                case .toolCall, .toolResult: return true
                default: return false
                }
            }
        }
    }

    /// True when any turn carries an image part — i.e. the history must use a
    /// multimodal wire encoding rather than the text-only fallback.
    public var containsImages: Bool {
        contains { message in
            message.parts.contains { part in
                if case .image = part { return true }
                return false
            }
        }
    }
}

/// Adopted by cloud backends that track token usage per response.
public protocol TokenUsageProvider: AnyObject {
    var lastUsage: (promptTokens: Int, completionTokens: Int)? { get }
}

/// Adopted by endpoint-based backends configured with endpoint URL + model name.
public protocol EndpointBackendURLModelConfigurable: AnyObject {
    func configure(baseURL: URL, modelName: String)
}

/// Adopted by endpoint-based backends that resolve API keys via a Keychain account.
public protocol EndpointBackendKeychainConfigurable: AnyObject {
    func configure(baseURL: URL, keychainAccount: String, modelName: String)
}

/// Adopted by backends whose *residency* is advisory — owned by a remote server
/// the engine cannot directly evict (e.g. Ollama keeps a model resident in VRAM
/// server-side and unloads it on its own `keep_alive` timer).
///
/// ## Owned vs advisory residency
///
/// ``InferenceService``'s ``KeepAlivePolicy`` governs **owned** (in-process)
/// residency: when its idle timer fires the engine actually frees the model.
/// For a server-side backend the engine cannot do that — it can only *advise*
/// the server how long to keep the model loaded after the last request. This
/// protocol is the bridge: the coordinator translates the owned policy's
/// `idleTimeout` into the backend's server-side hint so the two horizons agree
/// instead of diverging (an in-process 5-minute policy paired with Ollama's
/// independent 30-minute default would otherwise hold VRAM long after MK
/// considers the model idle).
public protocol AdvisoryResidencyConfigurable: AnyObject {
    /// Advises the backend's server-side keep-alive horizon.
    ///
    /// - Parameter idleTimeout: The owned policy's idle timeout in seconds, or
    ///   `nil` for ``KeepAlivePolicy/never`` (the backend should apply its own
    ///   default residency in that case — no advice is given).
    func applyAdvisoryKeepAlive(idleTimeout: TimeInterval?)
}

/// Adopted by backends that can report granular model-load progress.
///
/// `InferenceService` installs a handler before each load and clears it
/// (`nil`) once the load has completed or failed. Handlers may be invoked
/// from any thread; the closure is `@Sendable`. Backends without granular
/// progress need not adopt this protocol — `InferenceService` will simply
/// publish `0.0` until `isModelLoaded` flips to `true`.
public protocol LoadProgressReporting: AnyObject {
    /// Installs (or clears, when `nil`) a progress callback for the next
    /// `loadModel` call. Values must be in `[0.0, 1.0]`. Implementations
    /// should retain the handler only for the duration of the active load.
    func setLoadProgressHandler(_ handler: (@Sendable (Double) async -> Void)?)
}

/// Adopted by local backends that can count tokens exactly using their loaded vocabulary.
///
/// Non-local backends (cloud, Ollama) should not conform — they have no
/// local tokenizer. `GenerationQueue` gates the exact pre-flight
/// check on this protocol so the trim-and-retry path only activates for
/// backends where KV cache overflow is a real concern.
///
/// - Note: `countTokens` must only be called after the model is loaded.
///   Implementations throw ``InferenceError/modelNotFound(path:)`` when invoked
///   on an unloaded backend.
public protocol TokenCountingBackend: AnyObject {
    /// Returns the exact token count for `text` using the loaded model's vocabulary.
    ///
    /// - Throws: ``InferenceError/inferenceFailure(_:)`` if the model is not loaded,
    ///   or if tokenization fails (e.g., vocabulary is unavailable).
    func countTokens(_ text: String) throws -> Int
}

/// Adopted by backends whose model load is a long-running, externally-driven
/// operation that a host may need to observe or cancel — primarily the local
/// llama.cpp/ggml family, whose load is a **blocking C call that ignores Swift
/// `Task` cancellation** and keeps mutating the backend on a background thread
/// even after the awaiting Swift call site has thrown or been cancelled.
///
/// ## The hazard this addresses
///
/// `InferenceBackend/loadModel(from:plan:)` is `async`, so a host can wrap it
/// in a deadline (`Task` timeout / `withDeadline`). When that deadline fires,
/// the Swift continuation resumes with a `CancellationError`, **but the native
/// load underneath does not stop** — for the llama.cpp/ggml backend it is a
/// synchronous C call that builds and swaps graph/backend state on a worker
/// thread with no cooperative cancellation point. The Swift side believes the
/// load is over; the native side is still writing into the backend.
///
/// If a *second* operation then touches the backend while that orphaned native
/// load is still in flight — a retry `loadModel`, or an autonomous
/// `generate()` / `llama_decode` — the process **SIGSEGVs inside
/// `ggml_backend_graph_compute_async`**, because two threads are mutating the
/// same backend graph. (Seen downstream: Idlewick #315 / PR #347.)
///
/// Without this protocol a host's only mitigation is a *coarse latch*: set a
/// flag for the entire opaque duration of `loadModel` and refuse every other
/// load/decode until it returns — defensively serialising around a thread it
/// can neither observe nor cancel, and over-blocking whenever the Swift await
/// returns early.
///
/// ## What adopting this protocol buys the host
///
/// - ``isModelLoadInFlight`` lets the host **observe** whether a native load is
///   still mutating the backend, rather than inferring it from the (possibly
///   already-resumed) `loadModel` await.
/// - ``cancelModelLoad()`` lets the host **request** that an in-flight load
///   unwind — best-effort and cooperative (see below).
/// - ``awaitModelLoadSettled()`` lets the host **latch precisely**: await the
///   true completion of any in-flight native load before it tears the backend
///   down or issues the next load/decode, instead of guessing with a timer.
///
/// Backends that do not adopt this protocol leave hosts on the coarse-latch
/// fallback — correct, just conservative.
///
/// ## Best-effort cancellation
///
/// ``cancelModelLoad()`` is a **request**, not a guarantee. The underlying
/// runtime may have no interruption point mid-graph-build, in which case the
/// load runs to completion regardless and `cancelModelLoad()` only shortens the
/// window where one exists (e.g. between sub-steps the backend polls a flag).
/// Hosts must therefore still pair a cancel with ``awaitModelLoadSettled()``
/// before reusing or freeing the backend — cancel asks it to stop *sooner*,
/// settle tells you it has *actually* stopped. Never touch the backend (retry
/// load / decode / unload) while ``isModelLoadInFlight`` is `true`.
///
/// ## Thread safety
///
/// All three members may be called from any thread (the same `Task.detached`
/// load-dispatch contract as ``InferenceBackend``). Conformers with mutable
/// in-flight state must synchronise it (lock or actor) — the flag is read from
/// the host's actor while the native load writes it from a worker thread.
///
/// - Note: This is the core API *seam* only. Wiring it into the concrete
///   `LlamaBackend` native unwind (a cancel flag the load loop polls, plus the
///   settled signal fired from the C completion point) is a follow-up in the
///   `manifold-llama` companion repo.
public protocol CancellableModelLoading: AnyObject {
    /// Whether a native model load is currently in flight — i.e. still
    /// potentially mutating the backend on a background thread.
    ///
    /// This is **independent** of the `async` `loadModel` await: it stays
    /// `true` from the moment the native load begins mutating state until that
    /// native work has truly finished, which may be *after* the Swift
    /// `loadModel` continuation has already resumed (e.g. via a fired deadline).
    /// A host must treat any backend access as unsafe while this is `true`.
    ///
    /// Read from the host's actor while the load thread writes it; conformers
    /// must publish it under their own synchronisation.
    var isModelLoadInFlight: Bool { get }

    /// Requests that an in-flight model load unwind as soon as possible.
    ///
    /// **Best-effort and cooperative.** The native load may not be interruptible
    /// mid-graph-build; in that case this call sets the intent and the load
    /// still runs to completion. It is a no-op when no load is in flight.
    /// Always follow with ``awaitModelLoadSettled()`` before reusing or freeing
    /// the backend — cancel does not by itself mean the native work has stopped.
    func cancelModelLoad()

    /// Suspends until any in-flight native load has **truly finished** — whether
    /// it completed normally, failed, or unwound in response to
    /// ``cancelModelLoad()``.
    ///
    /// Returns immediately when no load is in flight. This is the precise latch
    /// a host awaits before tearing the backend down or issuing the next
    /// load/decode, replacing the coarse "refuse everything for the opaque
    /// duration" mitigation. After it returns, ``isModelLoadInFlight`` is
    /// `false` and the backend is safe to touch.
    func awaitModelLoadSettled() async
}

/// Adopted by local backends that support a multimodal projector (mmproj) companion file.
///
/// `ModelLifecycleCoordinator` calls ``setMmprojURL(_:)`` with the URL from
/// ``ModelInfo/mmprojURL`` before each ``InferenceBackend/loadModel(from:plan:)`` call.
/// Conformers should set ``BackendCapabilities/supportsVision`` to `true` only
/// once they can translate ``MessagePart/image(data:mimeType:placeholderHash:)`` into backend
/// image embeddings, not merely because a projector URL is present.
///
/// - Note: Passing `nil` clears the projector, returning the backend to text-only mode.
///   `ModelLifecycleCoordinator` always calls this before load so the projector state
///   stays in sync with the loaded model file.
public protocol MultimodalProjectorConfigurable: AnyObject {
    /// Sets (or clears) the mmproj companion file URL for the next ``InferenceBackend/loadModel(from:plan:)`` call.
    func setMmprojURL(_ url: URL?)
}
