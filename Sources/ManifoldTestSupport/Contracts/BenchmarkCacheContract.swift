#if canImport(XCTest)
import XCTest
import ManifoldRuntime
import ManifoldInference

// MARK: - BenchmarkCacheContract

/// Opt-in XCTestCase mixin that exercises the ``BenchmarkCache`` protocol
/// contract against any conforming implementation.
///
/// ```swift
/// @MainActor
/// final class InMemoryBenchmarkCacheContractTests: XCTestCase, BenchmarkCacheContract {
///     func makeBenchmarkCache() -> any BenchmarkCache {
///         InMemoryBenchmarkCacheImpl()
///     }
///
///     func test_upsertFetch() async throws {
///         try await assertBenchmarkCache_upsertThenFetchAll()
///     }
/// }
/// ```
@MainActor
public protocol BenchmarkCacheContract: AnyObject {
    /// Returns a fresh, empty benchmark cache for each assertion call.
    func makeBenchmarkCache() -> any BenchmarkCache
}

extension BenchmarkCacheContract where Self: XCTestCase {

    // MARK: - Fixture helpers

    private func makeResult(
        tier: ModelCapabilityTier = .balanced,
        tokensPerSecond: Double? = 42.0
    ) -> ModelBenchmarkResult {
        ModelBenchmarkResult(
            tier: tier,
            tokensPerSecond: tokensPerSecond,
            memoryBytes: nil,
            measuredAt: Date()
        )
    }

    // MARK: - Empty-store baseline

    /// Asserts that a fresh cache returns an empty dictionary from ``fetchAll()``.
    public func assertBenchmarkCache_emptyFetchAllReturnsEmptyDictionary(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let cache = makeBenchmarkCache()
        let result = try await cache.fetchAll()
        XCTAssertTrue(result.isEmpty, "Fresh cache must return an empty dictionary", file: file, line: line)
    }

    // MARK: - Upsert / Fetch

    /// Asserts that an upserted result is returned by ``fetchAll()`` under the
    /// correct key.
    public func assertBenchmarkCache_upsertThenFetchAll(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let cache = makeBenchmarkCache()
        let fileName = "model-q4.gguf"
        let result = makeResult(tier: .balanced)
        try await cache.upsert(modelFileName: fileName, result: result)

        let all = try await cache.fetchAll()
        XCTAssertEqual(all.count, 1, file: file, line: line)
        XCTAssertEqual(all[fileName]?.tier, result.tier, file: file, line: line)
    }

    // MARK: - Upsert replaces existing entry

    /// Asserts that calling ``upsert(modelFileName:result:)`` twice with the
    /// same key replaces the previous entry (upsert semantics).
    public func assertBenchmarkCache_upsertReplacesExistingEntry(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let cache = makeBenchmarkCache()
        let fileName = "model-q4.gguf"
        let first = makeResult(tier: .fast)
        let second = makeResult(tier: .frontier)

        try await cache.upsert(modelFileName: fileName, result: first)
        try await cache.upsert(modelFileName: fileName, result: second)

        let all = try await cache.fetchAll()
        XCTAssertEqual(all.count, 1,
                       "Upsert with same key must replace, not append",
                       file: file, line: line)
        XCTAssertEqual(all[fileName]?.tier, .frontier, file: file, line: line)
    }

    // MARK: - Multiple keys

    /// Asserts that entries for distinct model file names are stored and
    /// retrieved independently.
    public func assertBenchmarkCache_multipleKeysStoredSeparately(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let cache = makeBenchmarkCache()
        let fileA = "model-a.gguf"
        let fileB = "model-b.gguf"
        try await cache.upsert(modelFileName: fileA, result: makeResult(tier: .fast))
        try await cache.upsert(modelFileName: fileB, result: makeResult(tier: .frontier))

        let all = try await cache.fetchAll()
        XCTAssertEqual(all.count, 2, file: file, line: line)
        XCTAssertEqual(all[fileA]?.tier, .fast, file: file, line: line)
        XCTAssertEqual(all[fileB]?.tier, .frontier, file: file, line: line)
    }

    // MARK: - Key is the model file name (case-sensitive)

    /// Asserts that the key used for lookup is the exact file name string passed
    /// to ``upsert(modelFileName:result:)``; different casing is a different key.
    public func assertBenchmarkCache_keysAreCaseSensitive(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let cache = makeBenchmarkCache()
        let lower = "model.gguf"
        let upper = "MODEL.gguf"
        try await cache.upsert(modelFileName: lower, result: makeResult(tier: .fast))

        let all = try await cache.fetchAll()
        XCTAssertNotNil(all[lower],
                        "Exact-case key must be present",
                        file: file, line: line)
        // upper may or may not exist — we only assert the lower-case entry is
        // keyed correctly, not that the upper-case one is absent (that would
        // over-specify the implementation).
        _ = upper  // suppress unused-variable warning
    }
}
#endif
