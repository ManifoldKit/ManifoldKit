import XCTest
@testable import ManifoldRuntime
import ManifoldInference

/// Locks the ``SamplerPresetStore`` protocol contract via an in-memory
/// reference implementation. The SwiftData-backed implementation is
/// exercised in ``SwiftDataSamplerPresetStoreTests``; this file defends
/// the documented surface (`fetch`, `insert`, `delete`, missing-id error)
/// independently of any backing store.
@MainActor
final class SamplerPresetStoreContractTests: XCTestCase {

    private final class InMemorySamplerPresetStore: SamplerPresetStore {
        private var presets: [SamplerPresetRecord] = []

        func fetchPresets() async throws -> [SamplerPresetRecord] {
            presets.sorted(by: { $0.createdAt > $1.createdAt })
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

    func test_fetchPresets_emptyStore_returnsEmpty() async throws {
        let store = InMemorySamplerPresetStore()
        let result = try await store.fetchPresets()
        XCTAssertTrue(result.isEmpty)
    }

    func test_insertThenFetch_returnsInsertedRecord() async throws {
        let store = InMemorySamplerPresetStore()
        let preset = SamplerPresetRecord(name: "Creative", temperature: 1.1)
        try await store.insertPreset(preset)

        let fetched = try await store.fetchPresets()
        XCTAssertEqual(fetched.map(\.id), [preset.id])
        XCTAssertEqual(fetched.first?.temperature, 1.1)
    }

    func test_fetch_ordersMostRecentlyCreatedFirst() async throws {
        let store = InMemorySamplerPresetStore()
        let older = SamplerPresetRecord(
            name: "Older",
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let newer = SamplerPresetRecord(
            name: "Newer",
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )
        try await store.insertPreset(older)
        try await store.insertPreset(newer)

        let fetched = try await store.fetchPresets()
        XCTAssertEqual(fetched.map(\.id), [newer.id, older.id])
    }

    func test_delete_unknownID_throwsPresetNotFound() async throws {
        let store = InMemorySamplerPresetStore()
        let id = UUID()
        do {
            try await store.deletePreset(id)
            XCTFail("delete of unknown id must throw")
        } catch let SamplerPresetStoreError.presetNotFound(missingID) {
            XCTAssertEqual(missingID, id)
        } catch {
            XCTFail("expected SamplerPresetStoreError.presetNotFound, got \(error)")
        }
    }

    func test_samplerPresetStoreError_errorDescription_includesUUID() throws {
        let id = UUID()
        let error = SamplerPresetStoreError.presetNotFound(id)
        let message = try XCTUnwrap(error.errorDescription)
        XCTAssertTrue(message.contains(id.uuidString))
    }

    func test_samplerPresetStoreError_equatable() {
        let id = UUID()
        XCTAssertEqual(
            SamplerPresetStoreError.presetNotFound(id),
            SamplerPresetStoreError.presetNotFound(id)
        )
        XCTAssertNotEqual(
            SamplerPresetStoreError.presetNotFound(id),
            SamplerPresetStoreError.presetNotFound(UUID())
        )
    }
}
