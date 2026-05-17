import Foundation
import ManifoldInference
import ManifoldRuntime
@preconcurrency import SwiftData

/// ManifoldKit SwiftData schema version 8.
///
/// Adds session-level pinning to ``ChatSession`` via two new columns:
/// - `isPinned: Bool` — defaults to `false` so existing rows are unaffected.
/// - `pinnedAt: Date?` — set when the session is pinned; used as the stable
///   sort key inside the pinned bucket so the most recently pinned surfaces
///   first.
///
/// V7 carried `ManifoldSchemaV4.ChatSession` forward unchanged. V8 redefines
/// the model in-namespace so SwiftData picks up the two new columns. The
/// migration is lightweight — both columns have defaults and no existing
/// column is touched.
///
/// All other model types (``ChatMessage`` at V7, sampler preset, API endpoint,
/// benchmark cache, RAG document, usage record) are carried forward unchanged.
public enum ManifoldSchemaV8: VersionedSchema {
    public static let versionIdentifier = Schema.Version(8, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            ManifoldSchemaV7.ChatMessage.self,
            ChatSession.self,
            ManifoldSchemaV4.SamplerPreset.self,
            ManifoldSchemaV4.APIEndpoint.self,
            ManifoldSchemaV4.ModelBenchmarkCache.self,
            ManifoldSchemaV5.RagDocument.self,
            ManifoldSchemaV6.TurnUsageRecordModel.self,
        ]
    }

    // MARK: - ChatSession (V8 — adds isPinned and pinnedAt)

    /// A chat session containing a sequence of messages with its own settings.
    ///
    /// V8 introduces session-level pinning. Pinned sessions sort above the
    /// chronological list in ``SessionStore/fetchSessions()`` so consumer apps
    /// no longer need to maintain their own `Set<UUID>` of pinned IDs in
    /// `UserDefaults` and reconcile it across deletes.
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
        /// nil means no messages are pinned.
        public var pinnedMessageIDsRaw: String?

        /// True if this session is pinned to the top of the session list.
        ///
        /// Defaults to `false`. Existing rows migrated from V7 decode as
        /// unpinned without touching the persisted store.
        public var isPinned: Bool = false

        /// Timestamp recorded when ``isPinned`` flipped to `true`. Used as the
        /// stable secondary sort key inside the pinned bucket so the most
        /// recently pinned session surfaces first. `nil` while ``isPinned`` is
        /// `false`.
        public var pinnedAt: Date?

        /// Non-optional sort key so SwiftData can express the pinned-first
        /// ordering with a single `SortDescriptor` over a `Comparable`
        /// column. SwiftData's `SortDescriptor` only supports `Bool` /
        /// optional sort fields against NSObject — neither applies to
        /// SwiftData `@Model` types — so we mirror the pinned timestamp
        /// into a non-optional `Date` (defaulting to `Date.distantPast`)
        /// and sort on this column desc instead. Pinned rows sort above
        /// every unpinned row because `distantPast` is smaller than any
        /// real timestamp; within the pinned bucket the order is `pinnedAt`
        /// desc. Maintained by the persistence adapter on every
        /// insert/update — callers should not write to it directly.
        public var pinnedSortKey: Date = Date.distantPast

        public init(title: String = "New Chat") {
            self.id = UUID()
            self.title = title
            self.createdAt = Date()
            self.updatedAt = Date()
            self.systemPrompt = ""
            self.isPinned = false
        }

        /// The set of pinned message IDs for this session.
        ///
        /// Pinned messages are preserved when history is trimmed to fit the context window, regardless of age.
        /// Serialized as comma-separated UUID strings in ``pinnedMessageIDsRaw``.
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
