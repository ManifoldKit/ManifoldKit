import XCTest
import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldOllama

/// True end-to-end **streaming cancellation** tests against a real local Ollama
/// server at `localhost:11434`.
///
/// ## Why this suite exists
///
/// Streaming cancellation is otherwise only exercised hermetically through the
/// scripted Mock backend, where the emission gate makes the cancel point
/// deterministic. Live cancellation is *inherently racy* — the model may finish
/// before the cancel lands — which is why `GlassBoxScenarioLiveE2ETests`
/// deliberately excludes cancellation scenarios from its structural gate (see
/// `RuntimeScenarioRunner.driveCancelWithoutGate`).
///
/// This suite proves the part of cancellation that *is* deterministic: that
/// calling the real caller cancel path — `OllamaBackend.stopGeneration()`,
/// whose `cancellationStyle` is `.cooperative` — leaves the backend in a clean,
/// reusable state. It asserts **only robust post-conditions** and never inspects
/// mid-stream token counts, timing, or whether the cancel "won" the race:
///
/// - the event stream terminates within a bounded wait after `stopGeneration()`,
/// - `backend.isGenerating == false` afterward (the `InferenceBackend`
///   contract's synchronous stop-took-effect signal), and
/// - the backend is reusable: a subsequent short generation against the same
///   loaded model succeeds and produces non-empty output.
///
/// If the model finishes before the cancel lands, the test still passes —
/// "completed before cancel" is an acceptable outcome. The value is proving the
/// backend recovers cleanly, not catching the stream mid-flight.
///
/// ## Tier and gating
///
/// Nightly live tier, not a per-PR gate. Automatically skips when no Ollama
/// server is reachable or no suitable model is installed — exactly like the
/// sibling `OllamaE2ETests` / `GlassBoxScenarioLiveE2ETests` suites — so the
/// default `swift test` lane never requires a live server.
@MainActor
final class OllamaCancellationE2ETests: XCTestCase {

    private var backend: OllamaBackend!
    private var modelName: String!

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()

        try XCTSkipUnless(
            HardwareRequirements.hasOllamaServer,
            "Ollama server not running at localhost:11434 — live cancellation tier skipped"
        )

        guard let model = HardwareRequirements.findOllamaModel() else {
            throw XCTSkip("No suitable Ollama model installed — live cancellation tier skipped")
        }
        modelName = model

        backend = OllamaBackend()
        backend.configure(
            baseURL: URL(string: "http://localhost:11434")!,
            modelName: modelName
        )
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
    }

    override func tearDown() async throws {
        backend?.unloadModel()
        backend = nil
        modelName = nil
        try await super.tearDown()
    }

    // MARK: - Tests

    /// Drives a long generation, consumes a few events, calls the real caller
    /// cancel path (`stopGeneration()`), and asserts only deterministic
    /// post-conditions: the stream terminates within a bounded wait, the backend
    /// reports it is no longer generating, and it is reusable for a fresh
    /// generation.
    ///
    /// Deliberately makes NO assertion about *when* the cancel lands relative to
    /// model completion — that is the racy part. Whether the model finishes
    /// first or the cancel interrupts it, the clean-state post-conditions hold.
    func test_liveCancellation_leavesBackendCleanAndReusable() async throws {
        let config = GenerationConfig(
            temperature: 0.7,
            // Generous budget so the prompt is *likely* (not guaranteed) to be
            // long-running, giving the cancel a chance to land mid-stream.
            maxOutputTokens: 2048
        )

        let stream = try backend.generate(
            prompt: "Write a very detailed, multi-section essay about the complete "
                + "history of computing from the 1940s to today. Include many examples.",
            systemPrompt: nil,
            config: config
        )

        // Consume a few events deterministically (no Task.yield hacks), then
        // cancel. Ollama may take 10-20s to load the model into VRAM on the
        // first request, so wait for real evidence the stream is flowing before
        // cancelling rather than racing a fixed delay.
        //
        // Iterating until the stream naturally ends after cancel lets us observe
        // termination directly. We bound the whole consume-then-drain with a
        // tight deadline below rather than awaiting unbounded.
        let drained = Task<Bool, Error> {
            var seenEvents = 0
            var cancelRequested = false
            for try await event in stream.events {
                switch event {
                case .token, .thinkingToken:
                    seenEvents += 1
                default:
                    break
                }
                // After a few events confirm the stream is live, request the
                // stop via the same path a real caller uses.
                if seenEvents >= 5 && !cancelRequested {
                    cancelRequested = true
                    self.backend.stopGeneration()
                }
            }
            // Loop exit == stream terminated (cancelled or completed first).
            // `cancelRequested` may be false only if the model finished before
            // 5 events — an acceptable "completed before cancel" outcome.
            return cancelRequested
        }

        // Bounded wait: the stream MUST terminate well within this deadline once
        // cancellation is requested (or because the model finished). A hang here
        // would mean cancellation failed to terminate the stream — a real bug,
        // not flake. 60s tolerates first-request VRAM load on slow hardware.
        let cancelRequested = try await withDeadline(
            seconds: 60,
            "generation stream did not terminate within the deadline after cancellation"
        ) {
            try await drained.value
        }

        // POST-CONDITION 1: backend settles to not-generating after the stream
        // terminates. `stopGeneration()` clears the flag synchronously, but when
        // the model completes naturally the backend clears it asynchronously in
        // its `finishGeneration` closure (SSECloudBackend), which can lag the
        // consumer observing the final event. We poll for the flag to settle
        // rather than asserting a synchronous flip the contract doesn't promise.
        try await waitForNotGenerating()
        XCTAssertFalse(
            backend.isGenerating,
            "Backend should settle to isGenerating == false after the stream terminates "
                + "(model: \(modelName!), cancelRequested: \(cancelRequested))"
        )

        // POST-CONDITION 2: backend is reusable without reloading the model.
        // A subsequent short generation against the same loaded backend must
        // succeed and produce non-empty output — proving cancel/completion left
        // no corrupted session or stale state (InferenceBackend contract §2).
        let followUp = try await collectVisibleOrThinking(
            prompt: "Reply with exactly one short sentence.",
            maxTokens: 256
        )
        XCTAssertTrue(
            followUp,
            "Backend should be reusable after cancellation: a fresh generation "
                + "must produce output (model: \(modelName!))"
        )
        try await waitForNotGenerating()
        XCTAssertFalse(
            backend.isGenerating,
            "Backend should settle to not-generating after the follow-up completes (model: \(modelName!))"
        )
    }

    /// Polls `isGenerating` until it settles to `false`, up to `timeout`.
    ///
    /// Natural stream completion clears the flag asynchronously in the backend's
    /// `finishGeneration` closure, so it can briefly read `true` immediately
    /// after the consumer drains the final event. The meaningful guarantee is
    /// that the backend *does* settle to idle — not that the flag flips in
    /// lockstep with the last token — so a bounded poll is the correct,
    /// non-racy check. A backend genuinely stuck generating fails here when the
    /// deadline elapses.
    private func waitForNotGenerating(timeout: Double = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while backend.isGenerating && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        }
    }

    // MARK: - Helpers

    /// Runs a short generation and returns `true` if it produced *any* evidence
    /// of output — visible tokens for plain models, or thinking events for
    /// reasoning models whose visible portion may be empty on a trivial prompt
    /// (see the budget rationale in `OllamaE2ETests`).
    private func collectVisibleOrThinking(prompt: String, maxTokens: Int) async throws -> Bool {
        let config = GenerationConfig(temperature: 0.3, maxOutputTokens: maxTokens)
        let stream = try backend.generate(prompt: prompt, systemPrompt: nil, config: config)

        var visibleText = ""
        var thinkingTokens = 0
        var thinkingCompleted = false
        for try await event in stream.events {
            switch event {
            case .token(let text):
                visibleText += text
            case .thinkingToken:
                thinkingTokens += 1
            case .thinkingCompleted:
                thinkingCompleted = true
            default:
                continue
            }
        }
        return !visibleText.isEmpty || (thinkingTokens > 0 && thinkingCompleted)
    }

    /// Awaits `operation` with a hard deadline. Throws a descriptive failure if
    /// the deadline elapses first, so a cancellation-that-fails-to-terminate
    /// surfaces as a bounded, attributable failure rather than an unbounded hang.
    private func withDeadline<T: Sendable>(
        seconds: Double,
        _ message: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw DeadlineExceeded(message: message)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw DeadlineExceeded(message: message)
            }
            return result
        }
    }

    private struct DeadlineExceeded: Error, CustomStringConvertible {
        let message: String
        var description: String { "Deadline exceeded: \(message)" }
    }
}
