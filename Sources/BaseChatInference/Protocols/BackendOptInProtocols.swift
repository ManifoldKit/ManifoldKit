import Foundation

// MARK: - Supporting Protocols for Backend Opt-In Capabilities

/// Adopted by backends that can vend a synchronous ``TokenizerProvider``.
///
/// Use this when a backend has an efficient, thread-safe tokenizer available after
/// model load. Backends whose tokenizer requires `async` access should not conform.
public protocol TokenizerVendor: AnyObject {
    var tokenizer: any TokenizerProvider { get }
}

/// Adopted by cloud backends to receive the full conversation history for multi-turn support.
/// This avoids InferenceService having a hard dependency on specific backend types.
public protocol ConversationHistoryReceiver: AnyObject {
    func setConversationHistory(_ messages: [(role: String, content: String)])
}

/// One turn in a structured conversation history — a role plus an ordered
/// list of ``MessagePart`` values.
///
/// This is the inference-layer companion to ``ChatMessageRecord``: it strips
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
/// ``GenerationCoordinator`` for the flattening rule (text parts joined,
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
    /// support. Backends that want to replay thinking adopt
    /// ``StructuredHistoryReceiver`` instead and read ``parts`` directly.
    public var textContent: String {
        parts.compactMap(\.textContent).joined()
    }
}

/// Adopted by backends that can consume the full structured conversation
/// history — including thinking blocks with their provider signatures and
/// tool call / result parts.
///
/// ``GenerationCoordinator`` calls this in addition to (not instead of)
/// ``ConversationHistoryReceiver`` so backends can pick whichever shape
/// matches their wire format. The Anthropic backend reads the structured
/// form so it can serialize prior `thinking` content blocks with their
/// `signature` verbatim — required for multi-turn extended-thinking
/// requests. OpenAI-compatible reasoning APIs (DeepSeek, etc.) drop
/// thinking on replay and continue to read the flattened
/// ``ConversationHistoryReceiver`` form.
public protocol StructuredHistoryReceiver: AnyObject {
    func setStructuredHistory(_ messages: [StructuredMessage])
}

/// One entry in a tool-aware conversation history.
///
/// Extends the plain `(role, content)` shape that ``ConversationHistoryReceiver``
/// accepts with the tool-calling fields the Ollama and OpenAI-compatible
/// `/api/chat` wire contracts require:
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

/// Adopted by backends that can accept a tool-aware conversation history on
/// each generation request.
///
/// Implemented by the Ollama adapter so the coordinator can feed
/// `role: "tool"` entries (carrying a ``ToolCall/id`` back to the server) and
/// `role: "assistant"` entries annotated with the `toolCalls` the model
/// previously emitted. Backends without tool-call wire support keep the
/// classic ``ConversationHistoryReceiver`` contract.
public protocol ToolCallingHistoryReceiver: AnyObject {
    func setToolAwareHistory(_ messages: [ToolAwareHistoryEntry])
}

/// Adopted by cloud backends that track token usage per response.
public protocol TokenUsageProvider: AnyObject {
    var lastUsage: (promptTokens: Int, completionTokens: Int)? { get }
}

/// Adopted by cloud backends configured with endpoint URL + model name.
public protocol CloudBackendURLModelConfigurable: AnyObject {
    func configure(baseURL: URL, modelName: String)
}

/// Adopted by cloud backends that resolve API keys via a Keychain account.
public protocol CloudBackendKeychainConfigurable: AnyObject {
    func configure(baseURL: URL, keychainAccount: String, modelName: String)
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
/// local tokenizer. `GenerationCoordinator` gates the exact pre-flight
/// check on this protocol so the trim-and-retry path only activates for
/// backends where KV cache overflow is a real concern.
///
/// - Note: `countTokens` must only be called after the model is loaded.
///   Implementations throw ``InferenceError/modelNotLoaded`` when invoked
///   on an unloaded backend.
public protocol TokenCountingBackend: AnyObject {
    /// Returns the exact token count for `text` using the loaded model's vocabulary.
    ///
    /// - Throws: ``InferenceError/inferenceFailure(_:)`` if the model is not loaded,
    ///   or if tokenization fails (e.g., vocabulary is unavailable).
    func countTokens(_ text: String) throws -> Int
}
