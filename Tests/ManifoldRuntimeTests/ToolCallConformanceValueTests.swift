import XCTest
@testable import ManifoldRuntime

/// Codable round-trip coverage for the tool-call conformance value types
/// (`ToolCallConformance` / `ToolCallConformanceKey`).
///
/// These are the dialect vocabulary the companion backends (manifold-mlx /
/// manifold-llama) consume, so they stay `public` and stay tested. The
/// `ToolCallConformanceCache` port + its in-memory/SwiftData adapters were
/// removed 2026-07-22 (issue #2128 inert-surface sweep, zero adopters); their
/// tests went with them. This file retains only the value-type coverage.
final class ToolCallConformanceValueTests: XCTestCase {

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

    func testUnknownDefaultIsLazyUnknown() {
        let d = ToolCallConformance.unknownDefault
        XCTAssertEqual(d.capability, .unknown)
        XCTAssertEqual(d.source, .templateExpressible)
        XCTAssertEqual(d.sampleCount, 0)
    }
}
