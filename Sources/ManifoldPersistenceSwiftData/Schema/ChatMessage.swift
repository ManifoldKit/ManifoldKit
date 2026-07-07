/// The SwiftData persistence model for a chat message. Renamed at the
/// module-public layer to ``PersistedChatMessage`` to avoid shadowing
/// ``ManifoldInference/ChatMessage`` (the value type that flows through the
/// runtime and ports). The underlying `@Model` class remains
/// ``ManifoldSchemaV9/ChatMessage`` so existing SwiftData stores stay valid.
///
/// SchemaV9 adds `agentID: UUID?` for multi-agent attribution. Intentionally
/// not a `@Relationship` so deleting an agent doesn't cascade-delete its
/// authored history (see the field doc in ``ManifoldSchemaV9/ChatMessage``).
///
/// Use ``PersistedChatMessage`` in new code. Host apps that import both
/// ``ManifoldInference`` and ``ManifoldPersistenceSwiftData`` can refer to
/// the value type as `ChatMessage` and the SwiftData row as
/// `PersistedChatMessage` without disambiguation.
public typealias PersistedChatMessage = ManifoldSchemaV9.ChatMessage
