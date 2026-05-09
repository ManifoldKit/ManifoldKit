import Foundation
import ManifoldInference
import ManifoldRuntime
import SwiftData

/// Default ``SamplerPresetStore`` backed by SwiftData.
///
/// Operates on the ``ModelContext`` injected at init time, converting between
/// ``ManifoldSchemaV4/SamplerPreset`` `@Model` rows and ``SamplerPresetRecord``
/// value types at the boundary.
@MainActor
public final class SwiftDataSamplerPresetStore: SamplerPresetStore {

    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    public func fetchPresets() async throws -> [SamplerPresetRecord] {
        let descriptor = FetchDescriptor<SamplerPreset>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map { $0.toRecord() }
    }

    public func insertPreset(_ record: SamplerPresetRecord) async throws {
        let preset = SamplerPreset(
            name: record.name,
            temperature: record.temperature,
            topP: record.topP,
            repeatPenalty: record.repeatPenalty,
            presencePenalty: record.presencePenalty,
            frequencyPenalty: record.frequencyPenalty,
            repetitionContextSize: record.repetitionContextSize,
            presenceContextSize: record.presenceContextSize,
            frequencyContextSize: record.frequencyContextSize
        )
        preset.id = record.id
        preset.createdAt = record.createdAt
        modelContext.insert(preset)
        try modelContext.save()
    }

    public func deletePreset(_ id: UUID) async throws {
        let descriptor = FetchDescriptor<SamplerPreset>(
            predicate: #Predicate { $0.id == id }
        )
        guard let preset = try modelContext.fetch(descriptor).first else {
            throw SamplerPresetStoreError.presetNotFound(id)
        }
        modelContext.delete(preset)
        try modelContext.save()
    }
}

extension SamplerPreset {
    /// Converts a SwiftData model to a plain record.
    func toRecord() -> SamplerPresetRecord {
        SamplerPresetRecord(
            id: id,
            name: name,
            temperature: temperature,
            topP: topP,
            repeatPenalty: repeatPenalty,
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty,
            repetitionContextSize: repetitionContextSize,
            presenceContextSize: presenceContextSize,
            frequencyContextSize: frequencyContextSize,
            createdAt: createdAt
        )
    }
}
