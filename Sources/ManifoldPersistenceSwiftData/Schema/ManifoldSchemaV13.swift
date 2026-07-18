import Foundation
import ManifoldInference
import ManifoldRuntime
@preconcurrency import SwiftData

/// ManifoldKit SwiftData schema version 13.
///
/// Adds branch-origin provenance to `ChatSession` (#2307 branch-origin chip):
///
/// - ``ChatSession/branchOriginSessionID`` — the source session's id when this
///   session was created by ``SessionBranchCoordinator/branch(sourceSessionID:branchMessageID:newSessionID:newSessionTitle:)``;
///   `nil` for sessions that were not branched.
/// - ``ChatSession/branchOriginTitleSnapshot`` — the source session's title
///   captured at branch time. The read path prefers resolving the source's
///   *current* title live via `branchOriginSessionID` (so a rename of the
///   source is reflected); this snapshot is the fallback used only when the
///   source session no longer exists (deleted), so "Branched from ‹title›"
///   can still render instead of silently disappearing.
///
/// V13 redefines `ChatSession` in-namespace so SwiftData picks up the two new
/// columns. The migration is lightweight: both fields default to `nil`, no
/// existing column changes, no data motion.
///
/// All other model types (ChatMessage, Agent, sampler preset, API endpoint,
/// benchmark cache, RAG document, usage record, conversation run, run step,
/// tool-call conformance, persona) are carried forward from V12 unchanged.
public enum ManifoldSchemaV13: VersionedSchema {
    public static let versionIdentifier = Schema.Version(13, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            // Carried forward verbatim from V12 — V13 does not redefine these.
            ManifoldSchemaV9.ChatMessage.self,
            ManifoldSchemaV9.Agent.self,
            ManifoldSchemaV4.SamplerPreset.self,
            ManifoldSchemaV4.APIEndpoint.self,
            ManifoldSchemaV4.ModelBenchmarkCache.self,
            ManifoldSchemaV5.RagDocument.self,
            ManifoldSchemaV6.TurnUsageModel.self,
            ManifoldSchemaV10.ConversationRunModel.self,
            ManifoldSchemaV10.RunStepModel.self,
            ManifoldSchemaV11.ToolCallConformanceRecord.self,
            ManifoldSchemaV12.Persona.self,
            // New in V13.
            ChatSession.self,
        ]
    }

    // MARK: - ChatSession (V13 — adds branchOriginSessionID, branchOriginTitleSnapshot)

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
        @Relationship(deleteRule: .cascade) public var agents: [ManifoldSchemaV9.Agent] = []

        /// The source session's id when this session was created via
        /// ``SessionBranchCoordinator``. `nil` for sessions that were not
        /// branched. Intentionally NOT a `@Relationship` — the source session
        /// can be deleted independently of any session branched from it, and
        /// a `@Relationship` here would either cascade-delete branches on
        /// source deletion (destroying history) or require `.nullify`
        /// bookkeeping this column already handles by simply going stale.
        public var branchOriginSessionID: UUID?

        /// Snapshot of the source session's title, captured at branch time.
        /// Read-path fallback only: callers should resolve the source's
        /// current title live via `branchOriginSessionID` first, and fall
        /// back to this snapshot when the source no longer exists. `nil` for
        /// sessions that were not branched.
        public var branchOriginTitleSnapshot: String?

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
}
