#if Llama
import XCTest
import BaseChatRuntime
import BaseChatPersistenceSwiftData
@testable import BaseChatInference
import BaseChatTestSupport
@testable import BaseChatBackends

/// Tests for LlamaBackend state, capabilities, and error handling.
///
/// These tests exercise everything that does not require a real GGUF model file:
/// init state, capabilities, error paths, lifecycle transitions, and stop/unload.
///
/// All tests require Apple Silicon (llama_backend_init uses Metal).
final class LlamaBackendTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice, "LlamaBackend requires Metal (unavailable in simulator)")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "LlamaBackend requires Apple Silicon")
    }

    // MARK: - Init & State

    func test_init_defaultState() {
        let backend = LlamaBackend()
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    // MARK: - Load Options Plumbing

    func test_loadOptions_defaultUsesBackendTunedDefaults() {
        let backend = LlamaBackend()
        let opts = backend.loadOptionsForTesting
        XCTAssertEqual(opts.kvCacheQuantization, .q8)
        XCTAssertEqual(opts.flashAttention, BackendLoadOptions.platformDefaultFlashAttention)
        XCTAssertNil(opts.prefillBatchSize)
    }

    func test_setLoadOptions_persistsForNextLoad() {
        let backend = LlamaBackend()
        backend.setLoadOptions(BackendLoadOptions(
            kvCacheQuantization: .q8,
            flashAttention: true,
            prefillBatchSize: 1024
        ))
        let opts = backend.loadOptionsForTesting
        XCTAssertEqual(opts.kvCacheQuantization, .q8)
        XCTAssertTrue(opts.flashAttention)
        XCTAssertEqual(opts.prefillBatchSize, 1024)
    }

    func test_setLoadOptions_overridesPreviousValue() {
        let backend = LlamaBackend()
        backend.setLoadOptions(BackendLoadOptions(kvCacheQuantization: .q4))
        backend.setLoadOptions(BackendLoadOptions(kvCacheQuantization: .q8))
        XCTAssertEqual(backend.loadOptionsForTesting.kvCacheQuantization, .q8)
    }

    // MARK: - Capabilities

    func test_capabilities_supportsAllSamplingParameters() {
        let backend = LlamaBackend()
        let caps = backend.capabilities
        XCTAssertTrue(caps.supportedParameters.contains(.temperature))
        XCTAssertTrue(caps.supportedParameters.contains(.topP))
        XCTAssertTrue(caps.supportedParameters.contains(.topK))
        XCTAssertTrue(caps.supportedParameters.contains(.repeatPenalty))
        XCTAssertTrue(caps.supportedParameters.contains(.minP))
        XCTAssertTrue(caps.supportedParameters.contains(.repetitionPenalty))
        XCTAssertTrue(caps.supportedParameters.contains(.presencePenalty))
        XCTAssertTrue(caps.supportedParameters.contains(.frequencyPenalty))
        XCTAssertTrue(caps.supportedParameters.contains(.llamaDRY))
        XCTAssertTrue(caps.supportedParameters.contains(.llamaXTC))
        XCTAssertTrue(caps.supportedParameters.contains(.llamaMirostatV2))
    }

    func test_capabilities_requiresPromptTemplate() {
        let backend = LlamaBackend()
        XCTAssertTrue(backend.capabilities.requiresPromptTemplate,
                      "GGUF models need external prompt formatting")
    }

    func test_capabilities_supportsSystemPrompt() {
        let backend = LlamaBackend()
        XCTAssertTrue(backend.capabilities.supportsSystemPrompt)
    }

    func test_capabilities_contextSize() {
        let backend = LlamaBackend()
        XCTAssertEqual(backend.capabilities.maxContextTokens, 4096)
    }

    // MARK: - Model Loading Errors

    func test_loadModel_invalidPath_throws() async {
        let backend = LlamaBackend()
        let fakeURL = URL(fileURLWithPath: "/nonexistent/model.gguf")

        do {
            try await backend.loadModel(from: fakeURL, plan: .testStub(effectiveContextSize: 2048))
            XCTFail("Should throw when model file doesn't exist")
        } catch let error as InferenceError {
            if case .modelLoadFailed = error {
                // Expected
            } else {
                XCTFail("Expected modelLoadFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        XCTAssertFalse(backend.isModelLoaded)
    }

    func test_loadModel_emptyFile_throws() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fakeGGUF = tempDir.appendingPathComponent("fake.gguf")
        try Data().write(to: fakeGGUF)

        do {
            try await backend(fakeGGUF)
            XCTFail("Should throw for invalid GGUF file")
        } catch let error as InferenceError {
            if case .modelLoadFailed = error {
                // Expected — empty file is not a valid GGUF
            } else {
                XCTFail("Expected modelLoadFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    private func backend(_ url: URL) async throws {
        let b = LlamaBackend()
        try await b.loadModel(from: url, plan: .testStub(effectiveContextSize: 2048))
    }

    // MARK: - Generate Without Model

    func test_generate_withoutLoading_throws() {
        let backend = LlamaBackend()
        XCTAssertThrowsError(
            try backend.generate(prompt: "hello", systemPrompt: nil, config: GenerationConfig())
        ) { error in
            guard let inferenceError = error as? InferenceError else {
                XCTFail("Expected InferenceError, got \(error)")
                return
            }
            if case .inferenceFailure = inferenceError {
                // Expected
            } else {
                XCTFail("Expected inferenceFailure, got \(inferenceError)")
            }
        }
    }

    // MARK: - Unload

    func test_unloadModel_doesNotBlockCallerThread() {
        // unloadModel() must return quickly — it must not spin on the calling
        // thread waiting for isGenerating, as InferenceService is @MainActor.
        let backend = LlamaBackend()
        let start = Date()
        backend.unloadModel()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.1,
                          "unloadModel() must return in < 100 ms (got \(elapsed * 1000)ms); "
                        + "spinning on the calling thread would freeze the UI")
    }

    // Note: context-clamp logic and KV bytes-per-token computation moved from
    // LlamaBackend into `ModelLoadPlan` / `GGUFKVCacheEstimator` in Stage 3 of
    // the load-path refactor. The tests that previously exercised
    // `computeRamSafeCap` / `computeKVBytesPerToken` here were superseded by
    // `ModelLoadPlanTests` and `ModelLoadPlanParityTests` in
    // `BaseChatInferenceTests`. The retry-on-nil halving loop was deleted
    // outright — the plan is authoritative, so there is no fallback to test.

    func test_unloadModel_fromCleanState_isNoOp() {
        let backend = LlamaBackend()
        // Should not crash when nothing is loaded
        backend.unloadModel()
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    func test_unloadModel_afterFailedLoad_clearsState() async {
        let backend = LlamaBackend()
        let fakeURL = URL(fileURLWithPath: "/nonexistent/model.gguf")

        try? await backend.loadModel(from: fakeURL, plan: .testStub(effectiveContextSize: 2048))
        backend.unloadModel()

        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    func test_unloadAndWait_onCleanBackend_returnsQuickly() async {
        // With nothing loaded, unloadAndWait() must still return without hanging
        // because the cleanup task is never scheduled.
        let backend = LlamaBackend()
        let start = Date()
        await backend.unloadAndWait()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0,
                          "unloadAndWait() on a clean backend must return promptly (got \(elapsed * 1000)ms)")
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    func test_unloadAndWait_isIdempotent() async {
        // Back-to-back calls must not crash and must leave the backend unloaded.
        let backend = LlamaBackend()
        await backend.unloadAndWait()
        await backend.unloadAndWait()
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    func test_unloadAndWait_afterFailedLoad_clearsState() async {
        // unloadAndWait() must clear state identically to unloadModel(), and must
        // also drain any pending cleanup task before returning. Sabotaging the
        // implementation to skip the unloadModel() call would leave isModelLoaded
        // or isGenerating in a stale state if the failed load had set them.
        let backend = LlamaBackend()
        let fakeURL = URL(fileURLWithPath: "/nonexistent/model.gguf")

        try? await backend.loadModel(from: fakeURL, plan: .testStub(effectiveContextSize: 2048))
        await backend.unloadAndWait()

        XCTAssertFalse(backend.isModelLoaded,
                       "isModelLoaded must be false after unloadAndWait()")
        XCTAssertFalse(backend.isGenerating,
                       "isGenerating must be false after unloadAndWait()")
    }

    // MARK: - Stop Generation

    func test_stopGeneration_whenNotGenerating_isNoOp() {
        let backend = LlamaBackend()
        // Should not crash
        backend.stopGeneration()
        XCTAssertFalse(backend.isGenerating)
    }

    // MARK: - Regression: stopGeneration() thread-safety (issue #418)

    /// Regression test for #418: `stopGeneration()` was called from the main actor
    /// while the decode loop read the `cancelled` flag from a detached task. A plain
    /// `Bool` with no synchronisation was a data race under TSan.
    ///
    /// This test does NOT require a GGUF model — it calls `stopGeneration()` on an
    /// unloaded `LlamaBackend` (which is a no-op) from a concurrent task while the
    /// decode loop would have been running if a model were present. The purpose is to
    /// confirm that concurrent atomic access to the `cancelled` flag doesn't crash or
    /// produce a TSan violation.
    ///
    /// For the concurrent-generation/stop interaction against real llama.cpp C state,
    /// see `test_stopGeneration_thenGenerate_succeeds_regression390` which requires a
    /// real GGUF model on disk.
    func test_stopGeneration_concurrentCallsFromMultipleTasks_isRaceFree() async {
        let backend = LlamaBackend()

        // Fire 50 concurrent tasks that each call stopGeneration(). The flag is
        // Atomic<Bool>, so no two stores race — TSan must see zero violations.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    backend.stopGeneration()
                }
            }
        }

        // Backend was never loaded, so isGenerating must remain false throughout.
        XCTAssertFalse(backend.isGenerating,
                       "Concurrent stopGeneration() calls must not corrupt isGenerating state")
    }

    // MARK: - Regression: Stop Then Regenerate (issue #390)

    /// Regression test for #390: calling `stopGeneration()` used to leave
    /// the KV cache populated with the prior run's tokens, so the next
    /// `generate()` failed with `InferenceError.inferenceFailure("Failed to decode prompt")`.
    ///
    /// The fix clears the KV cache at the start of `generate()` rather than
    /// conditionally at the end. This test requires a real GGUF model on
    /// disk because the bug is in llama.cpp's decode path — it cannot be
    /// reproduced with a mock.
    func test_stopGeneration_thenGenerate_succeeds_regression390() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip(
                "No GGUF model found on disk. Place a `.gguf` file in ~/Documents/Models/ to run this regression test."
            )
        }

        // Paranoia for cross-test state leaks: when run after
        // `test_fixture_stopGeneration_midDecode_*_regression522` (the immediate
        // alphabetical predecessor that also performs a stop+drain on the same
        // GGUF), the backend can intermittently produce zero tokens on its
        // first generation despite being a fresh instance. The most likely
        // cause is residual llama.cpp / Metal pipeline state from the prior
        // test that is freed off-thread by the detached cleanup task in
        // `unloadAndWait()` and occasionally hasn't fully settled before this
        // test's first decode runs. The regression *under test* here is the
        // KV-cache clear at the start of the SECOND `generate()` (line 314+),
        // not the precondition that the first run produced tokens — so when
        // the precondition fails (line ~295), discard the backend and retry
        // once on a fresh instance. Any failure on the second attempt is real
        // and surfaces as a hard XCTFail. The retry intentionally does NOT
        // weaken the second-generation assertion at line ~330.
        var attempt = 0
        var lastFailure: String?
        let maxAttempts = 2
        while attempt < maxAttempts {
            attempt += 1
            let backend = LlamaBackend()
            // unloadAndWait() before load flushes any pending detached cleanup
            // task left over from a prior test — defensive no-op on a fresh
            // backend, but harmless and gives the upstream cleanup chain one
            // more chance to drain before we touch llama.cpp.
            await backend.unloadAndWait()

            try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))
            XCTAssertTrue(backend.isModelLoaded)

            // First generation — kick it off, then stop it mid-stream.
            let config = GenerationConfig(temperature: 0.3, maxOutputTokens: 128)
            let stream1 = try backend.generate(
                prompt: "Reply with a long story about a cat.",
                systemPrompt: nil,
                config: config
            )

            // Consume a few tokens to ensure generation has actually started
            // (and the KV cache has been populated) before we stop.
            // Accept either `.token` or `.thinkingToken` — a reasoning GGUF on
            // the Llama3 template emits `<think>…</think>` content first which
            // the driver's sniff mode routes to `.thinkingToken`. Either proves
            // decode reached the loop.
            var tokenCount = 0
            for try await event in stream1.events {
                switch event {
                case .token, .thinkingToken:
                    tokenCount += 1
                    if tokenCount >= 3 { break }
                default:
                    break
                }
                if tokenCount >= 3 { break }
            }

            if tokenCount == 0 {
                // Precondition failed — drain stream1, fully tear down, and
                // retry on a fresh backend. Drain ensures the generation task
                // exits before unloadAndWait() awaits its cleanup chain.
                for try await _ in stream1.events { }
                await backend.unloadAndWait()
                lastFailure = "Attempt \(attempt) produced 0 tokens before stop"
                continue
            }

            // Precondition met — run the actual regression assertion.
            try await runRegression390Body(backend: backend, stream1: stream1)
            return
        }
        XCTFail("All \(maxAttempts) attempts failed precondition: \(lastFailure ?? "unknown")")
    }

    /// Continuation of `test_stopGeneration_thenGenerate_succeeds_regression390`
    /// once the first generation has demonstrably produced ≥1 token. The body
    /// is split out so the precondition retry can construct a fresh backend
    /// without duplicating the assertion logic.
    private func runRegression390Body(
        backend: LlamaBackend,
        stream1: GenerationStream
    ) async throws {
        defer { backend.unloadModel() }

        backend.stopGeneration()

        // Drain the stream so isGenerating flips back to false.
        for try await _ in stream1.events { }

        // The backend flips `isGenerating` to false inside the task's `defer`
        // block, which may run a tick after the stream finishes. Poll until
        // a deadline so slower hardware or larger GGUFs don't flake.
        let waitDeadline = ContinuousClock.now + .seconds(2)
        while backend.isGenerating && ContinuousClock.now < waitDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(backend.isGenerating)

        // Second generation on the same loaded model. Before the fix, this
        // would throw `InferenceError.inferenceFailure("Failed to decode prompt")`
        // because the KV cache still held positions from run 1.
        //
        // Prompt + budget chosen to make spurious 0-token outcomes vanishingly
        // unlikely: a tight 16-token budget combined with a one-line prompt
        // ("Say hello.") plus the driver's random sampler seed
        // (`llama_sampler_init_dist(UInt32.random(...))`, see
        // `LlamaGenerationDriver.run`) lets reasoning GGUFs occasionally sample
        // EOG on iteration 0 — yielding a clean stream with no `.token` events
        // and a false-positive failure for #390. A multi-sentence request with
        // a 96-token budget gives the loop room to emit something even if the
        // first token sampled is EOG-adjacent.
        let stream2 = try backend.generate(
            prompt: "List three colors of the rainbow.",
            systemPrompt: nil,
            config: GenerationConfig(temperature: 0.1, maxOutputTokens: 96)
        )

        var secondRunTokenCount = 0
        for try await event in stream2.events {
            switch event {
            case .token, .thinkingToken:
                secondRunTokenCount += 1
            default:
                break
            }
        }

        XCTAssertGreaterThan(secondRunTokenCount, 0,
                             "Second generation after stopGeneration() must produce tokens — "
                             + "if this fails, the KV cache wasn't cleared between runs (#390)")
    }

    // MARK: - Multiple Init/Deinit Cycles

    func test_multipleInitDeinit_doesNotCrash() {
        for _ in 0..<5 {
            let backend = LlamaBackend()
            backend.unloadModel()
        }
    }

    // MARK: - Plan-Taking loadModel

    /// The plan's `effectiveContextSize` must be honoured verbatim — no clamping,
    /// no RAM-safe cap, no trained-context re-check. Prove it by passing a plan
    /// with a very small context (1 024) and asserting the backend reports it.
    ///
    /// Sabotage check: if `initializeModel` hardcoded `n_ctx = 2048` regardless
    /// of the plan, `backend.capabilities.maxContextTokens` would be 2 048 and
    /// this assertion would fail.
    func test_loadModel_fromPlan_passesEffectiveContextSizeToCContext() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip(
                "No GGUF model found on disk. Place a `.gguf` file in ~/Documents/Models/ to run this test."
            )
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }

        let requested = 1024
        let inputs = ModelLoadPlan.Inputs(
            modelFileSize: 0,
            memoryStrategy: .mappable,
            requestedContextSize: requested,
            trainedContextLength: nil,
            kvBytesPerToken: 0,
            availableMemoryBytes: UInt64.max,
            physicalMemoryBytes: UInt64.max,
            absoluteContextCeiling: 128_000,
            headroomFraction: 0.40
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        XCTAssertEqual(plan.effectiveContextSize, requested,
                       "Plan must pass through the requested context when no ceilings bind")

        try await backend.loadModel(from: modelURL, plan: plan)
        XCTAssertTrue(backend.isModelLoaded)
        XCTAssertEqual(backend.capabilities.maxContextTokens, Int32(requested),
                       "Backend must honour the plan's effectiveContextSize verbatim — "
                       + "a mismatch means the plan was not authoritative")
    }

    /// Regression test for #398/#411: when the plan clamps the context to a
    /// smaller value than requested (the normal memory-gated path), the C API
    /// must allocate the clamped size, not the requested size. This is the
    /// named regression for the ggml_metal_host_malloc crash: before the plan,
    /// the backend would attempt the full requested context and crash.
    ///
    /// The assertion here is indirect — we cannot inspect ggml_metal_host_malloc
    /// error output from a unit test without OSLogStore plumbing — but load
    /// success at a plan-clamped size confirms the new path respects the clamp.
    ///
    /// Sabotage check: if the backend ignored the plan and used `requested`,
    /// the load would attempt a larger allocation than we requested and either
    /// succeed (invalidating the test's premise) or crash (failing the test).
    /// A non-throwing load at the clamped size is what we want to see.
    func test_loadModel_fromPlan_clampRespected_noMetalHostMallocFailure() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip(
                "No GGUF model found on disk. Place a `.gguf` file in ~/Documents/Models/ to run this regression test."
            )
        }

        // Build a plan with a generous request but a tight memory budget so the
        // plan's memoryCeiling clamps `effectiveContextSize` well below the
        // request. The inputs are synthetic — we don't need the real file size
        // because `mappable` strategy uses a fraction.
        let inputs = ModelLoadPlan.Inputs(
            modelFileSize: 1_073_741_824,  // 1 GB, mappable ⇒ 256 MB resident reserve
            memoryStrategy: .mappable,
            requestedContextSize: 65_536,
            trainedContextLength: nil,
            kvBytesPerToken: 131_072,      // ~128 KB/tok (large; forces aggressive clamp)
            availableMemoryBytes: 2_147_483_648,  // 2 GB available
            physicalMemoryBytes: 8_589_934_592,   // 8 GB physical
            absoluteContextCeiling: 128_000,
            headroomFraction: 0.40
        )
        let plan = ModelLoadPlan.compute(inputs: inputs)
        XCTAssertLessThan(plan.effectiveContextSize, inputs.requestedContextSize,
                          "Test setup requires the plan to clamp — inputs must force a memory ceiling")
        XCTAssertNotEqual(plan.verdict, .deny,
                          "Test setup requires a plan that is safe to load (not denied)")

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }

        try await backend.loadModel(from: modelURL, plan: plan)
        XCTAssertTrue(backend.isModelLoaded,
                      "Load at plan-clamped context size must succeed; a failure here would "
                      + "indicate the backend allocated more than the plan authorized")
        XCTAssertEqual(backend.capabilities.maxContextTokens, Int32(plan.effectiveContextSize))
    }

    // MARK: - TokenizerVendor

    func test_tokenizerVendor_conformance_vendorReturnsSelf() {
        let backend = LlamaBackend()
        // tokenizer should be the backend itself (as TokenizerProvider)
        let tokenizer = backend.tokenizer
        // Verify it produces a result — exact value doesn't matter without a loaded vocab
        let count = tokenizer.tokenCount("hello world")
        XCTAssertGreaterThan(count, 0, "tokenCount should always return a positive value")
    }

    func test_tokenCount_withoutLoadedModel_fallsBackToHeuristic() {
        // Without a loaded model, vocab is nil → tokenize() returns [] → heuristic kicks in.
        // "hello world" = 11 chars → max(1, 11/4) = 2
        let backend = LlamaBackend()
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertEqual(backend.tokenCount("hello world"), 2,
                       "Should fall back to char-count heuristic when no model is loaded")
    }

    func test_tokenCount_emptyString_withoutModel_returnsOne() {
        // HeuristicTokenizer floors at 1; LlamaBackend.tokenCount should match.
        let backend = LlamaBackend()
        XCTAssertEqual(backend.tokenCount(""), 1,
                       "Empty string with no model should return heuristic floor of 1")
    }

    func test_tokenCount_longString_withoutModel_scalesWithLength() {
        let backend = LlamaBackend()
        let short = backend.tokenCount("Hi")          // max(1, 2/4) = 1
        let long  = backend.tokenCount(String(repeating: "abcd", count: 100))  // 400/4 = 100
        XCTAssertLessThan(short, long, "Longer text should produce a higher token count")
    }

    // MARK: - countTokens (TokenCountingBackend)

    /// `countTokens` must throw when called before any model is loaded, because
    /// the vocab pointer is nil and there is nothing to tokenize against.
    ///
    /// Sabotage check: if `countTokens` silently fell back to the heuristic
    /// instead of throwing, this test would fail (no error thrown).
    func test_countTokens_withoutModel_throws() {
        let backend = LlamaBackend()
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertThrowsError(try backend.countTokens("hello world")) { error in
            guard case InferenceError.inferenceFailure = error else {
                XCTFail("Expected InferenceError.inferenceFailure, got \(error)")
                return
            }
        }
    }

    /// When a real GGUF model is loaded, `countTokens` must return a positive
    /// and plausible count — not the heuristic fallback and not zero.
    ///
    /// The assertion checks lower bound only; exact token counts are
    /// model-specific and change with vocabulary.
    ///
    /// Sabotage check: if `countTokens` were hardcoded to return 1 for all
    /// input, `XCTAssertGreaterThan(count, 1)` would fail.
    func test_countTokens_withLoadedModel_returnsPlausibleCount() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip(
                "No GGUF model on disk. Place a `.gguf` file in ~/Documents/Models/ to run this test."
            )
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 1024))

        // A multi-word English phrase typically produces several tokens.
        let count = try backend.countTokens("The quick brown fox jumps over the lazy dog.")
        XCTAssertGreaterThan(count, 1,
                             "A non-trivial sentence must produce more than one token")
        // Rough sanity bound: BPE models compress ~4 chars/token on average English.
        // 45-character phrase → at most ~30 tokens even for a small vocab.
        XCTAssertLessThan(count, 30,
                          "Token count seems implausibly large — possible tokenizer bug")
    }

    /// `countTokens` must be consistent: calling it twice on the same string
    /// must return the same value (pure vocabulary lookup, no stochastic state).
    func test_countTokens_idempotent_withLoadedModel() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No GGUF model on disk.")
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 1024))

        let text = "Consistency is key."
        let first = try backend.countTokens(text)
        let second = try backend.countTokens(text)
        XCTAssertEqual(first, second, "countTokens must be deterministic")
    }

    // MARK: - Backend Contract

    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants { LlamaBackend() }
    }

    // MARK: - EOG Token Variants (#519)

    /// Closes #519 — exercises the `llama_vocab_is_eog` termination path of
    /// `LlamaGenerationDriver.run`, which is the only way real models stop mid-stream.
    ///
    /// GGUF tokenizers each carry their own end-of-generation token(s) — `</s>`,
    /// `<|endoftext|>`, `<|eot_id|>`, and Gemma variants with both `<end_of_turn>`
    /// and `<eos>`. Without hitting `vocab_is_eog`, generation only stops when the
    /// `maxOutputTokens` budget is exhausted. This fixture proves the EOG path
    /// terminates the stream cleanly on whatever GGUF happens to be available:
    /// the `maxOutputTokens` budget is set generously (256) while the prompt asks
    /// for a brief reply, so any well-behaved model hits EOG before the budget.
    ///
    /// Per #968: modern instruct models (Qwen3, Llama 3, Gemma) only emit their
    /// EOG token (`<|im_end|>`, `<|eot_id|>`, `<end_of_turn>`) inside a Jinja
    /// chat-templated response. Sending a raw prompt produces open-ended text
    /// that never hits EOG — the model just continues until the budget is
    /// exhausted. `LlamaBackend.capabilities.requiresPromptTemplate` is `true`
    /// for exactly this reason; the test honours that contract by formatting
    /// the prompt with the ChatML template (the most widely supported variant
    /// across Qwen2/Qwen3/Mistral instruct GGUFs). Llama-3 and Gemma GGUFs
    /// understand ChatML well enough to still terminate cleanly because the
    /// `<|im_end|>` token is only consumed as a string terminator — the actual
    /// EOG token emitted by the model is the one its own tokenizer marked as
    /// EOG, regardless of which delimiter format wrapped the prompt.
    ///
    /// Gated on a real GGUF today — per #519, unskipping requires refactoring
    /// `LlamaGenerationDriver` to accept a mockable sampler, which is out of
    /// scope for a fixture PR that is not allowed to modify the driver.
    ///
    /// Sabotage check: delete the `if llama_vocab_is_eog(vocab, token) { break }`
    /// line in `LlamaGenerationDriver.run`. Generation runs until `maxOutputTokens`
    /// instead of terminating on EOG, so `tokenCount == maxOutputTokens` rather
    /// than strictly less. Alternative sabotage (per #968): replace the
    /// chat-templated prompt with the raw "Reply with just the word 'ok'."
    /// string — Qwen3-0.6B-Q4_K_M then exhausts the 256-token budget and the
    /// `tokenCount < maxBudget` assertion fails.
    func test_fixture_eogTokenTerminatesStreamBeforeBudget_regression519() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No GGUF on disk. Place a `.gguf` in ~/Documents/Models/ to run this fixture.")
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        let maxBudget = 256
        let config = GenerationConfig(temperature: 0.1, maxOutputTokens: maxBudget)
        // ChatML-templated prompt (#968). Modern instruct GGUFs only emit their
        // EOG token at the end of a templated assistant turn — the trailing
        // `<|im_start|>assistant\n` cues the model to produce a reply and stop.
        let chatMLPrompt = """
            <|im_start|>user
            Reply with just the word 'ok'.<|im_end|>
            <|im_start|>assistant

            """
        let stream = try backend.generate(
            prompt: chatMLPrompt,
            systemPrompt: nil,
            config: config
        )

        // Accept either `.token` or `.thinkingToken` — the fixture gates on
        // whether EOG terminated the stream, not on which event bucket the
        // content went to. Reasoning GGUFs emit `<think>` content first which
        // the driver's sniff mode routes to `.thinkingToken`.
        var tokenCount = 0
        for try await event in stream.events {
            switch event {
            case .token, .thinkingToken: tokenCount += 1
            default: break
            }
        }

        XCTAssertGreaterThan(tokenCount, 0, "EOG fixture must produce at least one token")
        XCTAssertLessThan(
            tokenCount, maxBudget,
            "Generation must terminate on an EOG token before the \(maxBudget)-token budget — "
            + "if tokenCount == budget, the EOG branch in LlamaGenerationDriver.run never fired"
        )
    }

    // MARK: - n_batch Boundary Cases (#520)

    /// Closes #520 — pins the `n_batch`-sized chunked decode path of
    /// `LlamaGenerationDriver.run` against preflight clamping for oversized prompts.
    ///
    /// The driver chunks prompt decode into `llama_n_batch(context)`-sized pieces;
    /// prompts longer than `contextSize` are pre-empted by `LlamaBackend.generate`'s
    /// `tokens.count + maxOutputTokens <= contextSize` check which throws
    /// `InferenceError.contextExhausted`. Without a fixture, the chunking regression
    /// fixed in PR #409 can reappear silently when the decode loop is touched.
    ///
    /// Fixture strategy: build a plausible-but-oversized prompt by repeating a short
    /// string until the UTF-8 length guarantees the token count will exceed the
    /// clamped 512-token context (4-chars-per-token BPE average × 512 context
    /// = ~2 048 chars minimum; we use 16 000 chars for a comfortable margin).
    /// The exact token count is model-dependent, so we assert throws rather than
    /// reading the decoded count.
    ///
    /// The successful path — prompts short enough to decode in one chunk — is
    /// already covered by `test_stopGeneration_thenGenerate_succeeds_regression390`
    /// (the "Say hello." second-generation leg). Unskipping the exact `n_batch` /
    /// `n_batch + 1` / `contextSize - 1` counts requires a driver-level mock per #520.
    ///
    /// Sabotage check: change the preflight to `tokens.count + maxOutputTokens < 0`
    /// so the guard always passes. The oversized prompt reaches `llama_decode` and
    /// either succeeds (invalidating the fixture) or crashes llama.cpp instead of
    /// throwing the expected `InferenceError.contextExhausted`.
    func test_fixture_nBatchBoundary_oversizedPromptThrowsContextExhausted_scaffold520() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No GGUF on disk. Place a `.gguf` in ~/Documents/Models/ to run this fixture.")
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        // Clamp the context tight so a 16 kB repetition blows past it
        // without requiring a 100 kB fixture string.
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        // 16 000 chars ≈ 4 000 tokens at BPE's ~4 chars/token — an order of
        // magnitude over the clamped 512 context. Safe across tokenizers.
        let oversizedPrompt = String(repeating: "word ", count: 3_200)

        XCTAssertThrowsError(
            try backend.generate(
                prompt: oversizedPrompt,
                systemPrompt: nil,
                config: GenerationConfig(temperature: 0.1, maxOutputTokens: 16)
            )
        ) { error in
            guard let inferenceError = error as? InferenceError else {
                XCTFail("Expected InferenceError, got \(error)")
                return
            }
            if case .contextExhausted = inferenceError {
                // Expected — preflight caught the oversized prompt before
                // `llama_decode` could assert on `n_tokens_all > n_batch`.
            } else {
                XCTFail("Expected contextExhausted, got \(inferenceError)")
            }
        }
    }

    // MARK: - llama_decode Error Paths (#521)

    /// Closes #521 — pins the "generate() called before loadModel succeeded" path
    /// that funnels through the same `InferenceError.inferenceFailure` surface as
    /// `llama_decode` failures inside the driver.
    ///
    /// The issue's ideal fixture — mocking `llama_decode` to return non-zero and
    /// asserting the stream finishes with `.failed("Failed to decode prompt")` /
    /// `.failed("Decode failed during generation")` — requires refactoring
    /// `LlamaGenerationDriver` to inject the C call, which this PR cannot do.
    /// As the smoke-test-level substitute called out in the issue, this pins the
    /// public error contract: callers attempting to generate on a backend whose
    /// load failed (or was never issued) must see `InferenceError.inferenceFailure`,
    /// the same type they would see if `llama_decode` blew up mid-loop.
    ///
    /// Additionally verifies `isGenerating` stays false across the failure — a
    /// mid-loop decode failure goes through the same `defer { isGenerating = false }`,
    /// so the invariant is identical.
    ///
    /// Sabotage check: change the `No model loaded` guard in
    /// `LlamaBackend.generate` to `throw CancellationError()`. The fixture fails
    /// because the error type is no longer `InferenceError.inferenceFailure`.
    func test_fixture_decodeErrorPath_publicErrorContractForGeneratePreconditions_scaffold521() async throws {
        let backend = LlamaBackend()

        // Attempt generation on an unloaded backend. LlamaBackend.generate()
        // throws .inferenceFailure("No model loaded") synchronously — the same
        // error case the driver emits for `llama_decode != 0`.
        XCTAssertThrowsError(
            try backend.generate(
                prompt: "hello",
                systemPrompt: nil,
                config: GenerationConfig(temperature: 0.1, maxOutputTokens: 16)
            )
        ) { error in
            guard let inferenceError = error as? InferenceError else {
                XCTFail("Expected InferenceError, got \(error)")
                return
            }
            if case .inferenceFailure = inferenceError {
                // Expected. Any decode failure path in LlamaGenerationDriver.run
                // surfaces the same case.
            } else {
                XCTFail("Expected inferenceFailure, got \(inferenceError)")
            }
        }

        XCTAssertFalse(backend.isGenerating,
                       "isGenerating must remain false after generate() throws a decode-family failure")
    }

    // MARK: - stopGeneration Mid-Decode (#522)

    /// Closes #522 — stopGeneration() fired during a long prompt decode must flip
    /// `isGenerating` to false within a bounded time, proving the cancellation flag
    /// is observed between chunked `llama_decode` calls.
    ///
    /// `LlamaGenerationDriver.run` checks `isCancelled()` between prompt chunks
    /// AND between generation-loop iterations, not inside a single `llama_decode`
    /// call (that call is synchronous C). A stop fired mid-decode must wait for
    /// the current chunk/iteration to return, but from the caller's perspective
    /// `isGenerating` must fall false promptly after — within a 2-second budget
    /// per the issue's gated-on-real-GGUF fixture shape.
    ///
    /// This fixture specifically targets the case where the stop happens after
    /// generation has started yielding tokens, to guarantee we are cancelling
    /// inside the generation loop (not before decode even begins).
    ///
    /// Sabotage check: remove the `if isCancelled() { break }` check at the top
    /// of the generation loop. The loop runs until `maxOutputTokens` / EOG, and
    /// `isGenerating` stays true for the full generation — this fixture's
    /// 2-second polling window expires and the `XCTAssertFalse` fails.
    ///
    /// For the mockable driver-level variant described in #522 (stop during
    /// chunk N of a prompt-loop split, assert batch is freed and stream finishes
    /// `.done` not `.failed`), a driver refactor is required — deferred until
    /// the `LlamaGenerationDriver` decomposition follow-up lands.
    func test_fixture_stopGeneration_midDecode_isGeneratingFallsFalseWithinBudget_regression522() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No GGUF on disk. Place a `.gguf` in ~/Documents/Models/ to run this fixture.")
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        // Same prompt + temperature as the proven-working
        // `test_stopGeneration_thenGenerate_succeeds_regression390` path —
        // reliably produces multiple tokens before EOG on small instruct
        // models (incl. SmolLM2 / Phi-3 / TinyLlama).
        let config = GenerationConfig(temperature: 0.3, maxOutputTokens: 128)
        let stream = try backend.generate(
            prompt: "Reply with a long story about a cat.",
            systemPrompt: nil,
            config: config
        )

        // Consume a few tokens so generation has demonstrably entered the
        // decode loop — matching the regression390 test's 3-token warm-up.
        // Accept either `.token` or `.thinkingToken`: with the non-ChatML
        // thinking sniffer in place, reasoning models on the Llama3 template
        // emit `.thinkingToken` first while the visible block is still inside
        // a `<think>…</think>` region. Either event type proves the decode
        // loop is running, which is what this fixture gates on.
        var sawToken = false
        var tokenCount = 0
        for try await event in stream.events {
            switch event {
            case .token, .thinkingToken:
                tokenCount += 1
                if tokenCount >= 3 {
                    sawToken = true
                }
            default:
                break
            }
            if sawToken { break }
        }
        XCTAssertTrue(sawToken, "Expected at least three tokens (visible or thinking) before stopping — generation never reached the decode loop")

        // Fire the stop mid-generation. The generation loop's `isCancelled()`
        // check must pick this up and break on the next iteration.
        backend.stopGeneration()

        // Drain the stream so the task's `defer { isGenerating = false }` runs.
        for try await _ in stream.events { }

        // Poll within a 2-second budget (per #522's gated fixture shape).
        let waitDeadline = ContinuousClock.now + .seconds(2)
        while backend.isGenerating && ContinuousClock.now < waitDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(backend.isGenerating,
                       "stopGeneration() mid-decode must cause isGenerating to fall false within 2s — "
                       + "a regression here means the cancel check was moved out of the decode loop")
    }

    // MARK: - maxThinkingTokens == 0 disables thinking entirely (#597)

    /// Closes #597 (Llama half) — exercises the `LlamaGenerationDriver` path that
    /// short-circuits `ThinkingParser` when `config.maxThinkingTokens == 0`.
    ///
    /// With `thinkingMarkers = .qwen3` set on the config *and* `maxThinkingTokens = 0`,
    /// the driver must:
    ///   1. Emit zero `.thinkingToken` events — no reasoning tokens leak into the stream.
    ///   2. Emit zero `.thinkingComplete` events — the parser never opens a thinking block.
    ///   3. Produce visible `.token` events — disabling thinking must not starve output.
    ///
    /// Any `<think>` / `</think>` literal the model emits surfaces as `.token`
    /// text rather than being routed through the parser.
    ///
    /// Hardware-gated (requires Apple Silicon + a real GGUF). When the available
    /// GGUF happens to be a non-reasoning model, the stream produces zero thinking
    /// events trivially — which is still a valid pass: the contract is "no thinking
    /// events AND visible output appears", and both hold. The test remains useful
    /// because it re-asserts on every push that the gating code path still
    /// compiles and the `config.maxThinkingTokens == 0` branch actually routes
    /// content to `.token` rather than `.thinkingToken`.
    ///
    /// Sabotage check: remove `!thinkingDisabled &&` from the `useParser` /
    /// `sniffEnabled` initialisers in `LlamaGenerationDriver`. On a reasoning
    /// GGUF the stream emits `<think>` content as `.thinkingToken`, failing the
    /// zero-count assertion.
    func test_fixture_maxThinkingTokens_zero_disablesThinkingEntirely_regression597() async throws {
        guard let modelURL = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip("No GGUF on disk. Place a `.gguf` in ~/Documents/Models/ to run this fixture.")
        }

        let backend = LlamaBackend()
        addTeardownBlock { await backend.unloadAndWait() }
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))

        // thinkingMarkers = .qwen3 would normally activate the parser.
        // maxThinkingTokens = 0 must override that and keep the parser off.
        var config = GenerationConfig(temperature: 0.1, maxOutputTokens: 64)
        config.thinkingMarkers = .qwen3
        config.maxThinkingTokens = 0

        let stream = try backend.generate(
            prompt: "Reply with just the word 'ok'.",
            systemPrompt: nil,
            config: config
        )

        var thinkingTokenCount = 0
        var thinkingCompleteCount = 0
        var visibleTokenCount = 0
        for try await event in stream.events {
            switch event {
            case .thinkingToken: thinkingTokenCount += 1
            case .thinkingComplete: thinkingCompleteCount += 1
            case .token: visibleTokenCount += 1
            default: break
            }
        }

        XCTAssertEqual(thinkingTokenCount, 0,
            "maxThinkingTokens=0 must suppress every .thinkingToken event (#597) — "
            + "driver must short-circuit ThinkingParser even when thinkingMarkers is set")
        XCTAssertEqual(thinkingCompleteCount, 0,
            "maxThinkingTokens=0 must suppress .thinkingComplete — no thinking phase entered")
        XCTAssertGreaterThan(visibleTokenCount, 0,
            "Visible output must still appear when thinking is disabled — the generation loop "
            + "must not starve .token events")
    }

    // MARK: - HeuristicTokenizer Parity

    /// On a `LlamaBackend` with no model loaded the `tokenCount(_:)` fallback
    /// must route through the shared `HeuristicTokenizer.tokenCount(_:)` so
    /// the `chars / 4` heuristic stays in one place across
    /// `BaseChatInference` and `BaseChatBackends`.
    ///
    /// Sabotage: change `HeuristicTokenizer.tokenCount` to `text.count / 8`
    /// — this test fails (and the shared `HeuristicTokenizerTests` in
    /// `BaseChatInferenceSwiftTestingTests` also fail).
    func test_tokenCount_noVocab_matchesHeuristicTokenizer() {
        let backend = LlamaBackend()
        XCTAssertFalse(backend.isModelLoaded)

        let short = "hi"
        let long = String(repeating: "the quick brown fox ", count: 32) // ~640 chars

        XCTAssertEqual(backend.tokenCount(short), HeuristicTokenizer.tokenCount(short),
                       "short-string fallback must match shared heuristic")
        XCTAssertEqual(backend.tokenCount(long), HeuristicTokenizer.tokenCount(long),
                       "long-string fallback must match shared heuristic")
    }

    // MARK: - Multimodal Projector (supportsVision)

    func test_capabilities_supportsVision_withoutMmproj_isFalse() {
        let backend = LlamaBackend()
        XCTAssertFalse(backend.capabilities.supportsVision,
                       "supportsVision must be false when no mmproj URL has been set")
    }

    func test_capabilities_supportsVision_afterSetMmprojURL_isTrue() {
        let backend = LlamaBackend()
        let fakeMMProj = URL(fileURLWithPath: "/nonexistent/mmproj-model.gguf")
        backend.setMmprojURL(fakeMMProj)
        XCTAssertTrue(backend.capabilities.supportsVision,
                      "supportsVision must be true once a mmproj URL is staged")
    }

    func test_capabilities_supportsVision_afterClearingMmprojURL_isFalse() {
        let backend = LlamaBackend()
        backend.setMmprojURL(URL(fileURLWithPath: "/nonexistent/mmproj-model.gguf"))
        backend.setMmprojURL(nil)
        XCTAssertFalse(backend.capabilities.supportsVision,
                       "supportsVision must revert to false after setMmprojURL(nil)")
    }

    func test_capabilities_supportsVision_afterUnload_isFalse() {
        let backend = LlamaBackend()
        backend.setMmprojURL(URL(fileURLWithPath: "/nonexistent/mmproj-model.gguf"))
        backend.unloadModel()
        XCTAssertFalse(backend.capabilities.supportsVision,
                       "unloadModel() must clear the mmproj URL so supportsVision returns false")
    }

    func test_generate_withImageParts_throwsInferenceFailure() {
        let backend = LlamaBackend()
        backend.setMmprojURL(URL(fileURLWithPath: "/nonexistent/mmproj-model.gguf"))

        let imageData = Data([0xFF, 0xD8, 0xFF]) // JPEG magic bytes
        let history: [StructuredMessage] = [
            StructuredMessage(role: "user", parts: [
                .text("Describe this image:"),
                .image(data: imageData, mimeType: "image/jpeg")
            ])
        ]
        backend.setStructuredHistory(history)

        // The image guard runs before the model-loaded guard so a caller hits
        // the actionable xcframework-limitation message even when no model is
        // loaded. Asserting on the message text proves we hit the image guard
        // and not the generic "No model loaded" path.
        XCTAssertThrowsError(
            try backend.generate(prompt: "Describe this image:", systemPrompt: nil, config: GenerationConfig())
        ) { error in
            guard let inferenceError = error as? InferenceError,
                  case let .inferenceFailure(message) = inferenceError else {
                XCTFail("Expected InferenceError.inferenceFailure, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("multimodal image inference is not yet available"),
                          "expected image-guard message, got: \(message)")
            XCTAssertTrue(message.contains("clip.h"),
                          "error message must reference the missing headers so a developer knows the fix")
        }
    }
}
#endif
