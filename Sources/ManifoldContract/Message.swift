import Foundation

/// A typed conversation message used by `InferenceService.enqueue(messages:...)`
/// (the typed overload) and `InferenceService.generate(messages:...)`.
///
/// **Not the same as `ChatMessage` (the SwiftData `@Model`) / `ChatMessage`
/// (the `ManifoldInference` value type).** Those types live further down the
/// stack — they share a name but differ by module:
///
/// - `ChatMessage` (a SwiftData `@Model` in `ManifoldPersistenceSwiftData`)
///   is the persisted record with a UUID, timestamp, attachments, token-
///   usage counters, and SwiftData identity. It exists to back the on-disk
///   session/transcript model.
/// - `ChatMessage` (in `ManifoldInference`) is the persistence-agnostic
///   value type adapters convert ChatMessage to. It carries `contentParts`,
///   role enums, and structured attachment metadata.
/// - ``Message`` (this type) is the **wire-shaped** input the inference
///   queue takes when a caller wants to drive a one-shot generation without
///   constructing the richer persistence records. Each case carries only
///   role-discriminator + content text — no IDs, no timestamps, no
///   attachments.
///
/// Replaces the typo-prone `[(role: String, content: String)]` tuple
/// variant. The tuple-shaped `enqueue(messages: [(role:content:)])`
/// overloads were removed pre-1.0 (delete-don't-deprecate); the low-level,
/// non-queued `generate(messages: [(role:content:)])` entry point still
/// accepts the tuple shape by design — it predates ``Message`` and is not
/// scheduled for removal.
///
/// ## Scope boundary — text-only by design
///
/// Every case carries a single `String` and nothing else. This type
/// **intentionally cannot represent** tool calls, tool results, image or
/// audio attachments, or any multi-part turn. That is not a gap to close:
/// `Message` is the minimal one-shot wire shape for "send these plain turns
/// and stream a reply." Anything richer — multimodal content, tool-call
/// loops, persisted identity — flows through the value/`@Model` `ChatMessage`
/// types described above, which the runtime turn loop (`ConversationRuntime`)
/// drives. Keeping this enum thin is what lets callers script a quick
/// generation without constructing those records; widening it would blur the
/// boundary the two-tier design exists to draw.
public enum Message: Sendable, Equatable {
    /// A system message, typically setting role/persona/policy.
    case system(String)
    /// A user message — the human turn.
    case user(String)
    /// An assistant message — the model's prior turn.
    case assistant(String)
}

extension Message {
    /// The role string the underlying queue/backend layer expects on the
    /// `(role, content)` tuple shape. Stable across cases — bridge code
    /// maps this 1:1 onto the legacy tuple wire format.
    public var role: String {
        switch self {
        case .system: return "system"
        case .user: return "user"
        case .assistant: return "assistant"
        }
    }

    /// The associated string payload of this message.
    public var content: String {
        switch self {
        case let .system(text), let .user(text), let .assistant(text):
            return text
        }
    }

    /// Materialises the legacy tuple wire shape so the typed overload can
    /// forward into existing tuple-shaped queue and backend code without a
    /// duplicated implementation.
    public var asRoleContentTuple: (role: String, content: String) {
        (role: role, content: content)
    }
}

extension Array where Element == Message {
    /// Convenience — converts a `[Message]` slice into the legacy tuple
    /// shape for the one-shot adaptors that still take `[(role:content:)]`.
    public var asRoleContentTuples: [(role: String, content: String)] {
        map(\.asRoleContentTuple)
    }
}
