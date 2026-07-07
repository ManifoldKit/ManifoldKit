/// The SwiftData persistence model for a chat session. Renamed at the
/// module-public layer to ``PersistedChatSession`` to avoid shadowing
/// ``ManifoldInference/ChatSession`` (the value type that flows through the
/// runtime and ports). The underlying `@Model` class remains
/// ``ManifoldSchemaV9/ChatSession`` so existing SwiftData stores stay valid.
///
/// SchemaV9 adds `activeAgentID: UUID?`, `activeSkillName: String?`, and a
/// cascade `agents: [Agent]` relationship for the multi-agent / skills
/// foundation. Lightweight migration; all new fields default to nil/empty.
///
/// Use ``PersistedChatSession`` in new code. Host apps that import both
/// ``ManifoldInference`` and ``ManifoldPersistenceSwiftData`` can refer to
/// the value type as `ChatSession` and the SwiftData row as
/// `PersistedChatSession` without disambiguation.
public typealias PersistedChatSession = ManifoldSchemaV9.ChatSession
