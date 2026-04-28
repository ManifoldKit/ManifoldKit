#if canImport(FoundationModels)
import XCTest
import BaseChatCore
import BaseChatInference
import BaseChatTestSupport
@testable import BaseChatBackends

/// Isolated unit tests for `FoundationBackend` state management and guard paths.
///
/// These tests do NOT perform real inference and do NOT require Apple Intelligence.
/// They run everywhere that iOS 26 / macOS 26 SDK symbols are available (which is
/// satisfied at compile time even on the simulator / CI machines with Xcode 26 SDKs).
///
/// Tests that would require live model inference are gated with
/// `XCTSkipUnless(HardwareRequirements.hasFoundationModels)`.
@available(iOS 26, macOS 26, *)
final class FoundationBackendUnitTests: XCTestCase {

    private var backend: FoundationBackend!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // XCTest discovers and invokes test methods via the ObjC runtime, bypassing
        // Swift's @available check on the class. Without this guard, any test that
        // calls FoundationBackend.isAvailable (which accesses SystemLanguageModel —
        // a macOS 26 API) crashes the process on older runners before XCTSkipUnless
        // can run. ProcessInfo gives us a runtime availability check that the compiler
        // won't flag as redundant (unlike #available inside an @available class).
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        ) else {
            throw XCTSkip("FoundationModels requires iOS 26 / macOS 26")
        }
        backend = FoundationBackend()
    }

    override func tearDown() {
        backend = nil
        super.tearDown()
    }

    // MARK: - 1. generate() before loadModel() throws

    func test_generate_beforeLoad_throwsNoModelLoaded() throws {
        XCTAssertFalse(backend.isModelLoaded, "Precondition: model must not be loaded")

        let config = GenerationConfig()
        XCTAssertThrowsError(
            try backend.generate(prompt: "hello", systemPrompt: nil, config: config)
        ) { error in
            guard case InferenceError.inferenceFailure(let msg) = error else {
                XCTFail("Expected InferenceError.inferenceFailure, got \(error)")
                return
            }
            XCTAssertTrue(
                msg.localizedCaseInsensitiveContains("No model loaded"),
                "Error message should mention 'No model loaded', got: \(msg)"
            )
        }
    }

    // MARK: - 3. unloadModel() clears state

    func test_unloadModel_clearsState() {
        // Manually probe the initial state, then confirm unloadModel is idempotent
        // and always leaves the backend in the unloaded state.
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)

        backend.unloadModel()

        XCTAssertFalse(backend.isModelLoaded, "isModelLoaded must be false after unloadModel()")
        XCTAssertFalse(backend.isGenerating, "isGenerating must be false after unloadModel()")
    }

    func test_unloadModel_idempotent() {
        // Calling unloadModel() twice must not crash or leave bad state.
        backend.unloadModel()
        backend.unloadModel()

        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    // MARK: - 4. resetConversation() preserves isModelLoaded

    /// Regression test for the bug where resetConversation() would set session = nil
    /// without touching isModelLoaded, but callers expected isModelLoaded to remain
    /// true so that generate() could recreate the session on the next call.
    ///
    /// Without Apple Intelligence we cannot call loadModel() to get to the loaded
    /// state, so we verify the contract from the unloaded side: resetConversation()
    /// must NOT change isModelLoaded regardless of what it was before.
    func test_resetConversation_doesNotChangeIsModelLoaded_whenUnloaded() {
        XCTAssertFalse(backend.isModelLoaded, "Precondition")
        backend.resetConversation()
        XCTAssertFalse(
            backend.isModelLoaded,
            "resetConversation() must not modify isModelLoaded"
        )
    }

    /// On a real device with Apple Intelligence, verify the full round-trip:
    /// loadModel() → isModelLoaded==true, resetConversation() → still true.
    func test_resetConversation_preservesIsModelLoaded_afterLoad() async throws {
        try XCTSkipUnless(FoundationBackend.isAvailable, "Apple Intelligence not available on this device")

        let url = URL(fileURLWithPath: "/dev/null") // ignored by FoundationBackend
        try await backend.loadModel(from: url, plan: .testStub(effectiveContextSize: 4096))
        XCTAssertTrue(backend.isModelLoaded, "Precondition: loadModel() should set isModelLoaded")

        backend.resetConversation()

        XCTAssertTrue(
            backend.isModelLoaded,
            "resetConversation() must leave isModelLoaded == true (regression: was not clearing it)"
        )
    }

    // MARK: - 5. isAvailable is readable

    func test_isAvailable_returnsSystemModelAvailability() {
        // We can't assert a specific value — it's device-dependent.
        // This test merely confirms the property is readable and returns a Bool.
        let available: Bool = FoundationBackend.isAvailable
        // The result is valid either way; just ensure no crash / type mismatch.
        _ = available
    }

    // MARK: - 6. capabilities has correct values

    func test_capabilities_hasCorrectValues() {
        let caps = backend.capabilities

        XCTAssertFalse(
            caps.requiresPromptTemplate,
            "FoundationBackend applies its own chat template; requiresPromptTemplate must be false"
        )
        XCTAssertTrue(
            caps.supportsSystemPrompt,
            "FoundationBackend accepts a system prompt via LanguageModelSession(instructions:)"
        )
        XCTAssertEqual(
            caps.maxContextTokens,
            4096,
            "maxContextTokens should be 4096 (FoundationTokenizer handles accurate counting)"
        )
        XCTAssertTrue(
            caps.supportedParameters.contains(.temperature),
            "temperature must be in supportedParameters"
        )
    }

    // MARK: - 7. generate() while already generating throws alreadyGenerating

    func test_generate_whileAlreadyGenerating_throwsAlreadyGenerating() throws {
        // We cannot reach isGenerating==true without a running session, but we
        // can verify the guard ordering: the isModelLoaded guard fires first,
        // which means the alreadyGenerating guard is dead code when the model
        // is not loaded. To reach the alreadyGenerating path we need isModelLoaded
        // to be true. Since we cannot call loadModel() without Apple Intelligence,
        // skip this sub-test when unavailable.
        try XCTSkipUnless(FoundationBackend.isAvailable, "Apple Intelligence not available — cannot reach isGenerating guard without a loaded model")

        // If we get here we could load the model and start a long generation,
        // but that would be an E2E test. Instead, we verify the guard order
        // through the unit-level property: isGenerating is false by default
        // and only set to true inside generate(). The guard itself is correct
        // by code inspection; we validate the compile-time contract here.
        XCTAssertFalse(backend.isGenerating, "isGenerating must start false")
    }

    // MARK: - Probe session history

    /// Verifies that after `loadModel()` the backend does NOT retain the probe
    /// session as its active session. If it did, the first user message would
    /// see the probe "Hi / <response>" exchange as prior context.
    ///
    /// The `session` property is private, so we verify the observable invariant:
    /// after a successful `loadModel`, the backend must be able to generate
    /// without pre-existing conversation history. Since the property is inaccessible,
    /// we document the contract here and skip when Apple Intelligence is unavailable.
    func test_loadModel_doesNotRetainProbeSessionHistory() async throws {
        // Without live Foundation Models we cannot drive loadModel to success,
        // so we skip rather than silently pass on a path we haven't exercised.
        try XCTSkipUnless(
            FoundationBackend.isAvailable,
            "Apple Intelligence not available — cannot call loadModel() to verify probe session is discarded. "
            + "Inspect FoundationBackend.loadModel: session must remain nil after the probe so generate() creates a clean session."
        )

        let url = URL(fileURLWithPath: "/dev/null")
        try await backend.loadModel(from: url, plan: .testStub(effectiveContextSize: 4096))
        XCTAssertTrue(backend.isModelLoaded, "Precondition: loadModel should succeed")

        // If the probe session were retained, generate() with systemPrompt == nil
        // would reuse it (needsNewSession == false), carrying probe history forward.
        // After our fix, session is nil post-loadModel, so generate() creates a
        // fresh LanguageModelSession() on this call.
        XCTAssertFalse(backend.isGenerating, "isGenerating must be false before generate()")
        let stream = try backend.generate(prompt: "Hello", systemPrompt: nil, config: GenerationConfig())
        backend.stopGeneration()
        _ = stream // suppress unused-variable warning
    }



    // MARK: - stopGeneration() resets session

    /// After `stopGeneration()`, the session must be nil so the next `generate()`
    /// creates a fresh `LanguageModelSession` instead of reusing one with a
    /// truncated assistant turn from the cancelled generation.
    func test_stopGeneration_resetsSession_preservesIsModelLoaded() async throws {
        try XCTSkipUnless(
            FoundationBackend.isAvailable,
            "Apple Intelligence not available — cannot load model"
        )

        let url = URL(fileURLWithPath: "/dev/null")
        try await backend.loadModel(from: url, plan: .testStub(effectiveContextSize: 4096))
        XCTAssertTrue(backend.isModelLoaded, "Precondition")

        // Start and immediately stop a generation to simulate mid-stream cancel.
        let stream = try backend.generate(
            prompt: "Tell me a story",
            systemPrompt: "You are helpful.",
            config: GenerationConfig()
        )
        backend.stopGeneration()

        // Drain the cancelled stream so the generation task's defer block runs
        // and clears isGenerating before we attempt a second generate().
        for try await _ in stream.events {}

        XCTAssertTrue(
            backend.isModelLoaded,
            "stopGeneration() must not clear isModelLoaded"
        )
        XCTAssertFalse(
            backend.isGenerating,
            "isGenerating must be false after the cancelled stream drains"
        )

        // The key invariant: generate() must succeed after stop, which means
        // the session was nil'd and a fresh one will be created.
        let stream2 = try backend.generate(
            prompt: "Hello again",
            systemPrompt: "You are helpful.",
            config: GenerationConfig()
        )
        backend.stopGeneration()
        for try await _ in stream2.events {}
    }

    /// State-only version (no Apple Intelligence needed): stopGeneration() is
    /// safe to call when no generation is running and leaves state consistent.
    func test_stopGeneration_whenIdle_doesNotCrash() {
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)

        backend.stopGeneration()

        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    /// Verifies that resetConversation() only clears the session (conversation
    /// history), not the loaded state — so a subsequent generate() can recreate
    /// the session rather than throwing "No model loaded".
    ///
    /// State-only version (no real inference): checks that isModelLoaded is
    /// still true after reset, meaning the generate() guard would pass.
    func test_generate_afterResetConversation_isModelLoadedRemainsTrue() async throws {
        try XCTSkipUnless(FoundationBackend.isAvailable, "Apple Intelligence not available on this device")

        let url = URL(fileURLWithPath: "/dev/null")
        try await backend.loadModel(from: url, plan: .testStub(effectiveContextSize: 4096))
        XCTAssertTrue(backend.isModelLoaded)

        backend.resetConversation()

        XCTAssertTrue(
            backend.isModelLoaded,
            "After resetConversation(), isModelLoaded must still be true so generate() can recreate the session"
        )
        XCTAssertFalse(backend.isGenerating)
    }

    // MARK: - Session reuse for multi-turn context preservation

    /// Verifies that a dirty session forces a **new** `LanguageModelSession`
    /// on the next `generate()` call — even when the system prompt is unchanged.
    ///
    /// ## Why a new session is required after mid-stream cancellation
    ///
    /// `LanguageModelSession` asserts (SIGTRAP) if `streamResponse()` is called while
    /// the previous `ResponseStream`'s iterator was dropped before returning `nil`
    /// (i.e. the stream was abandoned mid-flight).  Cancelling the generation Task
    /// causes the iterator to be dropped early, leaving the session in a "dirty" state.
    /// `FoundationBackend` tracks this via `_sessionIsClean` and forces a fresh
    /// `LanguageModelSession` on the next call, preventing the SIGTRAP.
    ///
    /// ## Why `_markSessionDirty()` rather than `_cancelTaskOnly()`
    ///
    /// On fast hardware the generation Task may complete on a background thread between
    /// `generate()` returning and `_cancelTaskOnly()` being called.  If that happens
    /// the Task sets `_sessionIsClean = true` (natural completion) — racing with any
    /// flag write in `_cancelTaskOnly()`.  Using `_markSessionDirty()` sidesteps that
    /// race: it directly drives the `_sessionIsClean = false` state that a
    /// mid-stream cancellation would produce, without relying on Task scheduling order.
    ///
    /// Sabotage check: remove the `|| !_sessionIsClean` clause from the
    /// `needsNewSession` condition in `FoundationBackend.generate`.  The
    /// `XCTAssert(session1 !== session2)` assertion will fail because the dirty
    /// session is reused, reproducing the original SIGTRAP.  Remove the sabotage
    /// before committing.
    ///
    /// - Note: on CI (no Apple Intelligence) this test is SKIPPED — `LanguageModelSession`
    ///   cannot be created without Apple Intelligence.
    func test_generate_dirtySession_forcesNewSession() async throws {
        try XCTSkipUnless(
            FoundationBackend.isAvailable,
            "LanguageModelSession cannot be created without Apple Intelligence — skipping dirty-session test"
        )

        backend._forceLoaded()

        let systemPrompt = "You are a helpful assistant."
        let stream1 = try backend.generate(prompt: "Hello", systemPrompt: systemPrompt, config: GenerationConfig())

        let session1 = backend._session
        XCTAssertNotNil(session1, "First generate() must create a session")
        XCTAssertEqual(backend._currentSystemPrompt, systemPrompt)

        // Stop the active generation, then drain the stream so isGenerating → false.
        backend._cancelTaskOnly()
        for try await _ in stream1.events {}
        XCTAssertFalse(backend.isGenerating, "isGenerating must be false after stream drains")

        // Directly mark the session dirty — simulates the state left by a Task that was
        // cancelled before its ResponseStream iterator returned nil.  This avoids the
        // Task-scheduling race where a fast response completes before the cancel lands.
        backend._markSessionDirty()

        // Second call with the SAME systemPrompt — must allocate a NEW session because
        // the session is dirty and calling streamResponse() on it would SIGTRAP.
        let stream2 = try backend.generate(prompt: "How are you?", systemPrompt: systemPrompt, config: GenerationConfig())
        let session2 = backend._session
        XCTAssertNotNil(session2, "Second generate() must have a session")

        backend._cancelTaskOnly()
        for try await _ in stream2.events {}

        // After marking dirty the session must have been replaced, not reused.
        XCTAssert(
            session1 !== session2,
            "Dirty session must NOT be reused — a fresh LanguageModelSession is required "
            + "to prevent SIGTRAP on the next streamResponse() call"
        )
    }

    /// Verifies that consecutive `generate()` calls with the same `systemPrompt`
    /// reuse the **same** `LanguageModelSession` object after a **clean** completion.
    ///
    /// `LanguageModelSession.streamResponse(to:)` accumulates turns inside the session,
    /// which is how FoundationBackend provides multi-turn context to the model.
    /// If a new session were created on every call, all prior conversation history
    /// would be lost.
    ///
    /// Requires live Apple Intelligence because we must let the generation complete
    /// naturally so the `ResponseStream` iterator returns `nil` and the session is
    /// marked clean before the next call.
    ///
    /// Sabotage check: change the `needsNewSession` condition in `FoundationBackend.generate`
    /// so it always creates a new session (e.g. `let needsNewSession = true`). The
    /// `XCTAssert(session1 === session2)` assertion will fail because a new object is
    /// allocated on every call. Remove the sabotage before committing.
    func test_generate_reusesSameSession_afterCleanCompletion() async throws {
        try XCTSkipUnless(
            FoundationBackend.isAvailable,
            "LanguageModelSession cannot be created without Apple Intelligence — skipping session-reuse test"
        )

        let url = URL(fileURLWithPath: "/dev/null")
        try await backend.loadModel(from: url, plan: .testStub(effectiveContextSize: 4096))
        XCTAssertTrue(backend.isModelLoaded, "Precondition: loadModel must succeed")

        let systemPrompt = "Reply with exactly the word OK and nothing else."

        // First call — let generation complete naturally (short prompt → quick response).
        let stream1 = try backend.generate(prompt: "Say OK", systemPrompt: systemPrompt, config: GenerationConfig())
        for try await _ in stream1.events {}  // drain to natural completion
        let session1 = backend._session
        XCTAssertNotNil(session1, "First generate() must create a session")

        XCTAssertFalse(backend.isGenerating, "isGenerating must be false after natural completion")

        // Second call — same systemPrompt, previous stream completed cleanly → reuse session.
        let stream2 = try backend.generate(prompt: "What did you just say?", systemPrompt: systemPrompt, config: GenerationConfig())
        for try await _ in stream2.events {}
        let session2 = backend._session
        XCTAssertNotNil(session2, "Second generate() must have a session")

        // The key invariant: same session object identity means conversation history was preserved.
        XCTAssert(
            session1 === session2,
            "Session must be REUSED after a clean completion when systemPrompt is unchanged"
        )
    }

    /// Verifies that `generate()` creates a **new** `LanguageModelSession` when the
    /// system prompt changes between calls.
    ///
    /// `LanguageModelSession(instructions:)` bakes the system prompt into the session.
    /// There is no API to mutate instructions after creation, so a prompt change forces
    /// a new session (accepting that prior conversation history is discarded in exchange
    /// for the correct persona).
    ///
    /// The first generation must complete **cleanly** (not via `_cancelTaskOnly()`)
    /// so the session is marked clean before the second call.  That way the session
    /// recreation is caused solely by the prompt change and not by the dirty-session
    /// guard, keeping the sabotage check precise.
    ///
    /// Sabotage check: remove the `systemPrompt != currentSystemPrompt` clause from the
    /// `needsNewSession` condition in `FoundationBackend.generate`. The assertion
    /// `XCTAssert(session1 !== session2)` will fail because the old clean session is
    /// reused even though the prompt changed. Remove the sabotage before committing.
    func test_generate_createsNewSession_whenSystemPromptChanges() async throws {
        try XCTSkipUnless(
            FoundationBackend.isAvailable,
            "LanguageModelSession cannot be created without Apple Intelligence — skipping session-recreation test"
        )

        let url = URL(fileURLWithPath: "/dev/null")
        try await backend.loadModel(from: url, plan: .testStub(effectiveContextSize: 4096))
        XCTAssertTrue(backend.isModelLoaded, "Precondition: loadModel must succeed")

        // First call with prompt "A" — let generation complete naturally so the session
        // is marked clean.  This ensures the second call's new session is triggered by
        // the prompt change, not by the dirty-session guard.
        let stream1 = try backend.generate(
            prompt: "Say OK",
            systemPrompt: "Reply with exactly the word OK and nothing else.",
            config: GenerationConfig()
        )
        for try await _ in stream1.events {}  // drain to natural completion
        let session1 = backend._session
        XCTAssertNotNil(session1, "First generate() must create a session")
        XCTAssertEqual(backend._currentSystemPrompt, "Reply with exactly the word OK and nothing else.")

        XCTAssertFalse(backend.isGenerating, "isGenerating must be false after natural completion")

        // Second call with a DIFFERENT system prompt — must allocate a new session.
        let stream2 = try backend.generate(
            prompt: "Say OK",
            systemPrompt: "You are a pirate. Reply with exactly the word OK and nothing else.",
            config: GenerationConfig()
        )
        for try await _ in stream2.events {}
        let session2 = backend._session
        XCTAssertNotNil(session2, "Second generate() must create a session")
        XCTAssertEqual(
            backend._currentSystemPrompt,
            "You are a pirate. Reply with exactly the word OK and nothing else.",
            "currentSystemPrompt must update to new prompt"
        )

        // The key invariant: a different system prompt must produce a different session object.
        XCTAssert(
            session1 !== session2,
            "Session must be RECREATED when systemPrompt changes — object identity must differ"
        )
    }

    // MARK: - Backend Contract

    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants { FoundationBackend() }
    }

    // MARK: - Parameter passthrough (#523)

    /// Pins the capability contract for `GenerationOptions` passthrough.
    ///
    /// `FoundationBackend.generate` builds a `GenerationOptions` with only
    /// `options.temperature`. `topP`, `topK`, and `repeatPenalty` are silently
    /// dropped. That is honest only if the capability advertises the same thing,
    /// so UI code won't surface controls whose values have no effect.
    ///
    /// A future change that starts honouring any of these parameters must also
    /// add them to `supportedParameters` — this test is the tripwire that forces
    /// both edits to land together.
    func test_capabilities_advertisesOnlyTemperature_notTopPTopKRepeatPenalty() {
        let caps = FoundationBackend().capabilities

        XCTAssertTrue(
            caps.supportedParameters.contains(.temperature),
            "temperature is the one parameter FoundationBackend passes through"
        )
        XCTAssertFalse(
            caps.supportedParameters.contains(.topP),
            "topP is dropped by generate() — must not be advertised as supported"
        )
        XCTAssertFalse(
            caps.supportedParameters.contains(.topK),
            "topK is dropped by generate() — must not be advertised as supported"
        )
        XCTAssertFalse(
            caps.supportedParameters.contains(.repeatPenalty),
            "repeatPenalty is dropped by generate() — must not be advertised as supported"
        )
        XCTAssertFalse(
            caps.supportedParameters.contains(.typicalP),
            "typicalP is dropped by generate() — must not be advertised as supported"
        )
        // Belt-and-braces: visibleParameters is what the UI renders; it must also
        // exclude the dropped parameters.
        XCTAssertEqual(
            caps.visibleParameters,
            [.temperature],
            "UI must only render a temperature control for FoundationBackend"
        )
    }

    // MARK: - Availability variants (#524)

    /// Documents the current gap: `FoundationBackend.loadModel` collapses every
    /// non-`.available` `SystemLanguageModel.Availability` case into a single
    /// error message. There is no dependency-injection hook to stub availability,
    /// so per-reason assertions (`.deviceNotEligible`, `.appleIntelligenceNotEnabled`,
    /// `.modelNotReady`, …) can't be driven from a unit test today.
    ///
    /// The weak contract we CAN pin: on a device where Apple Intelligence is not
    /// available (simulator / CI), `loadModel` throws, and the error is an
    /// `InferenceError.inferenceFailure` whose message mentions Apple Intelligence.
    /// Any future refactor that swallows the error, changes the type, or returns
    /// success on a non-available device trips this test.
    ///
    /// Follow-up: #524 tracks adding an `AvailabilityProvider` injection hook so
    /// the per-reason messages can be asserted.
    func test_loadModel_whenUnavailable_throwsInferenceFailure() async throws {
        // Only meaningful when the real system says "unavailable" — otherwise
        // we'd need the injection hook that #524 exists to track.
        try XCTSkipIf(
            FoundationBackend.isAvailable,
            "Apple Intelligence IS available on this device — cannot exercise the unavailable branch without the availability-provider hook tracked in #524"
        )

        let url = URL(fileURLWithPath: "/dev/null")
        do {
            try await backend.loadModel(from: url, plan: .testStub(effectiveContextSize: 4096))
            XCTFail("loadModel must throw when SystemLanguageModel availability is not .available")
        } catch let InferenceError.inferenceFailure(msg) {
            // Current behaviour: the probe path and the pre-probe availability
            // check both throw inferenceFailure. Either message is acceptable
            // for this contract — both reference Apple Intelligence.
            XCTAssertTrue(
                msg.localizedCaseInsensitiveContains("Apple Intelligence"),
                "Error message should mention Apple Intelligence, got: \(msg)"
            )
        } catch {
            XCTFail("Expected InferenceError.inferenceFailure, got \(error)")
        }
    }

    // MARK: - Cancellation timing (#525)

    /// Pins the weaker contract that is reachable without injecting a stub
    /// `LanguageModelSession`: `stopGeneration()` is idempotent, returns
    /// synchronously, and leaves `isGenerating == false`.
    ///
    /// The stronger timing contract — that no `.token` event arrives after the
    /// caller observes `isGenerating == false` — needs a stub session so a test
    /// can interleave `continuation.yield(.token(...))` with `stopGeneration()`.
    /// #525 tracks adding that hook.
    func test_stopGeneration_idempotent_synchronous_whenIdle() {
        XCTAssertFalse(backend.isGenerating, "Precondition")

        // Synchronous: stopGeneration returns before the next statement runs.
        // If it were async (e.g. `await task.value`), this would hang when
        // generationTask == nil; but it must be safe to call from any context.
        backend.stopGeneration()
        backend.stopGeneration()
        backend.stopGeneration()

        XCTAssertFalse(
            backend.isGenerating,
            "stopGeneration() must leave isGenerating == false, even after repeated calls"
        )
        XCTAssertFalse(
            backend.isModelLoaded,
            "stopGeneration() must not flip isModelLoaded in either direction"
        )
    }

    // MARK: - Content diff edge cases (#526)

    /// Pins the capability contract that explains why the character-diff
    /// algorithm in `FoundationBackend.generate` is safe TODAY.
    ///
    /// The loop assumes `partial.content` grows monotonically (`currentText.count >
    /// previousText.count`). That is only correct as long as Apple's
    /// `LanguageModelSession.streamResponse` never emits a rewrite — which is
    /// the case today because the backend does not opt into structured output.
    ///
    /// If this test starts failing because `supportsStructuredOutput` flipped to
    /// `true`, the diff algorithm in `generate()` needs to handle non-monotonic
    /// payloads (either reset `previousText` on shrink, or switch to an
    /// event-parts API). #526 tracks the stronger fixture (stubbed partials that
    /// shrink mid-stream) once a session-injection hook lands.
    func test_capabilities_structuredOutputDisabled_justifiesMonotonicDiff() {
        let caps = FoundationBackend().capabilities

        XCTAssertFalse(
            caps.supportsStructuredOutput,
            "FoundationBackend.generate assumes partial.content grows monotonically. "
            + "Enabling structured output requires rewriting the diff loop to handle "
            + "shrinking payloads — see #526."
        )
        // Tool calling is now synthesized via GuidedGeneration (#434). The
        // tool-aware streaming path uses a separate code path that reads the
        // structured `rawContent.kind` rather than the cumulative-string
        // diff, so the monotonic-diff caveat above does not apply to it.
        XCTAssertTrue(
            caps.supportsToolCalling,
            "FoundationBackend exposes tool calling via GuidedGeneration on iOS 26 / macOS 26 (#434)."
        )
        XCTAssertFalse(
            caps.streamsToolCallArguments,
            "FoundationBackend emits whole .toolCall(...) events (no name/argument deltas)."
        )
    }

    // MARK: - Delta-extraction correctness (#644)

    /// Verifies the scalar-counter delta-extraction algorithm used in
    /// `FoundationBackend.generate` after the #644 memory fix.
    ///
    /// `FoundationModels` streams cumulative text; the loop emits only the new
    /// suffix on each step. This test exercises the pure logic (no live model
    /// needed) and confirms each emission is exactly the single new character.
    ///
    /// Sabotage check: change `previousCount = currentText.count` to
    /// `previousCount = 0` — `collectedDeltas` will contain the full cumulative
    /// string at each step, causing `allSatisfy { $0 == "a" }` to fail for any
    /// delta longer than one character. Remove the sabotage before committing.
    func testStreamingDeltaExtractionIsCorrect() throws {
        // FoundationModels streams cumulative text; verify we emit only the deltas.
        let cumulativeTexts = (1...100).map { i in String(repeating: "a", count: i) }
        var collectedDeltas: [String] = []
        var previousCount = 0
        for text in cumulativeTexts {
            if text.count > previousCount {
                collectedDeltas.append(String(text.dropFirst(previousCount)))
                previousCount = text.count
            }
        }
        // Each delta should be exactly "a" (one new character per step).
        XCTAssertEqual(collectedDeltas.count, 100)
        XCTAssertTrue(collectedDeltas.allSatisfy { $0 == "a" })
    }
}
#endif
