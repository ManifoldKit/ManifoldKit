#if MLX
import XCTest
import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends

/// MLX throughput benchmark — local developer use only.
///
/// Outputs `[MLX run N]` and `MLX summary` sentinel lines that
/// `scripts/benchmark.sh --mlx` greps to build the results table.
@MainActor
final class MLXBackendBenchmark: XCTestCase {

    private nonisolated(unsafe) static var sharedBackend: MLXBackend?
    private nonisolated(unsafe) static var sharedModelURL: URL?

    private var backend: MLXBackend!
    private var modelURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "Requires Apple Silicon")
        try XCTSkipUnless(HardwareRequirements.hasMetalDevice, "Requires Metal GPU")

        guard let dir = HardwareRequirements.findMLXModelDirectory() else {
            throw XCTSkip("No MLX model found — set MLX_TEST_MODEL or MANIFOLD_DISCOVER_LOCAL_MODELS=1")
        }

        if Self.sharedBackend == nil {
            let fresh = MLXBackend()
            try await fresh.loadModel(from: dir, plan: .testStub(effectiveContextSize: 4096))
            Self.sharedBackend = fresh
            Self.sharedModelURL = dir
        }
        backend  = Self.sharedBackend
        modelURL = Self.sharedModelURL
    }

    override func tearDown() async throws {
        backend = nil; modelURL = nil
        try await super.tearDown()
    }

    func test_throughput() async throws {
        let config = GenerationConfig(temperature: 0.3, maxOutputTokens: 300)
        let warmup = try backend.generate(prompt: mlxBenchPrompt, systemPrompt: nil, config: config)
        for try await _ in warmup.events {}

        var results: [(ttftMs: Double, totalMs: Double, tokens: Int)] = []
        for _ in 1...4 {
            results.append(try await mlxTimedGenerate(backend: backend))
        }
        printMLXResults(model: modelURL.lastPathComponent, results: results)
        XCTAssertGreaterThan(results.map { Double($0.tokens) / ($0.totalMs / 1000) }.max() ?? 0, 1)
    }

    func test_zzz_cleanup() async throws {
        guard let b = Self.sharedBackend else { return }
        b.unloadModel()
        Self.sharedBackend = nil
    }
}

private let mlxBenchPrompt = "Write a short story about a robot learning to paint. Be concise."

@MainActor
private func mlxTimedGenerate(
    backend: any InferenceBackend
) async throws -> (ttftMs: Double, totalMs: Double, tokens: Int) {
    let config = GenerationConfig(temperature: 0.3, maxOutputTokens: 300)
    let t0 = ContinuousClock.now
    var t1: ContinuousClock.Instant?
    var count = 0

    let stream = try backend.generate(prompt: mlxBenchPrompt, systemPrompt: nil, config: config)
    for try await event in stream.events {
        if case .token = event {
            if t1 == nil { t1 = ContinuousClock.now }
            count += 1
        }
    }
    let t2 = ContinuousClock.now

    func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
    guard let first = t1 else { return (0, ms(t2 - t0), 0) }
    return (ms(first - t0), ms(t2 - t0), count)
}

private func printMLXResults(model: String, results: [(ttftMs: Double, totalMs: Double, tokens: Int)]) {
    for (i, r) in results.enumerated() {
        let tps = Double(r.tokens) / (r.totalMs / 1000)
        print(String(format: "  [MLX run %d] TTFT=%.0fms  total=%.0fms  tokens=%d  TPS=%.1f",
                     i + 1, r.ttftMs, r.totalMs, r.tokens, tps))
    }
    let sortedTTFT = results.map(\.ttftMs).sorted()
    let sortedTPS  = results.map { Double($0.tokens) / ($0.totalMs / 1000) }.sorted()
    func median(_ xs: [Double]) -> Double {
        let n = xs.count
        return n.isMultiple(of: 2) ? (xs[n / 2 - 1] + xs[n / 2]) / 2 : xs[n / 2]
    }
    // "MLX summary" and "MLX run" are the sentinel patterns benchmark.sh greps for.
    print(String(format: "MLX summary median TTFT=%.0fms median TPS=%.1f model=%@",
                 median(sortedTTFT), median(sortedTPS), model))
}
#endif
