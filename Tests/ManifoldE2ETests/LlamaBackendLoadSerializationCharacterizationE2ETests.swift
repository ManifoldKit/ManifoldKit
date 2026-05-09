#if Llama
import XCTest
@testable import ManifoldBackends
import ManifoldInference
@testable import ManifoldTestSupport

/// Characterization (not specification) tests for `LlamaBackend`'s load-serialization
/// machinery. Pins the current observable behavior of:
///
/// - `loadSerializationLock` (Sources/ManifoldBackends/LlamaBackend.swift:38),
///   which serializes the C-level `llama_model_load_from_file` call so that at
///   most one detached load task is inside the llama.cpp API at a time.
/// - `nextLoadToken` / `activeLoadToken` (Sources/ManifoldBackends/LlamaBackend.swift:76-77),
///   the token pair that lets a later `loadModel` call supersede an earlier
///   in-flight load by incrementing `activeLoadToken`, causing the earlier
///   load's post-commit check (line ~153) to fail and throw `CancellationError()`.
/// - `unloadModel()`'s bump of both tokens (line ~582), which is how overlapping
///   `loadModel` calls end up superseding each other: each new `loadModel` calls
///   `unloadModel()` first, which invalidates any prior in-flight load.
///
/// These tests intentionally make assertions on the **current** types thrown and
/// the **current** observable ordering, not on what the contract "should" be.
/// When issue #407 decomposes this file, these tests should still hold — if they
/// start failing, that IS the regression signal. Investigate before adjusting.
///
/// Hardware & trait gating:
/// - `#if Llama` — only compiled when the Llama trait is enabled.
/// - `XCTSkipUnless(HardwareRequirements.isAppleSilicon)` — Metal + llama.cpp.
/// - `XCTSkipUnless(HardwareRequirements.isPhysicalDevice)` — simulator lacks Metal.
/// - `XCTSkipUnless(HardwareRequirements.findGGUFModel() != nil)` — needs a real
///   GGUF on disk. The serialization lock can only be exercised with a real
///   model load (`MockInferenceBackend` has no `loadSerializationLock`).
///
/// CLAUDE.md constraint: "`LlamaBackend` uses a global `llama_backend_init` —
/// only one instance can exist per process." The ref-counted backend in
/// `retainBackend` / `releaseBackend` makes multiple instances technically safe,
/// but to match the spirit of the constraint and keep tests robust, this file
/// shares a single backend across both tests via a static cache — see
/// `sharedBackend()`.
final class LlamaBackendLoadSerializationCharacterizationE2ETests: XCTestCase {

    // MARK: - Shared Backend

    /// One backend shared across tests in this file. `LlamaBackend.init` does a
    /// ref-counted `llama_backend_init`, so creating a new one per test is
    /// technically legal — but reusing the same instance matches the CLAUDE.md
    /// "one instance per process" guidance and keeps the global state predictable.
    private static let backendBox = BackendBox()

    private final class BackendBox: @unchecked Sendable {
        let lock = NSLock()
        var backend: LlamaBackend?
    }

    private func sharedBackend() -> LlamaBackend {
        Self.backendBox.lock.lock()
        defer { Self.backendBox.lock.unlock() }
        if let existing = Self.backendBox.backend {
            return existing
        }
        let fresh = LlamaBackend()
        Self.backendBox.backend = fresh
        return fresh
    }

    // MARK: - Setup / Teardown

    private var modelURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "LlamaBackend requires Apple Silicon (arm64)")
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice,
                          "LlamaBackend requires Metal (unavailable in simulator)")
        guard let found = HardwareRequirements.findGGUFModel() else {
            throw XCTSkip(
                "No GGUF model found on disk. Place a `.gguf` file in ~/Documents/Models/ to run "
                + "LlamaBackend load-serialization characterization tests."
            )
        }
        modelURL = found
    }

    override func tearDown() async throws {
        // Leave the shared backend unloaded between tests so state doesn't leak.
        // Await the detached cleanup to keep Metal's command-buffer resource sets
        // from lingering (see issue #391 note in `unloadAndWait` doc comment).
        if let backend = Self.backendBox.backend {
            await backend.unloadAndWait()
        }
        try await super.tearDown()
    }

    // MARK: - Test 1: Overlapping `loadModel` calls

    /// Characterizes: when two `loadModel` calls overlap, the second supersedes
    /// the first. The first call's `Task.detached` returns normally (llama.cpp
    /// actually loaded the model), but the commit check at LlamaBackend.swift:153
    /// (`guard activeLoadToken == loadToken`) fails because the second call's
    /// `unloadModel()` bumped `nextLoadToken` (and therefore `activeLoadToken`).
    /// The first caller sees `CancellationError`. The second caller succeeds and
    /// `isModelLoaded == true` at the end.
    ///
    /// This test may become a "best-effort race" if the first load completes
    /// before the second one even begins — we assert on whichever caller wins
    /// the race, not a fixed mapping of "first throws, second succeeds". What
    /// matters is the invariant: at most one caller commits, and the loser sees
    /// `CancellationError` (not a crash, not a silent no-op).
    func test_overlappingLoadModel_secondSupersedes_firstReceivesCancellationError() async throws {
        let backend = sharedBackend()
        // Ensure clean baseline — any prior test could have left state set.
        await backend.unloadAndWait()

        let url = modelURL!
        let plan = ModelLoadPlan.testStub(effectiveContextSize: 512)

        // Fire both loads concurrently via a task group. A group gets the
        // isolation right (each child inherits detached isolation from the
        // group itself) and avoids the region-checker corner case that trips
        // up `async let` / bare `Task` with a captured `@unchecked Sendable`
        // class instance.
        let results: [Result<Void, Error>] = await withTaskGroup(
            of: Result<Void, Error>.self,
            returning: [Result<Void, Error>].self
        ) { group in
            group.addTask { await Self.attemptLoad(backend: backend, url: url, plan: plan) }
            group.addTask { await Self.attemptLoad(backend: backend, url: url, plan: plan) }
            var collected: [Result<Void, Error>] = []
            for await result in group { collected.append(result) }
            return collected
        }
        XCTAssertEqual(results.count, 2, "Both concurrent load attempts must complete")
        let first = results[0]
        let second = results[1]

        // Characterize: exactly one succeeds, the other throws. The serialization
        // lock serializes the C calls; the token machinery picks a winner.
        let successes = [first, second].filter { if case .success = $0 { return true } else { return false } }
        let failures = [first, second].filter { if case .failure = $0 { return true } else { return false } }

        XCTAssertEqual(successes.count, 1,
                       "Exactly one overlapping loadModel must commit; got \(successes.count) successes")
        XCTAssertEqual(failures.count, 1,
                       "The superseded loadModel must fail; got \(failures.count) failures")

        // The loser's error is currently `CancellationError` — the exact type
        // thrown at LlamaBackend.swift:168. If #407's decomposition changes this
        // to a different "cancellation-shaped" error, update this assertion
        // deliberately after confirming the new type is still an expected error
        // (not, e.g., `InferenceError.modelLoadFailed`, which would indicate a
        // genuine load failure rather than supersession).
        guard let firstFailure = failures.first,
              case let .failure(error) = firstFailure else {
            // If the above assertions already reported 0 failures, we've
            // already failed meaningfully; skip the error-type assertion to
            // avoid a crashy unwrap.
            return
        }
        XCTAssertTrue(error is CancellationError,
                      "Superseded loadModel must throw CancellationError (currently thrown at "
                      + "LlamaBackend.swift:168 when activeLoadToken != loadToken); "
                      + "got \(type(of: error)): \(error)")

        // Winner's side-effect is observable: the backend ends up loaded.
        XCTAssertTrue(backend.isModelLoaded,
                      "After overlap settles, the winning load must leave the backend in the "
                      + "loaded state (activeLoadToken reflected the winner)")
    }

    // MARK: - Test 2: `loadModel` while `generate` is mid-stream

    /// Characterizes: calling `loadModel` while a `generate` stream is still
    /// producing tokens must (a) not crash, (b) terminate the in-flight
    /// generation cleanly (no `InferenceError.inferenceFailure` teardown race),
    /// and (c) leave the backend loaded for subsequent use.
    ///
    /// The serialization mechanism here is not `loadSerializationLock` directly
    /// (that only guards the C load call); it is the combination of
    /// `unloadModel()` cancelling the generation task and `waitForPendingCleanup`
    /// awaiting the detached cleanup before the new load enters `serializedModelLoad`.
    /// This test pins that observable outcome.
    func test_loadModelDuringActiveGenerate_generationTerminatesCleanly_noCrash() async throws {
        let backend = sharedBackend()
        await backend.unloadAndWait()

        let url = modelURL!
        let plan = ModelLoadPlan.testStub(effectiveContextSize: 512)

        try await backend.loadModel(from: url, plan: plan)
        XCTAssertTrue(backend.isModelLoaded, "Preconditions: first load must succeed")

        // Start a long-ish generation. The stream is an AsyncThrowingStream of
        // GenerationEvent; we consume in a child task so this one can kick off
        // the overlapping loadModel after a few tokens.
        // Match the prompt/config that `test_stopGeneration_thenGenerate_succeeds_regression390`
        // uses — proven to produce tokens on every GGUF in the fixture directory.
        let config = GenerationConfig(temperature: 0.3, maxOutputTokens: 128)
        let stream = try backend.generate(
            prompt: "Reply with a long story about a cat.",
            systemPrompt: nil,
            config: config
        )

        // Consume the stream on a background Task; record each event type so we
        // can assert ordering after. Using a Swift `actor` keeps reads race-free
        // without Combine/@Published.
        actor StreamRecorder {
            var tokenCount = 0
            var sawFirstToken = false
            var finalError: Error?
            var didFinish = false

            func recordToken() {
                tokenCount += 1
                sawFirstToken = true
            }
            func recordFinish(error: Error?) {
                finalError = error
                didFinish = true
            }
            func snapshot() -> (tokenCount: Int, sawFirstToken: Bool, finalError: Error?, didFinish: Bool) {
                (tokenCount, sawFirstToken, finalError, didFinish)
            }
        }

        let recorder = StreamRecorder()

        let consumer = Task {
            do {
                for try await event in stream.events {
                    switch event {
                    case .token, .thinkingToken:
                        // Reasoning GGUFs route early output through `.thinkingToken`
                        // when the driver's non-ChatML sniff detects `<think>`;
                        // either event counts as decode-loop-is-live.
                        await recorder.recordToken()
                    default:
                        break
                    }
                }
                await recorder.recordFinish(error: nil)
            } catch {
                await recorder.recordFinish(error: error)
            }
        }

        // Wait (bounded) for the first token to confirm generation is actually
        // live before we issue the overlapping loadModel. Polling a short
        // deadline is standard in this codebase (see LlamaBackendTests line
        // 264-267) and avoids a fixed sleep. 30s is generous enough to absorb
        // slow first-token latency on a warm-but-busy laptop; the load itself
        // is ~100ms so a slow first token here is the dominant factor.
        let firstTokenDeadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < firstTokenDeadline {
            let snap = await recorder.snapshot()
            if snap.sawFirstToken || snap.didFinish { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let preLoadSnap = await recorder.snapshot()
        if preLoadSnap.didFinish && !preLoadSnap.sawFirstToken {
            // Generation finished before any token arrived — treat as an
            // environment/backend issue rather than a test failure. The
            // characterization can only be exercised if generation is live.
            throw XCTSkip(
                "Generation finished before emitting any token (finalError: "
                + "\(String(describing: preLoadSnap.finalError))); cannot characterize "
                + "load-during-generate without a live stream."
            )
        }
        XCTAssertTrue(preLoadSnap.sawFirstToken,
                      "Test precondition: at least one token must arrive within 30s before issuing "
                      + "overlapping loadModel (got \(preLoadSnap.tokenCount) tokens, "
                      + "finalError: \(String(describing: preLoadSnap.finalError)))")

        // Issue the overlapping loadModel. This call triggers unloadModel()
        // internally (LlamaBackend.swift:131), which cancels the generation task
        // and schedules cleanup; then waitForPendingCleanup() drains it before
        // the new C-level load begins.
        try await backend.loadModel(from: url, plan: plan)

        // Drain the stream consumer to completion. Characterization: it must
        // finish — either with no error (clean `continuation.finish()` after
        // cancellation check at line 494) or with `CancellationError` from the
        // cancelled Task. It must NOT hang and must NOT throw anything shaped
        // like `InferenceError.inferenceFailure("Decode failed during generation")`
        // (which would mean the backend freed pointers out from under an active
        // decode — the exact bug the stateLock ordering is designed to prevent).
        await consumer.value
        let finalSnap = await recorder.snapshot()

        XCTAssertTrue(finalSnap.didFinish, "Stream consumer must finish (no hang)")

        if let error = finalSnap.finalError {
            // Only cancellation-shaped errors are acceptable here. `InferenceError`
            // with a failure phase would indicate the backend raced and tore down
            // pointers while decode was mid-flight.
            let isInferenceFailure: Bool = {
                if case .inferenceFailure = (error as? InferenceError) { return true }
                return false
            }()
            XCTAssertFalse(
                isInferenceFailure,
                "Generation must not fail with `InferenceError.inferenceFailure` when superseded by "
                + "loadModel — that would indicate a teardown race (got: \(error))"
            )
        }

        // Backend ends up in the loaded state from the second (winning) load.
        XCTAssertTrue(backend.isModelLoaded,
                      "Overlapping loadModel must leave the backend in the loaded state "
                      + "after clean generation teardown")
        XCTAssertFalse(backend.isGenerating,
                       "No generation should be in flight after the new load committed")
    }

    // MARK: - Helpers

    /// Wraps `backend.loadModel` in a `Result` so concurrent callers can inspect
    /// both outcomes. Static so the concurrent Tasks above don't capture `self`.
    private static func attemptLoad(
        backend: LlamaBackend,
        url: URL,
        plan: ModelLoadPlan
    ) async -> Result<Void, Error> {
        do {
            try await backend.loadModel(from: url, plan: plan)
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
#endif
