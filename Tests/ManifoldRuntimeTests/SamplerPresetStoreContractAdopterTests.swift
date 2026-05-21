import XCTest
import ManifoldRuntime
import ManifoldInference
import ManifoldTestSupport

// MARK: - InMemorySamplerPresetStore (test double for contract adoption)

@MainActor
private final class InMemorySamplerPresetStore: SamplerPresetStore {
    private var presets: [SamplerPresetRecord] = []

    func fetchPresets() async throws -> [SamplerPresetRecord] {
        presets.sorted { $0.createdAt > $1.createdAt }
    }

    func insertPreset(_ record: SamplerPresetRecord) async throws {
        presets.append(record)
    }

    func deletePreset(_ id: UUID) async throws {
        guard let idx = presets.firstIndex(where: { $0.id == id }) else {
            throw SamplerPresetStoreError.presetNotFound(id)
        }
        presets.remove(at: idx)
    }
}

// MARK: - InMemorySamplerPresetStoreContractTests

@MainActor
final class InMemorySamplerPresetStoreContractTests: XCTestCase, SamplerPresetStoreContract {

    func makeSamplerPresetStore() -> any SamplerPresetStore {
        InMemorySamplerPresetStore()
    }

    func test_emptyStore_returnsNoPresets() async throws {
        try await assertSamplerPresetStore_emptyStoreReturnsNoPresets()
    }

    func test_insert_thenFetch_returnsRecord() async throws {
        try await assertSamplerPresetStore_insertThenFetchReturnsRecord()
    }

    func test_fetch_ordersByMostRecentlyCreatedFirst() async throws {
        try await assertSamplerPresetStore_fetchOrdersByMostRecentlyCreatedFirst()
    }

    func test_delete_deletedPresetNotReturned() async throws {
        try await assertSamplerPresetStore_deletedPresetNotReturned()
    }

    func test_delete_unknownID_throwsNotFound() async throws {
        try await assertSamplerPresetStore_deleteUnknownIDThrowsNotFound()
    }

    func test_multiplePresets_allReturned() async throws {
        try await assertSamplerPresetStore_multiplePresetsAllReturned()
    }
}
