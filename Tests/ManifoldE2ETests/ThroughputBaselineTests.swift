#if Llama
import XCTest
import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends

/// Throughput baseline: measures real-model token generation rate.
///
/// Reports tokens/sec via `XCTMeasure` so Xcode records historical baselines
/// and alerts on regressions. A regression alert fires when throughput drops
/// >20% from the stored baseline (XCTest's built-in baseline management).
///
/// ## Setup
///
/// Requires both:
/// 1. `RUN_OPERATIONAL_TESTS=1` env var
/// 2. `MID_THINKING` slot in `~/Library/Caches/ManifoldKit/test-models/manifest.json`
///
/// ```bash
/// RUN_OPERATIONAL_TESTS=1 swift test --traits Llama \
///   --filter ManifoldE2ETests/ThroughputBaselineTests
/// ```
///
/// The first run establishes the `XCTMeasure` baseline in Xcode. Subsequent
/// runs compare against the stored baseline and emit a warning when throughput
/// drops more than the configured `maxDeviation`.
///
/// ## Classification
///
/// This is an **operational** test (T4.5 in the T4 operational tier). It
/// requires real Apple Silicon hardware and a local GGUF — it is intentionally
/// not run in CI. Use it before shipping a new llama.cpp bump, context-size
/// change, or quantisation variant that might silently regress generation speed.
@MainActor
final class ThroughputBaselineTests: XCTestCase {

    // Shared across test methods — llama_backend_init is once-per-process.
    private nonisolated(unsafe) static var sharedBackend: LlamaBackend?
    private nonisolated(unsafe) static var sharedModelURL: URL?

    private var backend: LlamaBackend!
    private var modelURL: URL!

    // Number of tokens to generate per measurement iteration. Enough to get a
    // stable token/sec reading without making each iteration too slow.
    private let targetTokenCount = 128

    // Number of warm-up iterations to run before `XCTMeasure` starts timing.
    // One warm-up ensures the Metal JIT and KV-cache allocation are paid before
    // measurement begins, making results more consistent across runs.
    private let warmUpIterations = 1

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_OPERATIONAL_TESTS"] == "1",
            "Set RUN_OPERATIONAL_TESTS=1 to run throughput baseline"
        )
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "Requires Apple Silicon")
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice, "Requires Metal")
        guard let url = Self.midThinkingModelURL() else {
            throw XCTSkip(
                "MID_THINKING slot absent from manifest. "
                + "Set the path in ~/Library/Caches/ManifoldKit/test-models/manifest.json. "
                + "See Tests/ManifoldE2ETests/README.md for setup instructions."
            )
        }

        if Self.sharedBackend == nil {
            let fresh = LlamaBackend()
            // Load with a generous context so the throughput measurement is not
            // affected by context-exhaustion preflight rejections on long warm-up
            // prompts.
            try await fresh.loadModel(from: url, plan: .testStub(effectiveContextSize: 4096))
            Self.sharedBackend = fresh
            Self.sharedModelURL = url
        }
        backend = Self.sharedBackend
        modelURL = Self.sharedModelURL
    }

    override func tearDown() async throws {
        backend = nil
        modelURL = nil
        try await super.tearDown()
    }

    // MARK: - Cleanup

    func test_zzz_drainCleanup() async throws {
        guard let b = Self.sharedBackend else {
            throw XCTSkip("Shared backend never loaded")
        }
        await b.unloadAndWait()
        Self.sharedBackend = nil
        Self.sharedModelURL = nil
    }

    // MARK: - Manifest helper

    /// Returns the `MID_THINKING` model URL from the test manifest, or `nil`
    /// when the manifest is absent or the slot is unset.
    private static func midThinkingModelURL() -> URL? {
        let manifestURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(components: "Library", "Caches", "ManifoldKit", "test-models", "manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let slots = json["slots"] as? [String: Any?],
              let path = slots["MID_THINKING"] as? String,
              !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    // MARK: - Helpers

    /// Runs one generation against the shared backend and returns the token count
    /// and elapsed wall-clock milliseconds.
    ///
    /// Uses `temperature: 0.0` + `maxThinkingTokens: 0` for greedy, reproducible
    /// decode. The prompt is formatted with ChatML because that is what the shared
    /// Qwen/smollm2 GGUF fixtures expect (see `LlamaE2ETests`).
    private func generateAndMeasure(
        prompt: String
    ) async throws -> (tokenCount: Int, elapsedMs: Double) {
        let formatted = PromptTemplate.chatML.format(
            messages: [(role: "user", content: prompt)],
            systemPrompt: nil
        )
        let config = GenerationConfig(
            temperature: 0.0,
            maxOutputTokens: targetTokenCount,
            // maxThinkingTokens: 0 prevents thinking-capable GGUFs from spending
            // the whole budget on a <think> block before producing visible output.
            // See LlamaE2ETests for the full rationale (#1135).
            maxThinkingTokens: 0
        )

        let start = ContinuousClock.now
        var count = 0
        let stream = try backend.generate(prompt: formatted, systemPrompt: nil, config: config)
        for try await event in stream.events {
            if case .token = event {
                count += 1
            }
        }
        let elapsed = ContinuousClock.now - start

        func ms(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
        }
        return (count, ms(elapsed))
    }

    // MARK: - Throughput baseline test (T4.5)

    /// Measures warm token-generation throughput (tokens/sec) for the
    /// `MID_THINKING` GGUF using `XCTMeasure`.
    ///
    /// The test runs `warmUpIterations` ignored iterations first to amortise
    /// Metal JIT compilation and KV-cache allocation. Then it invokes
    /// `XCTMeasure` with `XCTClockMetric()` to capture wall-clock time per
    /// iteration. After measurement it verifies that the observed throughput
    /// exceeds a sanity floor of 3 tokens/sec — a deliberately low bar that
    /// catches total inference failure (hang, crash, empty stream) while
    /// avoiding false positives from slow developer machines.
    ///
    /// Xcode's built-in `maxDeviation` (20% by default) governs regression
    /// alerting against the stored baseline; the `XCTAssertGreaterThan` at the
    /// end is an independent sanity floor for the current run.
    func test_throughputBaseline_warmTokensPerSec() async throws {
        let measurePrompt = "Write a short haiku about a mountain."

        // Warm-up: ensure JIT compilation and KV-cache allocation are
        // complete before measurement starts.
        for _ in 0..<warmUpIterations {
            let (_, _) = try await generateAndMeasure(prompt: measurePrompt)
        }

        // Capture results inside the measure block so XCTest can record the
        // clock-based performance metric.
        var totalTokens = 0
        var totalMs = 0.0

        // XCTMeasure runs the block `options.iterationCount` times (default: 5).
        // We accumulate tokens and time to compute a per-run tokens/sec outside
        // the block.
        measure(metrics: [XCTClockMetric()]) {
            // XCTMeasure's block is synchronous, but `generateAndMeasure` is
            // async. Bridge with a semaphore so the measurement body can call
            // the async helper without requiring Swift Testing.
            let sem = DispatchSemaphore(value: 0)
            final class Box: @unchecked Sendable {
                var count = 0
                var ms = 0.0
                var error: Error?
            }
            let box = Box()
            Task { @MainActor [weak self] in
                guard let self else { sem.signal(); return }
                do {
                    let (count, ms) = try await self.generateAndMeasure(prompt: measurePrompt)
                    box.count = count
                    box.ms = ms
                } catch {
                    box.error = error
                }
                sem.signal()
            }
            sem.wait()
            totalTokens += box.count
            totalMs += box.ms
        }

        // The measure block already provides Xcode's regression tracking.
        // The assertion below is a hard floor for the current run.
        let averageTPS: Double
        if totalMs > 0 {
            averageTPS = Double(totalTokens) / (totalMs / 1_000)
        } else {
            averageTPS = 0
        }

        XCTAssertGreaterThan(
            averageTPS,
            3.0,
            "Throughput floor: must generate > 3 tokens/sec on Apple Silicon. "
            + "Got \(String(format: "%.1f", averageTPS)) tok/s across \(totalTokens) tokens "
            + "(model: \(modelURL.lastPathComponent))"
        )
    }
}
#endif
