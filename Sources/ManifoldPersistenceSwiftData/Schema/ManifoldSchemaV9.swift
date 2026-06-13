import Foundation
import ManifoldInference
import ManifoldRuntime
@preconcurrency import SwiftData

/// ManifoldKit SwiftData schema version 9.
///
/// Adds agent identity + skill scope fields used by the Wave 1B foundation of
/// the multi-agent / skill plan:
///
/// - ``ChatSession/activeAgentID`` — UUID of the agent currently authoring
///   the session's next turn; nil when no multi-agent registry is in play.
/// - ``ChatSession/activeSkillName`` — sticky scope name while a skill is
///   active. Cleared when the skill's invocation completes.
/// - ``ChatSession/agents`` — per-session cascade relationship of ``Agent``
///   rows. Agents die with their session.
/// - ``ChatMessage/agentID`` — identity of the agent that authored a
///   message. **Intentionally NOT a `@Relationship`** — see the field doc.
/// - New ``Agent`` `@Model`.
///
/// V9 redefines `ChatSession` and `ChatMessage` in-namespace so SwiftData
/// picks up the new columns. The migration is lightweight: every new field
/// has a nil/empty default, no existing column changes, no data motion.
///
/// All other model types (sampler preset, API endpoint, benchmark cache,
/// RAG document, usage record) are carried forward unchanged.
public enum ManifoldSchemaV9: VersionedSchema {
    public static let versionIdentifier = Schema.Version(9, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            ChatMessage.self,
            ChatSession.self,
            Agent.self,
            ManifoldSchemaV4.SamplerPreset.self,
            ManifoldSchemaV4.APIEndpoint.self,
            ManifoldSchemaV4.ModelBenchmarkCache.self,
            ManifoldSchemaV5.RagDocument.self,
            ManifoldSchemaV6.TurnUsageModel.self,
        ]
    }

    // MARK: - ChatSession (V9 — adds activeAgentID, activeSkillName, agents)

    @Model
    public final class ChatSession {
        public var id: UUID
        public var title: String
        public var createdAt: Date
        public var updatedAt: Date

        /// Per-session system prompt.
        public var systemPrompt: String

        /// The UUID of the selected ModelInfo for this session.
        public var selectedModelID: UUID?

        /// The UUID of the selected APIEndpoint for this session.
        public var selectedEndpointID: UUID?

        // Per-session generation overrides (nil = use global default)
        public var temperature: Float?
        public var topP: Float?
        public var repeatPenalty: Float?

        /// Stored as PromptTemplate.rawValue; nil means auto-detect or global default.
        public var promptTemplateRawValue: String?

        /// User override for context window size; nil uses model default.
        public var contextSizeOverride: Int?

        /// Comma-separated UUID strings of pinned messages in this session.
        public var pinnedMessageIDsRaw: String?

        /// True if this session is pinned to the top of the session list.
        public var isPinned: Bool = false

        /// Timestamp recorded when ``isPinned`` flipped to `true`.
        public var pinnedAt: Date?

        /// Non-optional sort key used by the persistence adapter to express
        /// pinned-first ordering in a single SortDescriptor. Maintained by
        /// the adapter; callers should not write directly.
        public var pinnedSortKey: Date = Date.distantPast

        /// UUID of the agent currently authoring this session's next turn.
        /// Nil when the session has no multi-agent registry. The executor
        /// re-derives the active system prompt per turn from this ID.
        public var activeAgentID: UUID?

        /// Sticky scope name while a skill is mid-invocation. Cleared when
        /// the skill returns. While non-nil the advertised tool list is
        /// intersected with the skill's `allowed-tools`.
        public var activeSkillName: String?

        /// Per-session agent registry. Cascade delete is correct here:
        /// agents only have meaning inside their owning session.
        @Relationship(deleteRule: .cascade) public var agents: [Agent] = []

        public init(title: String = "New Chat") {
            self.id = UUID()
            self.title = title
            self.createdAt = Date()
            self.updatedAt = Date()
            self.systemPrompt = ""
            self.isPinned = false
        }

        /// The set of pinned message IDs for this session.
        public var pinnedMessageIDs: Set<UUID> {
            get {
                guard let raw = pinnedMessageIDsRaw else { return [] }
                return Set(raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
            }
            set {
                pinnedMessageIDsRaw = newValue.isEmpty ? nil : newValue.map(\.uuidString).joined(separator: ",")
            }
        }

        /// Convenience to get/set the prompt template as a `PromptTemplate` enum.
        public var promptTemplate: PromptTemplate? {
            get {
                guard let raw = promptTemplateRawValue else { return nil }
                return PromptTemplate(rawValue: raw)
            }
            set {
                promptTemplateRawValue = newValue?.rawValue
            }
        }
    }

    // MARK: - ChatMessage (V9 — adds agentID)

    @Model
    public final class ChatMessage {
        public var id: UUID
        public var role: MessageRole
        public var timestamp: Date
        public var sessionID: UUID

        /// Plain-text cache of the message content.
        public var content: String

        /// JSON-encoded `[MessagePart]` array. This is the source of truth for
        /// structured content.
        public var contentPartsJSON: String

        /// Tokens used in the prompt for this response (cloud API backends only).
        public var promptTokens: Int?
        /// Tokens generated in this response (cloud API backends only).
        public var completionTokens: Int?

        /// Raw storage for ``MessageKind``. Defaults to "chat" so rows written
        /// before SchemaV7 decode as ``MessageKind/chat``.
        public var kindRaw: String = "chat"

        /// JSON-encoded ``[Citation]`` array. `nil` when the turn was not RAG-augmented.
        public var citationsJSON: String?

        /// Identity of the agent that authored this message, when the session has a
        /// multi-agent registry. Intentionally NOT a `@Relationship` — agents can be
        /// deleted independently of their authored history, and the UI falls back to
        /// role-based rendering when an `agentID` no longer resolves to an `Agent`
        /// in the session. A `@Relationship` here would cascade-delete authored
        /// messages on agent removal, which destroys conversation audit trail.
        public var agentID: UUID?

        public init(
            role: MessageRole,
            content: String,
            sessionID: UUID
        ) {
            self.id = UUID()
            self.role = role
            self.timestamp = Date()
            self.sessionID = sessionID
            self.content = content
            self.contentPartsJSON = Self.encode([.text(content)])
            self.kindRaw = "chat"
        }

        /// Creates a message from structured content parts.
        public init(
            role: MessageRole,
            contentParts: [MessagePart],
            sessionID: UUID
        ) {
            self.id = UUID()
            self.role = role
            self.timestamp = Date()
            self.sessionID = sessionID
            self.contentPartsJSON = Self.encode(contentParts)
            self.content = contentParts.compactMap(\.textContent).joined()
            self.kindRaw = "chat"
        }

        // MARK: - Content Parts

        public var contentParts: [MessagePart] {
            get { Self.decode(contentPartsJSON) }
            set {
                contentPartsJSON = Self.encode(newValue)
                content = newValue.compactMap(\.textContent).joined()
            }
        }

        // MARK: - Kind (MessageKind)

        public var kind: MessageKind {
            get { MessageKind(rawStorage: kindRaw) ?? .chat }
            set { kindRaw = newValue.rawStorage }
        }

        // MARK: - Citations

        public var citations: [Citation]? {
            get {
                guard let data = citationsJSON?.data(using: .utf8) else { return nil }
                do {
                    return try JSONDecoder().decode([Citation].self, from: data)
                } catch {
                    Log.persistence.warning("Failed to decode citationsJSON: \(error)")
                    return nil
                }
            }
            set {
                guard let v = newValue, !v.isEmpty else { citationsJSON = nil; return }
                do {
                    let data = try JSONEncoder().encode(v)
                    citationsJSON = String(data: data, encoding: .utf8)
                } catch {
                    Log.persistence.warning("Failed to encode citations: \(error)")
                    citationsJSON = nil
                }
            }
        }

        // MARK: - JSON Helpers

        static func encode(_ parts: [MessagePart]) -> String {
            do {
                let data = try JSONEncoder().encode(parts)
                if let json = String(data: data, encoding: .utf8) {
                    return json
                }
                Log.persistence.error("Failed to convert encoded MessagePart data to UTF-8 string; substituting visible placeholder")
            } catch {
                Log.persistence.error("Failed to encode MessagePart array: \(error)")
            }
            // Returning "[]" here would be indistinguishable from a legitimately empty
            // message and would silently lose the content. A non-JSON sentinel makes the
            // failure visible: decode() falls back to .text(...) for non-JSON input, so the
            // user sees the placeholder instead of a vanished message.
            return Self.encodeFailurePlaceholder
        }

        /// Sentinel persisted when MessagePart encoding fails. Intentionally not valid JSON so
        /// decode() surfaces it as visible text rather than swallowing it as empty content.
        static let encodeFailurePlaceholder = "[message content could not be encoded]"

        static func decode(_ json: String) -> [MessagePart] {
            guard let data = json.data(using: .utf8) else {
                Log.persistence.warning("contentPartsJSON is not valid UTF-8")
                return json.isEmpty ? [] : [.text(json)]
            }
            do {
                return try JSONDecoder().decode([MessagePart].self, from: data)
            } catch {
                Log.persistence.warning("Failed to decode contentPartsJSON, falling back to text: \(error)")
                return json.isEmpty ? [] : [.text(json)]
            }
        }
    }

    // MARK: - Agent (V9 — new model)

    /// A per-session agent identity with its own system prompt and tool scope.
    ///
    /// Lives inside its owning ``ChatSession`` via a cascade relationship.
    /// The executor re-derives the active system prompt per turn from the
    /// session's `activeAgentID`; prior assistant messages keep their
    /// `agentID` attribution for audit purposes.
    @Model
    public final class Agent {
        @Attribute(.unique) public var id: UUID
        public var name: String
        public var systemPrompt: String

        /// User-facing description. SwiftData reserves the unadorned `description`
        /// identifier on `@Model` types, so we expose it under a renamed column.
        public var descriptionText: String

        /// Optional intersection scope for tools. When non-nil, the executor
        /// restricts the advertised tool list to names in this set while this
        /// agent is active.
        public var allowedToolNames: [String]?

        public init(
            id: UUID = UUID(),
            name: String,
            systemPrompt: String,
            descriptionText: String,
            allowedToolNames: [String]? = nil
        ) {
            self.id = id
            self.name = name
            self.systemPrompt = systemPrompt
            self.descriptionText = descriptionText
            self.allowedToolNames = allowedToolNames
        }
    }
}
