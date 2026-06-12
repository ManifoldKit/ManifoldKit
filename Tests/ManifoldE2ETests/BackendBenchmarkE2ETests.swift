/// Backend throughput benchmarks — local developer use only, never run in CI.
///
/// Measures TTFT and tokens/sec for each compiled-in backend through the
/// ManifoldKit SDK. Results are printed via a `BENCH_RESULT` sentinel line
/// that `scripts/benchmark.sh` greps to assemble a Markdown table.
///
/// ## Running individually
///
/// ```bash
/// # Ollama backend (requires Ollama at localhost:11434):
/// MANIFOLD_BENCH_OLLAMA_MODEL=llama3.1:8b \
///   xcrun swift test \
///   --filter OllamaBackendBenchmark --skip-update
///
/// ```
///
/// The MLX / llama.cpp backend benchmarks moved to the manifold-mlx /
/// manifold-llama companion packages with the backends (v0.48, PR C2).
import XCTest
import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends

// MARK: - Shared helpers

private let benchPrompt = "Write a short story about a robot learning to paint. Be concise."
private let benchRuns   = 4
private let benchTokens = 300

@MainActor
private func timedGenerate(
    backend: any InferenceBackend,
    maxOutputTokens: Int = benchTokens
) async throws -> (ttftMs: Double, totalMs: Double, tokens: Int) {
    let config = GenerationConfig(temperature: 0.3, maxOutputTokens: maxOutputTokens)
    let t0 = ContinuousClock.now
    var t1: ContinuousClock.Instant?
    var count = 0

    let stream = try backend.generate(prompt: benchPrompt, systemPrompt: nil, config: config)
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

private func printResults(
    label: String, model: String,
    results: [(ttftMs: Double, totalMs: Double, tokens: Int)]
) {
    for (i, r) in results.enumerated() {
        let tps = Double(r.tokens) / (r.totalMs / 1000)
        print(String(format: "  [%@ run %d] TTFT=%.0fms  total=%.0fms  tokens=%d  TPS=%.1f",
                     label, i + 1, r.ttftMs, r.totalMs, r.tokens, tps))
    }
    let sortedTTFT = results.map(\.ttftMs).sorted()
    let sortedTPS  = results.map { Double($0.tokens) / ($0.totalMs / 1000) }.sorted()
    // Compute true median: average the two middle values for even counts,
    // matching Python's statistics.median() behaviour.
    func median(_ xs: [Double]) -> Double {
        let n = xs.count
        return n.isMultiple(of: 2) ? (xs[n / 2 - 1] + xs[n / 2]) / 2 : xs[n / 2]
    }
    // BENCH_RESULT sentinel — grep'd by benchmark.sh to assemble the table.
    print(String(format: "BENCH_RESULT label=%@ model=%@ median_ttft_ms=%.0f median_tps=%.1f",
                 label, model, median(sortedTTFT), median(sortedTPS)))
}

// MARK: - Ollama backend

@MainActor
final class OllamaBackendBenchmark: XCTestCase {

    private var backend: OllamaBackend!
    private var modelName: String = "unknown"

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(HardwareRequirements.hasOllamaServer,
                          "Ollama server not running at localhost:11434")
        // Prefer explicit model from MANIFOLD_BENCH_OLLAMA_MODEL (set by benchmark.sh),
        // otherwise auto-discover the first available model.
        let envModel = ProcessInfo.processInfo.environment["MANIFOLD_BENCH_OLLAMA_MODEL"] ?? ""
        if !envModel.isEmpty {
            modelName = envModel
        } else if let found = HardwareRequirements.findOllamaModel() {
            modelName = found
        } else {
            throw XCTSkip("No Ollama model — set MANIFOLD_BENCH_OLLAMA_MODEL=<name>")
        }
        backend = OllamaBackend()
        backend.configure(baseURL: URL(string: "http://localhost:11434")!, modelName: modelName)
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
    }

    override func tearDown() async throws {
        backend?.unloadModel(); backend = nil
        try await super.tearDown()
    }

    func test_throughput() async throws {
        let config = GenerationConfig(temperature: 0.3, maxOutputTokens: benchTokens)
        // Warmup
        let warmup = try backend.generate(prompt: benchPrompt, systemPrompt: nil, config: config)
        for try await _ in warmup.events {}

        var results: [(ttftMs: Double, totalMs: Double, tokens: Int)] = []
        for _ in 1...benchRuns {
            results.append(try await timedGenerate(backend: backend))
        }
        printResults(label: "ManifoldKit→Ollama", model: modelName, results: results)
        XCTAssertGreaterThan(results.map { Double($0.tokens) / ($0.totalMs / 1000) }.max() ?? 0, 5)
    }
}


// MARK: - Foundation backend (Apple Intelligence)

#if canImport(FoundationModels)
@available(iOS 26, macOS 26, *)
@MainActor
final class FoundationBackendBenchmark: XCTestCase {

    private var backend: FoundationBackend!

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(
            FoundationBackend.isAvailable,
            "Apple Intelligence is not available on this device"
        )
        let ready = await FoundationBackend.probeIsReady()
        try XCTSkipUnless(ready, "Apple Intelligence is not ready — download may be in progress")

        backend = FoundationBackend()
        try await backend.loadModel(from: ModelInfo.builtInFoundation.url, plan: .cloud())
    }

    override func tearDown() async throws {
        backend?.unloadModel()
        backend = nil
        try await super.tearDown()
    }

    func test_throughput() async throws {
        let config = GenerationConfig(temperature: 0.3, maxOutputTokens: benchTokens)
        let warmup = try backend.generate(prompt: benchPrompt, systemPrompt: nil, config: config)
        for try await _ in warmup.events {}

        var results: [(ttftMs: Double, totalMs: Double, tokens: Int)] = []
        for _ in 1...benchRuns {
            results.append(try await timedGenerate(backend: backend))
        }
        printResults(label: "ManifoldKit→Foundation", model: "apple-intelligence", results: results)
        XCTAssertGreaterThan(results.map { Double($0.tokens) / ($0.totalMs / 1000) }.max() ?? 0, 1)
    }
}
#endif
