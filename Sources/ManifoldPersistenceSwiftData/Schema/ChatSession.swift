/// Public alias for the current SwiftData chat session model.
///
/// SchemaV9 adds `activeAgentID: UUID?`, `activeSkillName: String?`, and a
/// cascade `agents: [Agent]` relationship for the multi-agent / skills
/// foundation. Lightweight migration; all new fields default to nil/empty.
public typealias ChatSession = ManifoldSchemaV9.ChatSession
