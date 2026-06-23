import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
import ManifoldRuntime
import ManifoldTestSupport

/// Integration tests for ``SwiftDataToolCallConformanceCache``.
///
/// All tests run against an in-memory SwiftData container so nothing touches
/// the production store. The assertions cover the three contract requirements
/// from ``ToolCallConformanceCache``:
///
/// 1. `get` on an unmeasured key returns ``ToolCallConformance/unknownDefault``.
/// 2. `put` then `get` round-trips the full verdict.
/// 3. `put` is upsert: a second `put` for the same key replaces the row and
///    leaves no stale duplicate in the store.
/// 4. `fetchAll` returns every cached verdict keyed by cell.
@MainActor
final class SwiftDataToolCallConformanceCacheTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var cache: SwiftDataToolCallConformanceCache!

    override func setUp() async throws {
        container = try makeInMemoryContainer()
        context = ModelContext(container)
        cache = SwiftDataToolCallConformanceCache(modelContext: context)
    }

    override func tearDown() async throws {
        cache = nil
        context = nil
        container = nil
    }

    // MARK: - Helpers

    private func key(model: String = "Qwen2.5-7B", quant: String? = "Q4_K_M", backend: String = "llama") -> ToolCallConformanceKey {
        ToolCallConformanceKey(model: model, quant: quant, backend: backend)
    }

    private func measuredConformance(
        capability: ToolCallCapability = .supported,
        dialect: String? = "hermes",
        precision: Double? = 0.95,
        recall: Double? = 0.88,
        f1: Double? = 0.91,
        sampleCount: Int = 20,
        measuredAt: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> ToolCallConformance {
        ToolCallConformance(
            capability: capability,
            observedDialect: dialect,
            source: .measured,
            precision: precision,
            recall: recall,
            f1: f1,
            measuredAt: measuredAt,
            sampleCount: sampleCount
        )
    }

    // MARK: - Get on empty store

    func test_get_unknownKey_returnsUnknownDefault() async {
        let result = await cache.get(key())
        XCTAssertEqual(result, .unknownDefault)
        XCTAssertEqual(result.capability, .unknown)
        XCTAssertEqual(result.sampleCount, 0)
    }

    // MARK: - Round-trip

    func test_putThenGet_roundTripsFullVerdict() async throws {
        let k = key()
        let conformance = measuredConformance()

        await cache.put(k, conformance)

        let fetched = await cache.get(k)
        XCTAssertEqual(fetched.capability, .supported)
        XCTAssertEqual(fetched.observedDialect, "hermes")
        XCTAssertEqual(fetched.source, .measured)
        XCTAssertEqual(fetched.precision, 0.95)
        XCTAssertEqual(fetched.recall, 0.88)
        XCTAssertEqual(fetched.f1, 0.91)
        XCTAssertEqual(fetched.sampleCount, 20)
        XCTAssertEqual(fetched.measuredAt, Date(timeIntervalSince1970: 1_000_000))
    }

    func test_putThenGet_nilQuant_roundTrips() async {
        let k = ToolCallConformanceKey(model: "Phi-4", quant: nil, backend: "ollama")
        let conformance = ToolCallConformance(
            capability: .supported,
            source: .renderConsistent,
            sampleCount: 0
        )

        await cache.put(k, conformance)

        let fetched = await cache.get(k)
        XCTAssertEqual(fetched.capability, .supported)
        XCTAssertEqual(fetched.source, .renderConsistent)
        XCTAssertNil(fetched.observedDialect)
        XCTAssertNil(fetched.precision)
        XCTAssertNil(fetched.recall)
        XCTAssertNil(fetched.f1)
    }

    // MARK: - Upsert semantics

    func test_put_replacesPreviousEntryForSameKey() async throws {
        let k = key()
        let initial = ToolCallConformance(
            capability: .unknown,
            source: .templateExpressible,
            sampleCount: 0
        )
        await cache.put(k, initial)

        let updated = measuredConformance(capability: .supported, sampleCount: 40)
        await cache.put(k, updated)

        let fetched = await cache.get(k)
        XCTAssertEqual(fetched.capability, .supported)
        XCTAssertEqual(fetched.sampleCount, 40)

        // Confirm no stale duplicate row was left in the store.
        // fetchAll() collapses by key in its dictionary return, so the only
        // way to detect a leaked duplicate is to count the raw model rows.
        let allRows = try context.fetch(FetchDescriptor<ToolCallConformanceRecord>())
        XCTAssertEqual(allRows.count, 1, "Upsert must not accumulate stale rows for the same key.")
    }

    func test_put_doesNotAffectOtherKeys() async {
        let k1 = key(model: "Qwen2.5-7B", backend: "llama")
        let k2 = key(model: "Phi-4-mini", backend: "ollama")

        await cache.put(k1, measuredConformance(capability: .supported, sampleCount: 10))
        await cache.put(k2, measuredConformance(capability: .unsupported, sampleCount: 5))

        let r1 = await cache.get(k1)
        let r2 = await cache.get(k2)
        XCTAssertEqual(r1.capability, .supported)
        XCTAssertEqual(r2.capability, .unsupported)
    }

    // MARK: - fetchAll

    func test_fetchAll_emptyStore_returnsEmpty() async {
        let all = await cache.fetchAll()
        XCTAssertTrue(all.isEmpty)
    }

    func test_fetchAll_returnsAllCachedVerdicts() async {
        let k1 = key(model: "ModelA", backend: "llama")
        let k2 = key(model: "ModelB", quant: nil, backend: "ollama")
        let k3 = key(model: "ModelC", quant: "Q8_0", backend: "mlx")

        await cache.put(k1, measuredConformance(capability: .supported))
        await cache.put(k2, measuredConformance(capability: .unsupported))
        await cache.put(k3, ToolCallConformance(capability: .unknown, source: .templateExpressible))

        let all = await cache.fetchAll()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[k1]?.capability, .supported)
        XCTAssertEqual(all[k2]?.capability, .unsupported)
        XCTAssertEqual(all[k3]?.capability, .unknown)
    }

    // MARK: - Key distinctness

    func test_sameModelDifferentQuant_storesSeparateCells() async {
        let kQ4 = key(model: "Llama-3-8B", quant: "Q4_K_M", backend: "llama")
        let kQ8 = key(model: "Llama-3-8B", quant: "Q8_0", backend: "llama")

        await cache.put(kQ4, measuredConformance(capability: .supported, sampleCount: 20))
        await cache.put(kQ8, measuredConformance(capability: .unsupported, sampleCount: 20))

        let r4 = await cache.get(kQ4)
        let r8 = await cache.get(kQ8)
        XCTAssertEqual(r4.capability, .supported)
        XCTAssertEqual(r8.capability, .unsupported)
    }

    func test_sameModelSameQuantDifferentBackend_storesSeparateCells() async {
        let kLlama = key(model: "Qwen2.5-7B", quant: "Q4_K_M", backend: "llama")
        let kOllama = key(model: "Qwen2.5-7B", quant: "Q4_K_M", backend: "ollama")

        await cache.put(kLlama, measuredConformance(capability: .supported, sampleCount: 30))
        await cache.put(kOllama, measuredConformance(capability: .unsupported, sampleCount: 12))

        let rLlama = await cache.get(kLlama)
        let rOllama = await cache.get(kOllama)
        XCTAssertEqual(rLlama.capability, .supported)
        XCTAssertEqual(rOllama.capability, .unsupported)
    }
}
