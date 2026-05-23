#if canImport(XCTest)
import XCTest
import ManifoldRuntime
import ManifoldInference

// MARK: - SamplerPresetStoreContract

/// Opt-in XCTestCase mixin that exercises the ``SamplerPresetStore`` protocol
/// contract against any conforming implementation.
///
/// ```swift
/// @MainActor
/// final class InMemorySamplerPresetStoreContractTests: XCTestCase, SamplerPresetStoreContract {
///     func makeSamplerPresetStore() -> any SamplerPresetStore {
///         InMemorySamplerPresetStoreImpl()
///     }
///
///     func test_insertFetch() async throws {
///         try await assertSamplerPresetStore_insertThenFetchReturnsRecord()
///     }
/// }
/// ```
@MainActor
public protocol SamplerPresetStoreContract: AnyObject {
    /// Returns a fresh, empty sampler-preset store for each assertion call.
    func makeSamplerPresetStore() -> any SamplerPresetStore
}

extension SamplerPresetStoreContract where Self: XCTestCase {

    // MARK: - Fixture helpers

    private func makePreset(
        name: String = "Test Preset",
        temperature: Float = 0.7,
        createdAt: Date = Date()
    ) -> SamplerPresetRecord {
        SamplerPresetRecord(name: name, temperature: temperature, createdAt: createdAt)
    }

    // MARK: - Empty-store baseline

    /// Asserts that a fresh store returns an empty array from ``fetchPresets()``.
    public func assertSamplerPresetStore_emptyStoreReturnsNoPresets(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeSamplerPresetStore()
        let result = try await store.fetchPresets()
        XCTAssertTrue(result.isEmpty, "Fresh store must return no presets", file: file, line: line)
    }

    // MARK: - Insert / Fetch

    /// Asserts that an inserted preset is returned by ``fetchPresets()``.
    public func assertSamplerPresetStore_insertThenFetchReturnsRecord(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeSamplerPresetStore()
        let preset = makePreset(name: "Creative")
        try await store.insertPreset(preset)

        let fetched = try await store.fetchPresets()
        XCTAssertEqual(fetched.count, 1, file: file, line: line)
        XCTAssertEqual(fetched.first?.id, preset.id, file: file, line: line)
        XCTAssertEqual(fetched.first?.name, preset.name, file: file, line: line)
    }

    // MARK: - Most-recently-created ordering

    /// Asserts that ``fetchPresets()`` orders presets most-recently-created
    /// first, as documented on the protocol.
    public func assertSamplerPresetStore_fetchOrdersByMostRecentlyCreatedFirst(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeSamplerPresetStore()
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let older = makePreset(name: "Older", createdAt: base)
        let newer = makePreset(name: "Newer", createdAt: base.addingTimeInterval(10))
        try await store.insertPreset(older)
        try await store.insertPreset(newer)

        let fetched = try await store.fetchPresets()
        XCTAssertEqual(
            fetched.map(\.id), [newer.id, older.id],
            "fetchPresets() must return most-recently-created first",
            file: file, line: line
        )
    }

    // MARK: - Delete

    /// Asserts that a deleted preset is no longer returned by ``fetchPresets()``.
    public func assertSamplerPresetStore_deletedPresetNotReturned(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeSamplerPresetStore()
        let preset = makePreset(name: "To delete")
        try await store.insertPreset(preset)
        try await store.deletePreset(preset.id)

        let fetched = try await store.fetchPresets()
        XCTAssertFalse(
            fetched.contains { $0.id == preset.id },
            "Deleted preset must not appear in subsequent fetch",
            file: file, line: line
        )
    }

    /// Asserts that ``deletePreset(_:)`` throws
    /// ``SamplerPresetStoreError/presetNotFound(_:)`` for an unknown ID.
    public func assertSamplerPresetStore_deleteUnknownIDThrowsNotFound(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeSamplerPresetStore()
        let unknownID = UUID()
        do {
            try await store.deletePreset(unknownID)
            XCTFail("delete of unknown id must throw", file: file, line: line)
        } catch SamplerPresetStoreError.presetNotFound(let id) {
            XCTAssertEqual(id, unknownID, file: file, line: line)
        } catch {
            XCTFail("Expected SamplerPresetStoreError.presetNotFound, got \(error)", file: file, line: line)
        }
    }

    // MARK: - Multiple presets

    /// Asserts that inserting multiple presets and fetching all returns all of them.
    public func assertSamplerPresetStore_multiplePresetsAllReturned(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeSamplerPresetStore()
        let presets = [
            makePreset(name: "Conservative"),
            makePreset(name: "Balanced"),
            makePreset(name: "Creative"),
        ]
        for p in presets {
            try await store.insertPreset(p)
        }

        let fetched = try await store.fetchPresets()
        XCTAssertEqual(fetched.count, 3, "All inserted presets must be returned", file: file, line: line)
        let fetchedIDs = Set(fetched.map(\.id))
        let insertedIDs = Set(presets.map(\.id))
        XCTAssertEqual(fetchedIDs, insertedIDs, file: file, line: line)
    }
}
#endif
