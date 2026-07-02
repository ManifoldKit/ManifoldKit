import Foundation
import ManifoldInference
import ManifoldRuntime
import SwiftData

/// Default ``PersonaStore`` backed by SwiftData.
///
/// Operates on the ``ModelContext`` injected at init time, converting between
/// ``ManifoldSchemaV12/Persona`` `@Model` rows and ``PersonaRecord`` value
/// types at the boundary.
@MainActor
public final class SwiftDataPersonaStore: PersonaStore {

    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    public func fetchPersonas() async throws -> [PersonaRecord] {
        let descriptor = FetchDescriptor<Persona>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map { $0.toRecord() }
    }

    public func insertPersona(_ record: PersonaRecord) async throws {
        let persona = Persona(
            name: record.name,
            systemPrompt: record.systemPrompt
        )
        persona.id = record.id
        persona.createdAt = record.createdAt
        modelContext.insert(persona)
        try modelContext.save()
    }

    public func deletePersona(_ id: UUID) async throws {
        let descriptor = FetchDescriptor<Persona>(
            predicate: #Predicate { $0.id == id }
        )
        guard let persona = try modelContext.fetch(descriptor).first else {
            throw PersonaStoreError.personaNotFound(id)
        }
        modelContext.delete(persona)
        try modelContext.save()
    }
}

extension Persona {
    /// Converts a SwiftData model to a plain record.
    func toRecord() -> PersonaRecord {
        PersonaRecord(
            id: id,
            name: name,
            systemPrompt: systemPrompt,
            createdAt: createdAt
        )
    }
}
