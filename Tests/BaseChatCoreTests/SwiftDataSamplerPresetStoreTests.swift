import XCTest
import SwiftData
@testable import BaseChatCore
import BaseChatInference
import BaseChatTestSupport

@MainActor
final class SwiftDataSamplerPresetStoreTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var store: SwiftDataSamplerPresetStore!

    override func setUp() async throws {
        container = try makeInMemoryContainer()
        context = ModelContext(container)
        store = SwiftDataSamplerPresetStore(modelContext: context)
    }

    override func tearDown() async throws {
        store = nil
        context = nil
        container = nil
    }

    // MARK: - Insert + fetch

    func test_fetchPresets_emptyStore_returnsEmpty() async throws {
        let presets = try await store.fetchPresets()
        XCTAssertTrue(presets.isEmpty)
    }

    func test_insertPreset_persistsAllFields() async throws {
        let record = SamplerPresetRecord(
            name: "Precise",
            temperature: 0.2,
            topP: 0.85,
            repeatPenalty: 1.05
        )

        try await store.insertPreset(record)

        let presets = try await store.fetchPresets()
        XCTAssertEqual(presets.count, 1)
        let fetched = try XCTUnwrap(presets.first)
        XCTAssertEqual(fetched.id, record.id)
        XCTAssertEqual(fetched.name, "Precise")
        XCTAssertEqual(fetched.temperature, 0.2, accuracy: 0.001)
        XCTAssertEqual(fetched.topP, 0.85, accuracy: 0.001)
        XCTAssertEqual(fetched.repeatPenalty, 1.05, accuracy: 0.001)
    }

    func test_fetchPresets_returnsMostRecentFirst() async throws {
        let earliest = SamplerPresetRecord(name: "A", createdAt: Date(timeIntervalSince1970: 100))
        let middle = SamplerPresetRecord(name: "B", createdAt: Date(timeIntervalSince1970: 200))
        let newest = SamplerPresetRecord(name: "C", createdAt: Date(timeIntervalSince1970: 300))

        try await store.insertPreset(earliest)
        try await store.insertPreset(middle)
        try await store.insertPreset(newest)

        let presets = try await store.fetchPresets()
        XCTAssertEqual(presets.map(\.name), ["C", "B", "A"])
    }

    // MARK: - Delete

    func test_deletePreset_removesRow() async throws {
        let record = SamplerPresetRecord(name: "ToRemove")
        try await store.insertPreset(record)

        try await store.deletePreset(record.id)

        let remaining = try await store.fetchPresets()
        XCTAssertTrue(remaining.isEmpty)
    }

    func test_deletePreset_unknownID_throwsPresetNotFound() async throws {
        let bogusID = UUID()

        do {
            try await store.deletePreset(bogusID)
            XCTFail("Expected presetNotFound error")
        } catch let error as SamplerPresetStoreError {
            XCTAssertEqual(error, .presetNotFound(bogusID))
        }
    }

    func test_deletePreset_doesNotAffectOthers() async throws {
        let kept = SamplerPresetRecord(name: "Keeper")
        let removed = SamplerPresetRecord(name: "Goner")
        try await store.insertPreset(kept)
        try await store.insertPreset(removed)

        try await store.deletePreset(removed.id)

        let presets = try await store.fetchPresets()
        XCTAssertEqual(presets.map(\.id), [kept.id])
    }
}
