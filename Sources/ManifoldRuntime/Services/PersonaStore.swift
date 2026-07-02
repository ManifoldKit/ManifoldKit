import Foundation
import ManifoldInference

/// Errors produced by ``PersonaStore`` implementations.
public enum PersonaStoreError: Error, LocalizedError, Sendable, Equatable {
    case personaNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case let .personaNotFound(id):
            return "Persona not found: \(id.uuidString)"
        }
    }
}

/// Storage-neutral port for persona (saved system prompt) CRUD.
///
/// Mirrors ``SamplerPresetStore`` — UI layers traffic in
/// ``PersonaRecord`` value types rather than reaching through SwiftData to
/// read or write rows. The default implementation is
/// ``SwiftDataPersonaStore``.
///
/// All methods are `async throws` at the surface and traffic in
/// ``PersonaRecord`` value types — the SwiftData `@Model` never escapes the
/// impl.
@MainActor
public protocol PersonaStore: AnyObject, Sendable {

    /// Fetches every persisted persona, ordered most-recently-created first.
    func fetchPersonas() async throws -> [PersonaRecord]

    /// Inserts a new persona.
    func insertPersona(_ record: PersonaRecord) async throws

    /// Deletes a persona by id.
    ///
    /// - Throws: ``PersonaStoreError/personaNotFound(_:)`` when the persona
    ///   does not exist.
    func deletePersona(_ id: UUID) async throws
}
