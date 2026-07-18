/// The SwiftData persistence model for a chat session. Renamed at the
/// module-public layer to ``PersistedChatSession`` to avoid shadowing
/// ``ManifoldInference/ChatSession`` (the value type that flows through the
/// runtime and ports). The underlying `@Model` class is now
/// ``ManifoldSchemaV13/ChatSession`` (previously ``ManifoldSchemaV9/ChatSession``);
/// existing SwiftData stores migrate forward via ``ManifoldMigrationPlan``.
///
/// SchemaV13 adds `branchOriginSessionID: UUID?` and
/// `branchOriginTitleSnapshot: String?` for the branch-origin chip (#2307).
/// Lightweight migration; both new fields default to nil.
///
/// Use ``PersistedChatSession`` in new code. Host apps that import both
/// ``ManifoldInference`` and ``ManifoldPersistenceSwiftData`` can refer to
/// the value type as `ChatSession` and the SwiftData row as
/// `PersistedChatSession` without disambiguation.
public typealias PersistedChatSession = ManifoldSchemaV13.ChatSession
