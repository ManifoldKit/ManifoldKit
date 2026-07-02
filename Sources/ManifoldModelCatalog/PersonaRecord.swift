import Foundation

/// Plain-data snapshot of a saved persona (a named, reusable system prompt),
/// decoupled from any specific storage backend.
///
/// `ManifoldPersistenceSwiftData` provides the SwiftData `@Model Persona` that
/// maps to this record; UI flows traffic in records so they don't need a
/// SwiftData dependency on the read or write path.
public struct PersonaRecord: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var systemPrompt: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        systemPrompt: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.createdAt = createdAt
    }
}
