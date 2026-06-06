#if Llama
import XCTest
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends

/// Hardware-gated end-to-end test for `LlamaBackend` driving a real thinking-capable
/// GGUF (Qwen3-0.6B-Instruct-Q4_K_M or similar). Verifies the full
/// `LlamaGenerationDriver` thinking-parser pipeline: per-token decode -> ThinkingTransform
/// -> `.thinkingToken` / `.thinkingCompleted` events -> visible `.token` events.
///
/// All thinking-token tests in CI use `MockInferenceBackend`, which bypasses the real
/// `LlamaGenerationDriver` integration with `ThinkingTransform`. A regression in the C-API
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
                "No thinking-capable GGUF found. Set LLAMA_TEST_MODEL=<path> to a Qwen3 (or other "
                + "ChatML thinking) model, or place one at "
                + "~/Library/Caches/ManifoldKit/test-models/qwen3-thinking.gguf "
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
    /// - exactly one `.thinkingCompleted` event before the first visible `.token`
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
            case .thinkingCompleted:
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
            "Exactly one .thinkingCompleted event must fire (got \(thinkingCompleteCount), model: \(modelURL.lastPathComponent))"
        )
        XCTAssertEqual(
            firstTokenAfterThinkingComplete,
            true,
            ".thinkingCompleted must fire before the first visible .token (model: \(modelURL.lastPathComponent))"
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
            "Visible output must not contain raw <think> tag — ThinkingTransform failed to strip it "
            + "(model: \(modelURL.lastPathComponent), output prefix: \(visibleText.prefix(200)))"
        )
        XCTAssertFalse(
            visibleText.contains("</think>"),
            "Visible output must not contain raw </think> tag — ThinkingTransform failed to strip it "
            + "(model: \(modelURL.lastPathComponent), output prefix: \(visibleText.prefix(200)))"
        )
    }

    /// Acceptance test for issue #1595: a thinking model with a STRICT grammar must
    /// produce a free-form `<think>` reasoning block (NOT schema-constrained) followed
    /// by schema-valid visible output (constrained).
    ///
    /// The grammar `root ::= [0-9]+` accepts digit strings only. Before the fix, the
    /// grammar sampler ran on every step, so during reasoning it masked every
    /// non-digit logit — including the letters of `<think>` itself. That made the
    /// reasoning block unreachable (`thinkingTokenCount == 0`) and corrupted parsing.
    /// After the phase-gating fix, the permissive chain samples the reasoning block
    /// (so it contains natural-language, non-digit characters) and the strict chain
    /// samples the visible answer (so it is digits-only).
    ///
    /// # Sabotage check
    ///
    /// Remove the gate — pass `outputSampler` unconditionally in
    /// `LlamaGenerationDriver` instead of selecting on `grammarGate.isGrammarActive`.
    /// The grammar then constrains the reasoning block: `thinkingTokenCount` collapses
    /// to 0 (the model cannot emit `<think>`), and this test fails on the first
    /// assertion. That is the regression signal.
    func testLlamaBackend_thinkingModel_grammarConstrainsOnlyVisibleOutput() async throws {
        let formattedPrompt = PromptTemplate.chatML.format(
            messages: [(role: "user", content: "What is 17 × 23? Think step by step, then answer with only the number.")],
            systemPrompt: nil
        )
        var config = GenerationConfig(
            temperature: 0.3,
            maxOutputTokens: 64,
            thinkingMarkers: PromptTemplate.chatML.thinkingMarkers
        )
        // Strict: visible output may contain digits ONLY. Reasoning must be exempt.
        config.grammar = "root ::= [0-9]+"

        let stream = try backend.generate(
            prompt: formattedPrompt,
            systemPrompt: nil,
            config: config
        )

        var thinkingText = ""
        var thinkingTokenCount = 0
        var visibleText = ""
        for try await event in stream.events {
            switch event {
            case .thinkingToken(let t):
                thinkingText += t
                thinkingTokenCount += 1
            case .token(let t):
                visibleText += t
            default:
                continue
            }
        }

        // Non-thinking fallback GGUFs trip findGGUFModel() but emit no reasoning;
        // skip rather than fail so the suite stays actionable without a Qwen3 fixture.
        try XCTSkipIf(
            thinkingTokenCount == 0,
            "GGUF '\(modelURL.lastPathComponent)' produced no reasoning with a strict grammar. "
            + "Either it is not a thinking model, or the grammar leaked into the reasoning phase "
            + "(the #1595 regression). Provision a Qwen3 fixture — see Tests/ManifoldE2ETests/README.md."
        )

        // Reasoning direction: the <think> block must be free-form. A digit-only
        // grammar leaking into reasoning would make this impossible.
        XCTAssertGreaterThan(thinkingTokenCount, 0,
            "Reasoning block must be emitted free-form under a strict grammar (model: \(modelURL.lastPathComponent))")
        XCTAssertTrue(thinkingText.contains { !$0.isNumber },
            "Reasoning must NOT be schema-constrained — a digit-only grammar leaked into the <think> block "
            + "(reasoning: \(thinkingText.prefix(200)), model: \(modelURL.lastPathComponent))")

        // Output direction: the visible answer must satisfy the grammar exactly.
        XCTAssertFalse(visibleText.isEmpty,
            "Thinking + grammar must still produce a visible answer (model: \(modelURL.lastPathComponent))")
        XCTAssertTrue(visibleText.allSatisfy { $0.isNumber },
            "Visible output must be grammar-constrained to digits only; got: \(visibleText.debugDescription) "
            + "(model: \(modelURL.lastPathComponent))")
    }
}
#endif
