import XCTest
@testable import ManifoldRuntime

final class ToolCallConformanceCacheTests: XCTestCase {

    private func sampleConformance() -> ToolCallConformance {
        ToolCallConformance(
            capability: .supported,
            observedDialect: "hermes",
            source: .measured,
            precision: 0.97,
            recall: 0.93,
            f1: 0.95,
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
            sampleCount: 40
        )
    }

    func testCodableRoundTrip() throws {
        let original = sampleConformance()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ToolCallConformance.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testKeyCodableRoundTrip() throws {
        let key = ToolCallConformanceKey(model: "Qwen2.5-7B-Instruct", quant: "Q4_K_M", backend: "llama")
        let data = try JSONEncoder().encode(key)
        let decoded = try JSONDecoder().decode(ToolCallConformanceKey.self, from: data)
        XCTAssertEqual(decoded, key)
    }

    func testGetAfterPutReturnsStoredValue() async {
        let cache = InMemoryToolCallConformanceCache()
        let key = ToolCallConformanceKey(model: "Qwen2.5-7B-Instruct", quant: "Q4_K_M", backend: "llama")
        let value = sampleConformance()

        await cache.put(key, value)
        let fetched = await cache.get(key)

        XCTAssertEqual(fetched, value)
    }

    func testGetMissingKeyReturnsUnknownDefault() async {
        let cache = InMemoryToolCallConformanceCache()
        let key = ToolCallConformanceKey(model: "never-measured", quant: nil, backend: "mlx")

        let fetched = await cache.get(key)

        XCTAssertEqual(fetched.capability, .unknown)
        XCTAssertEqual(fetched, ToolCallConformance.unknownDefault)
        XCTAssertEqual(fetched.sampleCount, 0)
    }

    func testFetchAllReturnsAllPuts() async {
        let cache = InMemoryToolCallConformanceCache()
        let k1 = ToolCallConformanceKey(model: "a", quant: "Q4_K_M", backend: "llama")
        let k2 = ToolCallConformanceKey(model: "b", quant: nil, backend: "ollama")

        await cache.put(k1, sampleConformance())
        await cache.put(k2, ToolCallConformance(capability: .unsupported, source: .templateExpressible))

        let all = await cache.fetchAll()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[k1]?.capability, .supported)
        XCTAssertEqual(all[k2]?.capability, .unsupported)
    }
}
