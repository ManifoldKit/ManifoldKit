import Testing
import Foundation
@testable import ManifoldInference

@Suite("ModelBenchmarkResult")
struct ModelBenchmarkResultTests {

    // MARK: - isStale

    @Test("isStale is false for a freshly created result")
    func isStale_freshResult_isFalse() {
        let result = ModelBenchmarkResult(tier: .fast, measuredAt: Date())
        #expect(!result.isStale)
    }

    @Test("isStale is true for a result measured 8 days ago")
    func isStale_eightDaysAgo_isTrue() {
        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 3_600)
        let result = ModelBenchmarkResult(tier: .balanced, measuredAt: eightDaysAgo)
        #expect(result.isStale)
    }

    @Test("isStale is false for a result measured exactly 6 days ago")
    func isStale_sixDaysAgo_isFalse() {
        let sixDaysAgo = Date().addingTimeInterval(-6 * 24 * 3_600)
        let result = ModelBenchmarkResult(tier: .capable, measuredAt: sixDaysAgo)
        #expect(!result.isStale)
    }

    // MARK: - Codable round-trip

    @Test("Codable round-trip preserves all non-nil fields")
    func codableRoundTrip_allFields() throws {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let original = ModelBenchmarkResult(
            tier: .capable,
            tokensPerSecond: 42.5,
            memoryBytes: 8_000_000_000,
            measuredAt: date
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ModelBenchmarkResult.self, from: data)

        #expect(decoded == original)
        #expect(decoded.tier == .capable)
        #expect(decoded.tokensPerSecond == 42.5)
        #expect(decoded.memoryBytes == 8_000_000_000)
        // Date round-trips via JSON with sub-second precision loss — use tolerance.
        #expect(abs(decoded.measuredAt.timeIntervalSince(date)) < 0.001)
    }

    @Test("Codable round-trip preserves nil optional fields")
    func codableRoundTrip_nilFields() throws {
        let original = ModelBenchmarkResult(tier: .minimal)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ModelBenchmarkResult.self, from: data)

        #expect(decoded.tier == .minimal)
        #expect(decoded.tokensPerSecond == nil)
        #expect(decoded.memoryBytes == nil)
    }
}
