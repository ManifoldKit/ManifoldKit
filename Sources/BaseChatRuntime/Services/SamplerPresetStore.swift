import Foundation
import BaseChatInference

/// Errors produced by ``SamplerPresetStore`` implementations.
public enum SamplerPresetStoreError: Error, LocalizedError, Sendable, Equatable {
    case presetNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case let .presetNotFound(id):
            return "Sampler preset not found: \(id.uuidString)"
        }
    }
}

/// Storage-neutral port for sampler-preset CRUD.
///
/// Replaces the direct `@Query(\SamplerPreset.createdAt)` access in
/// `SamplerPresetPickerView`, so UI layers no longer reach through SwiftData
/// to read or write preset rows. The default implementation is
/// ``SwiftDataSamplerPresetStore``.
///
/// All methods are `async throws` at the surface and traffic in
/// ``SamplerPresetRecord`` value types — the SwiftData `@Model` never escapes
/// the impl.
@MainActor
public protocol SamplerPresetStore: AnyObject, Sendable {

    /// Fetches every persisted preset, ordered most-recently-created first.
    func fetchPresets() async throws -> [SamplerPresetRecord]

    /// Inserts a new preset.
    func insertPreset(_ record: SamplerPresetRecord) async throws

    /// Deletes a preset by id.
    ///
    /// - Throws: ``SamplerPresetStoreError/presetNotFound(_:)`` when the preset
    ///   does not exist.
    func deletePreset(_ id: UUID) async throws
}
