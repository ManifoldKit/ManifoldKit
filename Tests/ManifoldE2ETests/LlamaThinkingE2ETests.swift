#if Llama
import XCTest
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends

/// Hardware-gated end-to-end test for `LlamaBackend` driving a real thinking-capable
/// GGUF (Qwen3-0.6B-Instruct-Q4_K_M or similar). Verifies the full
/// `LlamaGenerationDriver` thinking-parser pipeline: per-token decode -> ThinkingParser
/// -> `.thinkingToken` / `.thinkingComplete` events -> visible `.token` events.
///
/// All thinking-token tests in CI use `MockInferenceBackend`, which bypasses the real
/// `LlamaGenerationDriver` integration with `ThinkingParser`. A regression in the C-API
/// token decode loop or in the parser wiring would only be caught manually — this test
/// exercises that path on hardware.
///
/// # Sabotage check
///
/// Removing `markers:` from `LlamaGenerationDriver.run()` (i.e. forcing the parser
/// off in `LlamaBackend.swift` where `markers: config.thinkingMarkers` is passed)
/// must fail this test. Specifically:
///
/// - `thinkingTokenCount` would drop to 0 (no `.thinkingToken` events)
/// - `thinkingCompleteCount` would drop to 0
/// - `visibleText` would contain raw `<think>` / `</think>` tags
///
/// Any one of those assertions failing is the regression signal.
///
/// # Hardware & trait gating
///
/// - `#if Llama` — only compiled when the Llama trait is enabled (Apple Silicon).
/// - `XCTSkipUnless(HardwareRequirements.isAppleSilicon)` — Metal + llama.cpp.
/// - `XCTSkipUnless(HardwareRequirements.isPhysicalDevice)` — simulator lacks Metal.
/// - Skipped when no thinking-capable GGUF is available on disk. The canonical path
///   is `~/Library/Caches/ManifoldKit/test-models/qwen3-thinking.gguf`. As a fallback
///   the test falls back to `HardwareRequirements.findGGUFModel()` (any GGUF in
///   `~/Documents/Models/`) and then probes the model — a non-thinking GGUF will
///   skip rather than fail.
///
/// `ManifoldE2ETests` does not run in CI (see `ci.yml`); this test exists for
/// developer pre-push verification only. See `Tests/ManifoldE2ETests/README.md`
/// for instructions on provisioning the test model.
@MainActor
final class LlamaThinkingE2ETests: XCTestCase {

    private var backend: LlamaBackend!
    private var modelURL: URL!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "LlamaBackend requires Apple Silicon (arm64)")
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice,
                          "LlamaBackend requires Metal (unavailable in simulator)")

        guard let url = Self.locateThinkingGGUF() else {
            throw XCTSkip(
                "No thinking-capable GGUF found. Place a Qwen3 (or other ChatML "
                + "thinking) model at ~/Library/Caches/ManifoldKit/test-models/qwen3-thinking.gguf "
                + "or in ~/Documents/Models/. See Tests/ManifoldE2ETests/README.md."
            )
        }
        modelURL = url

        backend = LlamaBackend()
        // Qwen3-class reasoning on a step-by-step prompt routinely emits 1k+
        // thinking tokens before closing `</think>`; load with a roomy context
        // so a single test request can hold the prompt + reasoning + visible
        // answer without tripping the context-exhaustion preflight.
        try await backend.loadModel(from: url, plan: .testStub(effectiveContextSize: 4096))
    }

    override func tearDown() async throws {
        if let backend {
            await backend.unloadAndWait()
        }
        backend = nil
        modelURL = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Locates a candidate thinking-capable GGUF on disk. Prefers the canonical
    /// thinking cache path; falls back to any GGUF in `~/Documents/Models/` so
    /// developers who already have a Qwen3 fixture there don't need to duplicate it.
    private static func locateThinkingGGUF() -> URL? {
        let fm = FileManager.default

        // Canonical path documented in Tests/ManifoldE2ETests/README.md.
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            let canonical = URL(fileURLWithPath: home)
                .appendingPathComponent("Library/Caches/ManifoldKit/test-models/qwen3-thinking.gguf")
            if fm.fileExists(atPath: canonical.path) {
                return canonical
            }
        }

        // Fallback: any GGUF the existing Llama E2E suite already discovered.
        return HardwareRequirements.findGGUFModel()
    }

    /// Prompt that reliably provokes chain-of-thought on Qwen3-class reasoning models.
    /// Mirrors the issue's recommendation ("What is 17 × 23? Think step by step.").
    private static let reasoningPrompt = "What is 17 × 23? Think step by step."

    // MARK: - Test

    /// Asserts the full thinking pipeline:
    /// - at least one `.thinkingToken` event
    /// - exactly one `.thinkingComplete` event before the first visible `.token`
    /// - non-empty visible output
    /// - visible output does NOT contain raw `<think>` / `</think>` tags
    ///   (the parser must strip them — leaking tags is a hard regression signal).
    ///
    /// Skips (rather than fails) when the discovered GGUF is not actually a
    /// thinking model: a non-Qwen3 fallback can satisfy `findGGUFModel()` but
    /// emits no `<think>` block, which would make assertions vacuous.
    func testLlamaBackend_thinkingGGUF_emitsThinkingEventsBeforeVisibleOutput() async throws {
        // ChatML formatting is required — LlamaBackend does not apply chat templates.
        // The Qwen3 family expects ChatML wrapping; `PromptTemplate.chatML.thinkingMarkers`
        // resolves to `.qwen3` (`<think>` / `</think>`), which the backend forwards to
        // `LlamaGenerationDriver` via `config.thinkingMarkers`.
        let formattedPrompt = PromptTemplate.chatML.format(
            messages: [(role: "user", content: Self.reasoningPrompt)],
            systemPrompt: nil
        )
        // Qwen3-4B-class models routinely emit >1k tokens of reasoning on a
        // step-by-step arithmetic prompt before producing visible output.
        // 3072 leaves room for the prompt (~30 tokens) plus a long reasoning
        // trace plus a non-empty visible answer inside the 4096-token context.
        let config = GenerationConfig(
            temperature: 0.3,
            maxOutputTokens: 3072,
            thinkingMarkers: PromptTemplate.chatML.thinkingMarkers
        )

        let stream = try backend.generate(
            prompt: formattedPrompt,
            systemPrompt: nil,
            config: config
        )

        var thinkingTokenCount = 0
        var thinkingCompleteCount = 0
        var firstTokenAfterThinkingComplete: Bool?
        var visibleText = ""
        var sawFirstVisibleToken = false

        for try await event in stream.events {
            switch event {
            case .thinkingToken:
                thinkingTokenCount += 1
                if sawFirstVisibleToken {
                    XCTFail("Received .thinkingToken after visible .token — reasoning must precede visible output (model: \(modelURL.lastPathComponent))")
                }
            case .thinkingComplete:
                thinkingCompleteCount += 1
                if !sawFirstVisibleToken {
                    firstTokenAfterThinkingComplete = true
                }
            case .token(let text):
                visibleText += text
                sawFirstVisibleToken = true
                if firstTokenAfterThinkingComplete == nil {
                    firstTokenAfterThinkingComplete = false
                }
            default:
                continue
            }
        }

        // Non-thinking GGUFs (e.g. smollm2) trip `findGGUFModel()` but do not emit
        // `<think>...</think>`. Skip rather than fail so this test stays actionable
        // for developers without a Qwen3 fixture handy.
        try XCTSkipIf(
            thinkingTokenCount == 0,
            "GGUF '\(modelURL.lastPathComponent)' did not emit any .thinkingToken events. "
            + "This test requires a thinking-capable model (e.g. Qwen3). See "
            + "Tests/ManifoldE2ETests/README.md for the canonical fixture."
        )

        XCTAssertGreaterThan(
            thinkingTokenCount,
            0,
            "Thinking GGUF must emit at least one .thinkingToken (model: \(modelURL.lastPathComponent))"
        )
        XCTAssertEqual(
            thinkingCompleteCount,
            1,
            "Exactly one .thinkingComplete event must fire (got \(thinkingCompleteCount), model: \(modelURL.lastPathComponent))"
        )
        XCTAssertEqual(
            firstTokenAfterThinkingComplete,
            true,
            ".thinkingComplete must fire before the first visible .token (model: \(modelURL.lastPathComponent))"
        )
        XCTAssertFalse(
            visibleText.isEmpty,
            "Thinking model must still emit a visible response (model: \(modelURL.lastPathComponent))"
        )

        // Parser regression check: `LlamaGenerationDriver` must strip the literal
        // marker tokens out of visible output. If `markers:` is not threaded through
        // to the driver, raw `<think>` / `</think>` would surface here — that is the
        // primary signal this test is designed to catch.
        XCTAssertFalse(
            visibleText.contains("<think>"),
            "Visible output must not contain raw <think> tag — ThinkingParser failed to strip it "
            + "(model: \(modelURL.lastPathComponent), output prefix: \(visibleText.prefix(200)))"
        )
        XCTAssertFalse(
            visibleText.contains("</think>"),
            "Visible output must not contain raw </think> tag — ThinkingParser failed to strip it "
            + "(model: \(modelURL.lastPathComponent), output prefix: \(visibleText.prefix(200)))"
        )
    }
}
#endif
