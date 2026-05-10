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
///   xcrun swift test --traits Ollama \
///   --filter OllamaBackendBenchmark --skip-update
///
/// # LlamaBackend (set MANIFOLD_BENCH_LLAMA_MODEL to an absolute .gguf path):
/// MANIFOLD_BENCH_LLAMA_MODEL=~/Documents/Models/llama3.1-8b-instruct-Q4_K_M.gguf \
///   xcrun swift test --traits Llama \
///   --filter LlamaBackendBenchmark --skip-update
/// ```
///
/// MLX requires Xcode — use `scripts/benchmark.sh --mlx` for that path.
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

#if Ollama
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
#endif

// MARK: - Llama backend

#if Llama
@MainActor
final class LlamaBackendBenchmark: XCTestCase {

    // Shared across test methods — llama_backend_init is once-per-process.
    private nonisolated(unsafe) static var sharedBackend: LlamaBackend?
    private nonisolated(unsafe) static var sharedModelURL: URL?

    private var backend: LlamaBackend!
    private var modelURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "Requires Apple Silicon")
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice, "Requires Metal")

        // MANIFOLD_BENCH_LLAMA_MODEL (absolute path) is set by benchmark.sh.
        // Fall back to MANIFOLD_DISCOVER_LOCAL_MODELS + LLAMA_TEST_MODEL hint.
        let url: URL
        let envPath = ProcessInfo.processInfo.environment["MANIFOLD_BENCH_LLAMA_MODEL"] ?? ""
        if !envPath.isEmpty, FileManager.default.fileExists(atPath: envPath) {
            url = URL(fileURLWithPath: envPath)
        } else if let found = HardwareRequirements.findGGUFModel() {
            url = found
        } else {
            throw XCTSkip(
                "No GGUF found. Set MANIFOLD_BENCH_LLAMA_MODEL=<path> or " +
                "MANIFOLD_DISCOVER_LOCAL_MODELS=1 + LLAMA_TEST_MODEL=<name hint>"
            )
        }

        if Self.sharedBackend == nil {
            let fresh = LlamaBackend()
            try await fresh.loadModel(from: url, plan: .testStub(effectiveContextSize: 4096))
            Self.sharedBackend = fresh
            Self.sharedModelURL = url
        }
        backend  = Self.sharedBackend
        modelURL = Self.sharedModelURL
    }

    override func tearDown() async throws {
        backend = nil; modelURL = nil
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
        printResults(label: "ManifoldKit→Llama", model: modelURL.lastPathComponent, results: results)
        XCTAssertGreaterThan(results.map { Double($0.tokens) / ($0.totalMs / 1000) }.max() ?? 0, 5)
    }

    func test_zzz_cleanup() async throws {
        guard let b = Self.sharedBackend else { return }
        await b.unloadAndWait()
        Self.sharedBackend = nil
    }
}
#endif

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
