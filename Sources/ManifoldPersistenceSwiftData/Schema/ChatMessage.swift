/// Public alias for the current SwiftData chat message model.
///
/// SchemaV9 adds `agentID: UUID?` for multi-agent attribution. Intentionally
/// not a `@Relationship` so deleting an agent doesn't cascade-delete its
/// authored history (see the field doc in ``ManifoldSchemaV9/ChatMessage``).
public typealias ChatMessage = ManifoldSchemaV9.ChatMessage
