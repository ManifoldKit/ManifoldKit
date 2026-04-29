import Foundation
import BaseChatInference

// MARK: - PromptContextRequest
//
// Carries the inputs ``ConversationRuntime`` is about to feed into prompt
// assembly. Emitted on `ConversationEvent.beforeContextAssembly` so consumers
// that bracket context assembly (memory injection, retrieval) can observe the
// shape of the upcoming turn before slots are merged.
//
// Plain value type; no provider list is exposed here — the providers live on
// the runtime and the pipeline composes them. The request is the *input* to
// assembly, not the assembly state itself.

/// Input snapshot for the upcoming context-assembly pass.
///
/// Emitted via ``ConversationEvent/beforeContextAssembly(prompt:request:)`` so
/// consumers can observe the request shape before ``PromptContextPipeline``
/// merges contributing slots. The contained `messageCount` is the same value
/// the runtime forwards to ``PromptContextProvider/contributeSlots(messageCount:)``.
public struct PromptContextRequest: Sendable, Hashable {

    /// The session whose turn is being assembled.
    public let sessionID: UUID

    /// Number of conversation messages already on record at assembly time.
    /// Forwarded to providers so ``PromptSlotPosition/atDepth(_:)`` can compute
    /// its sort index against the same baseline the runtime is about to render.
    public let messageCount: Int

    /// The user's input text that triggered this turn. `nil` when the turn was
    /// initiated by something other than user input (e.g., regenerate). PR-A
    /// only emits this for send; later sub-flows fill in the regenerate /
    /// edit shapes.
    public let userInput: String?

    public init(sessionID: UUID, messageCount: Int, userInput: String?) {
        self.sessionID = sessionID
        self.messageCount = messageCount
        self.userInput = userInput
    }
}

// MARK: - FinishReason

/// Why a generation stream terminated.
///
/// Carried by ``ConversationEvent/streamFinished(messageID:reason:)``. The
/// case set is deliberately small — backends and the runtime collapse a
/// richer underlying lifecycle into one of these four high-level outcomes
/// before emitting.
public enum FinishReason: Sendable, Hashable {
    /// Stream ended normally — backend emitted its terminal event.
    case stop

    /// Caller cancelled the in-flight stream via
    /// ``ConversationRuntime/cancel(_:)`` (or equivalent).
    case cancelled

    /// Backend produced no visible content (and no thinking content) before
    /// the stream ended. The runtime drops the empty assistant message
    /// instead of persisting it.
    case empty

    /// Backend reached its declared output-token cap or another
    /// length-limited stop condition.
    case length
}

// MARK: - CompressionReason

/// Why the runtime compressed (trimmed) message history before generation.
///
/// Carried by ``ConversationEvent/compressionTriggered(removed:reason:)``.
/// PR-A does not emit this case from its send flow — context-window
/// management remains in `ChatViewModel`'s `GenerationCoordinator` for the
/// pre-PR-A surface. The case is wired into the event enum for future sub-
/// flows (PR-B/PR-C) and Phase 1.2.5 follow-ups so adopters can subscribe
/// today and receive events when later PRs route compression through the
/// runtime.
public enum CompressionReason: Sendable, Hashable {
    /// Total prompt tokens (history + system + reserve) exceeded the
    /// configured context window. Older messages were dropped to fit.
    case contextWindowExceeded

    /// Caller-driven compression — e.g., a user-initiated "summarise older
    /// messages" command. PR-A does not surface this; reserved for hosts
    /// that later opt into runtime-managed compression.
    case manual
}

// MARK: - ConversationError

/// Errors surfaced through the runtime's event stream.
///
/// Wraps the heterogeneous error sources `ConversationRuntime` composes
/// against (`MessageStore`, `InferenceService`, `PromptContextPipeline`)
/// into a single typed error so consumers don't have to switch on multiple
/// underlying types. `.persistence` and `.inference` carry the underlying
/// `Error` so callers that want to introspect can bridge back; the
/// load-bearing case is `.cancelled`, which lets adapters distinguish
/// user-initiated cancel from real failures without inspecting an
/// underlying type.
public enum ConversationError: Error, Sendable {
    /// The runtime was driven without a configured persistence port. The
    /// runtime requires a `MessageStore` at construction; this case exists
    /// for parity with `ChatPersistenceError.providerNotConfigured` for
    /// callers that surface persistence-style errors uniformly.
    case providerNotConfigured

    /// `regenerate` was called when no assistant message exists in the
    /// session. There is nothing to replace — callers should gate the
    /// regenerate action on the presence of at least one assistant message.
    case noAssistantMessageToRegenerate

    /// Persistence (insert / update / delete) failed.
    case persistence(any Error)

    /// Inference (enqueue / stream iteration) failed. The cancellation case
    /// is broken out separately so adapters can distinguish user-cancel
    /// from real failures; this case carries every other underlying
    /// inference error.
    case inference(any Error)

    /// Context assembly via a registered ``PromptContextProvider`` failed.
    case contextAssembly(any Error)

    /// The runtime's send was cancelled (via ``ConversationRuntime/cancel(_:)``
    /// or task cancellation propagation). Adapters use this to suppress
    /// error UI for explicit user cancel.
    case cancelled
}

extension ConversationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .providerNotConfigured:
            return "ConversationRuntime persistence is not configured."
        case .noAssistantMessageToRegenerate:
            return "No assistant message to regenerate — the conversation has no assistant turn yet."
        case let .persistence(error):
            return "Persistence failure during conversation: \(error.localizedDescription)"
        case let .inference(error):
            return "Inference failure during conversation: \(error.localizedDescription)"
        case let .contextAssembly(error):
            return "Context assembly failure: \(error.localizedDescription)"
        case .cancelled:
            return "Conversation request was cancelled."
        }
    }
}
