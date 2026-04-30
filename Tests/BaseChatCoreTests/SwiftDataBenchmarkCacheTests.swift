import XCTest
import SwiftData
@testable import BaseChatPersistenceSwiftData
import BaseChatInference
import BaseChatTestSupport

@MainActor
final class SwiftDataBenchmarkCacheTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var cache: SwiftDataBenchmarkCache!

    override func setUp() async throws {
        container = try makeInMemoryContainer()
        context = ModelContext(container)
        cache = SwiftDataBenchmarkCache(modelContext: context)
    }

    override func tearDown() async throws {
        cache = nil
        context = nil
        container = nil
    }

    // MARK: - Fetch

    func test_fetchAll_emptyStore_returnsEmpty() async throws {
        let entries = try await cache.fetchAll()
        XCTAssertTrue(entries.isEmpty)
    }

    func test_upsertThenFetch_roundTripsResult() async throws {
        let result = ModelBenchmarkResult(
            tier: .balanced,
            tokensPerSecond: 42.5,
            memoryBytes: 1_024_000,
            measuredAt: Date(timeIntervalSince1970: 1_000)
        )

        try await cache.upsert(modelFileName: "model.gguf", result: result)

        let entries = try await cache.fetchAll()
        XCTAssertEqual(entries.count, 1)
        let fetched = try XCTUnwrap(entries["model.gguf"])
        XCTAssertEqual(fetched.tier, .balanced)
        XCTAssertEqual(fetched.tokensPerSecond, 42.5)
        XCTAssertEqual(fetched.memoryBytes, 1_024_000)
        XCTAssertEqual(fetched.measuredAt, Date(timeIntervalSince1970: 1_000))
    }

    // MARK: - Upsert semantics

    func test_upsert_replacesPreviousEntryForSameFileName() async throws {
        let initial = ModelBenchmarkResult(tier: .minimal, tokensPerSecond: 5.0)
        try await cache.upsert(modelFileName: "phi-mini.gguf", result: initial)

        let updated = ModelBenchmarkResult(tier: .capable, tokensPerSecond: 80.0)
        try await cache.upsert(modelFileName: "phi-mini.gguf", result: updated)

        let entries = try await cache.fetchAll()
        XCTAssertEqual(entries.count, 1)
        let fetched = try XCTUnwrap(entries["phi-mini.gguf"])
        XCTAssertEqual(fetched.tier, .capable)
        XCTAssertEqual(fetched.tokensPerSecond, 80.0)

        // Storage-level assertion: upsert must not leave stale rows behind.
        // fetchAll() coalesces by key in its dictionary return, so a duplicate
        // row would still produce a one-entry dictionary — checking the
        // underlying row count is the only way to detect the leak.
        let allRows = try context.fetch(FetchDescriptor<ModelBenchmarkCache>())
        XCTAssertEqual(allRows.count, 1, "Upsert must not accumulate stale rows for the same key.")
    }

    func test_upsert_doesNotAffectOtherFiles() async throws {
        let alpha = ModelBenchmarkResult(tier: .fast, tokensPerSecond: 10.0)
        let beta = ModelBenchmarkResult(tier: .capable, tokensPerSecond: 50.0)

        try await cache.upsert(modelFileName: "alpha.gguf", result: alpha)
        try await cache.upsert(modelFileName: "beta.gguf", result: beta)

        let entries = try await cache.fetchAll()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries["alpha.gguf"]?.tier, .fast)
        XCTAssertEqual(entries["beta.gguf"]?.tier, .capable)
    }
}
