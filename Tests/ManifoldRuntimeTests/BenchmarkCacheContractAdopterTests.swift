import XCTest
import ManifoldRuntime
import ManifoldInference
import ManifoldTestSupport
import ManifoldContractTestSupport

// MARK: - InMemoryBenchmarkCache (test double for contract adoption)

@MainActor
private final class InMemoryBenchmarkCache: BenchmarkCache {
    private var storage: [String: ModelBenchmarkResult] = [:]

    func fetchAll() async throws -> [String: ModelBenchmarkResult] {
        storage
    }

    func upsert(modelFileName: String, result: ModelBenchmarkResult) async throws {
        storage[modelFileName] = result
    }
}

// MARK: - InMemoryBenchmarkCacheContractTests

@MainActor
final class InMemoryBenchmarkCacheContractTests: XCTestCase, BenchmarkCacheContract {

    func makeBenchmarkCache() -> any BenchmarkCache {
        InMemoryBenchmarkCache()
    }

    func test_emptyCache_fetchAllReturnsEmpty() async throws {
        try await assertBenchmarkCache_emptyFetchAllReturnsEmptyDictionary()
    }

    func test_upsert_thenFetchAll_returnsEntry() async throws {
        try await assertBenchmarkCache_upsertThenFetchAll()
    }

    func test_upsert_replacesExistingEntry() async throws {
        try await assertBenchmarkCache_upsertReplacesExistingEntry()
    }

    func test_multipleKeys_storedSeparately() async throws {
        try await assertBenchmarkCache_multipleKeysStoredSeparately()
    }

    func test_keys_areCaseSensitive() async throws {
        try await assertBenchmarkCache_keysAreCaseSensitive()
    }
}
