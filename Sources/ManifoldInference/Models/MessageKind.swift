import Foundation

/// The semantic kind of a ``ChatMessage``.
///
/// Kind is orthogonal to ``MessageRole`` — backends see role; the persistence,
/// export, and UI layers switch on kind.
public enum MessageKind: Hashable, Sendable {
    /// An ordinary chat turn (user, assistant, or system prompt fragment).
    case chat
    /// A compression brief or summarisation artifact. The associated string is
    /// an opaque label (e.g. `"summary"`, `"memory"`) set by the compression policy.
    case memory(String)
    /// A host-defined annotation. Not sent to the backend by default.
    case annotation(String)
    /// Reserved for tool-result receipts. Currently **inert**: no first-party
    /// path emits this case, and it is filtered from both the wire payload
    /// (``isWireVisible`` is `false`) and user-facing exports/UI
    /// (``isUserVisible`` is `false`), so constructing one today has no
    /// behavioural effect. The case exists now only so wiring it later is not a
    /// second breaking enum change.
    case toolResult(callID: String)
    /// Escape hatch for host-defined kinds not covered by the named cases.
    /// Sent to the backend as a `system`-role message when `isWireVisible` is `true`.
    case custom(String)
}

// MARK: - Wire & visibility

extension MessageKind {
    /// The role to use when sending this record to an inference backend.
    /// `nil` means the caller uses `record.role` directly (the `.chat` case).
    /// Records with `isWireVisible == false` are filtered out before this is consulted.
    public var backendRole: MessageRole? {
        switch self {
        case .chat:               return nil  // caller uses record.role directly
        case .memory:             return .system
        case .annotation:         return nil
        case .toolResult:         return nil  // reserved; not wired yet
        case .custom:             return .system
        }
    }

    /// Whether this record should appear in the payload sent to the backend.
    public var isWireVisible: Bool {
        switch self {
        case .chat:       return true
        case .memory:     return true
        case .annotation: return false
        case .toolResult: return false
        case .custom:     return true
        }
    }

    /// Whether this record should appear in user-facing exports and the default chat UI.
    public var isUserVisible: Bool {
        switch self {
        case .chat:       return true
        case .memory:     return false
        case .annotation: return false
        case .toolResult: return false
        case .custom:     return false
        }
    }
}

// MARK: - Storage encoding

extension MessageKind: Codable {
    // Stored as "type:payload" strings. Unknown prefixes decode as .chat so
    // future kinds don't corrupt old installs that roll back.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MessageKind(rawStorage: raw) ?? .chat
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawStorage)
    }

    public init?(rawStorage: String) {
        if rawStorage == "chat" { self = .chat; return }
        let parts = rawStorage.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "memory":     self = .memory(parts[1])
        case "annotation": self = .annotation(parts[1])
        case "toolResult": self = .toolResult(callID: parts[1])
        case "custom":     self = .custom(parts[1])
        default:           return nil
        }
    }

    public var rawStorage: String {
        switch self {
        case .chat:                    return "chat"
        case .memory(let label):       return "memory:\(label)"
        case .annotation(let label):   return "annotation:\(label)"
        case .toolResult(let callID):  return "toolResult:\(callID)"
        case .custom(let value):       return "custom:\(value)"
        }
    }
}
