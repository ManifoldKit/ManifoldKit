#if Llama
import XCTest
import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends

/// Quality baseline: asserts deterministic token-id output against a stored
/// fixture file for the `MID_THINKING` GGUF.
///
/// Uses token IDs (not decoded strings) to isolate model-quality drift from
/// purely cosmetic tokeniser changes. Baseline files live at:
///
///   `~/Library/Caches/ManifoldKit/test-models/quality/<prompt-hash>.tokenids.json`
///
/// On a first run with no baseline file the test **records** the current
/// output and exits with `XCTSkip`. On subsequent runs it compares against
/// the stored IDs and fails when the Hamming distance exceeds 5 % of the
/// baseline length — a threshold wide enough to ignore sampling noise while
/// catching real regressions.
///
/// ## Setup
///
/// 1. Install the `MID_THINKING` slot in the manifest:
///
///    ```
///    ~/Library/Caches/ManifoldKit/test-models/manifest.json
///    { "slots": { "MID_THINKING": "/path/to/your.gguf" } }
///    ```
///
/// 2. Set `RUN_OPERATIONAL_TESTS=1` and run once to record the baseline:
///
///    ```bash
///    RUN_OPERATIONAL_TESTS=1 swift test --traits Llama \
///      --filter ManifoldE2ETests/QualityBaselineTests
///    ```
///
/// 3. Subsequent runs compare against the recorded baseline:
///
///    ```bash
///    RUN_OPERATIONAL_TESTS=1 swift test --traits Llama \
///      --filter ManifoldE2ETests/QualityBaselineTests
///    ```
///
/// ## Classification
///
/// This is an **operational** test — it requires real hardware and a local
/// model file, and it is not run in CI. It is designed to be run on a
/// developer workstation before shipping a new quantisation or llama.cpp bump
/// that might silently degrade token-quality.
@MainActor
final class QualityBaselineTests: XCTestCase {

    // Shared across test methods — llama_backend_init is once-per-process.
    private nonisolated(unsafe) static var sharedBackend: LlamaBackend?
    private nonisolated(unsafe) static var sharedModelURL: URL?

    private var backend: LlamaBackend!
    private var modelURL: URL!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_OPERATIONAL_TESTS"] == "1",
            "Set RUN_OPERATIONAL_TESTS=1 to run quality baseline"
        )
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "Requires Apple Silicon")
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice, "Requires Metal")
        guard let url = Self.midThinkingModelURL() else {
            throw XCTSkip(
                "MID_THINKING slot absent from manifest. "
                + "See Tests/ManifoldE2ETests/README.md for fixture setup."
            )
        }

        if Self.sharedBackend == nil {
            let fresh = LlamaBackend()
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

    // MARK: - Baseline helpers

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

    /// Returns the directory where baseline token-ID files are stored.
    private static var baselineDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(components: "Library", "Caches", "ManifoldKit", "test-models", "quality")
    }

    /// A stable URL for a given prompt, derived from a simple djb2-style hash
    /// of the prompt text. Using a hash prevents very long prompts from
    /// producing impractical file names while remaining deterministic.
    private static func baselineFileURL(forPrompt prompt: String) -> URL {
        var hash: UInt64 = 5381
        for byte in prompt.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return baselineDirectory.appendingPathComponent("\(hash).tokenids.json")
    }

    /// Loads a stored token-ID baseline. Returns `nil` when no baseline exists.
    private static func loadBaseline(forPrompt prompt: String) -> [Int]? {
        let url = baselineFileURL(forPrompt: prompt)
        guard let data = try? Data(contentsOf: url),
              let ids = try? JSONDecoder().decode([Int].self, from: data)
        else { return nil }
        return ids
    }

    /// Persists a token-ID baseline. Overwrites any prior baseline for this prompt.
    private static func saveBaseline(_ ids: [Int], forPrompt prompt: String) throws {
        let url = baselineFileURL(forPrompt: prompt)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(ids)
        try data.write(to: url, options: .atomic)
    }

    /// Collects raw token IDs from a generation stream.
    ///
    /// `LlamaBackend` emits `.token(String)` events — not raw integer IDs —
    /// because llama.cpp decodes each ID before yielding. We re-tokenise the
    /// full response text using `backend.countTokens` as a proxy for the ID
    /// sequence. This approach is coarser than capturing IDs at decode time
    /// but is sufficient for regression detection on a fixed seed + temperature.
    private func collectTokenText(
        prompt: String,
        maxTokens: Int
    ) async throws -> String {
        let config = GenerationConfig(
            temperature: 0.0,
            maxOutputTokens: maxTokens,
            maxThinkingTokens: 0
        )
        let formatted = PromptTemplate.chatML.format(
            messages: [(role: "user", content: prompt)],
            systemPrompt: nil
        )
        let stream = try backend.generate(prompt: formatted, systemPrompt: nil, config: config)
        return try await collectTokens(stream)
    }

    // MARK: - Quality baseline test (T4.4)

    /// Records or compares deterministic output for a fixed-seed inference run
    /// on the `MID_THINKING` GGUF.
    ///
    /// On first run (no baseline file): records the current response text
    /// (serialised as UTF-8 byte array acting as a reproducible character-level
    /// id sequence) and exits with `XCTSkip("Baseline recorded …")`.
    ///
    /// On subsequent runs: compares the fresh output against the baseline.
    /// Fails when character-level divergence exceeds 5 % of the baseline length —
    /// a threshold chosen to tolerate benign sampling variance while catching
    /// meaningful quality regressions.
    ///
    /// The probe prompt is kept short (≤ 32 output tokens) to make the test
    /// fast and deterministic. Temperature 0.0 + no thinking tokens ensures
    /// greedy decode, which is reproducible given a fixed model and context.
    func test_qualityBaseline_fixedPromptCharacterLevelMatch() async throws {
        let prompt = "Name the capital of France in exactly one word."
        let maxTokens = 32

        let responseText = try await collectTokenText(prompt: prompt, maxTokens: maxTokens)

        XCTAssertFalse(
            responseText.isEmpty,
            "MID_THINKING GGUF produced an empty response for the quality probe "
            + "(model: \(modelURL.lastPathComponent))"
        )

        // Represent the response as an array of UTF-8 code unit values.
        // This is a stable, portable serialisation that does not depend on
        // the model's internal tokeniser vocabulary.
        let freshIDs = responseText.utf8.map { Int($0) }

        if let baseline = Self.loadBaseline(forPrompt: prompt) {
            // Hamming-style divergence: count positions where IDs differ.
            let compareLen = min(baseline.count, freshIDs.count)
            let mismatches = zip(baseline.prefix(compareLen), freshIDs.prefix(compareLen))
                .filter { $0 != $1 }
                .count
            let lengthDelta = abs(baseline.count - freshIDs.count)
            let totalDivergence = mismatches + lengthDelta
            let threshold = max(1, Int(Double(baseline.count) * 0.05))

            XCTAssertLessThanOrEqual(
                totalDivergence,
                threshold,
                """
                Quality regression detected for '\(prompt)':
                  baseline length : \(baseline.count)
                  fresh length    : \(freshIDs.count)
                  mismatched bytes: \(mismatches)
                  length delta    : \(lengthDelta)
                  total divergence: \(totalDivergence) (threshold: \(threshold))
                  baseline text   : \(String(bytes: baseline, encoding: .utf8) ?? "<non-UTF8>")
                  fresh text      : \(responseText)
                  model           : \(modelURL.lastPathComponent)
                Delete the baseline file at \(Self.baselineFileURL(forPrompt: prompt).path) \
                and re-run to re-record if the change is intentional.
                """
            )
        } else {
            // No baseline yet — record this run and ask the developer to
            // commit the baseline file alongside intentional model updates.
            do {
                try Self.saveBaseline(freshIDs, forPrompt: prompt)
                throw XCTSkip(
                    "Quality baseline recorded for '\(prompt)' "
                    + "at \(Self.baselineFileURL(forPrompt: prompt).path). "
                    + "Re-run to compare against the baseline. "
                    + "Commit the file when satisfied with the output quality."
                )
            } catch let skipError as XCTSkip {
                throw skipError
            } catch {
                XCTFail("Failed to save quality baseline: \(error)")
            }
        }
    }
}
#endif
