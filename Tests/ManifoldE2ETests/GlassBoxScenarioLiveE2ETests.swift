import XCTest
import ManifoldInference
import ManifoldRuntime
@testable import ManifoldTestSupport
@testable import ManifoldContractTestSupport
@testable import ManifoldBackends

/// Live-backend counterpart to the hermetic `RuntimeScenarioRunnerTests`
/// scripted-mode gate (issue #1576).
///
/// Where `test_allRegisteredScenarios_passInScriptedMode` runs every
/// ``RuntimeScenarioRegistry`` entry through a `ScriptedGenerationBackend`,
/// this suite runs the *structurally model-independent* subset against a real
/// local Ollama server and asserts only the scenario's
/// ``RuntimeScenario/expectedSubsequence`` — the same `[ConversationEventKind]`
/// oracle the scripted gate uses. Token content is never inspected: it is
/// nondeterministic in a live run.
///
/// ## Tier and gating
///
/// This is a **nightly live-tier** suite, not a per-PR gate. It is
/// automatically skipped when:
/// - No Ollama server is reachable at `localhost:11434`
///   (`HardwareRequirements.hasOllamaServer`), or
/// - No suitable model is installed.
///
/// So the default `swift test` lane (and CI's per-PR gate) never requires a
/// live server — the whole suite skips cleanly. The dedicated nightly job
/// (`.github/workflows/nightly.yml` → `glassbox-live-e2e`) stands up Ollama,
/// pulls a model, sets `OLLAMA_TEST_MODEL`, and runs only this suite so a flaky
/// live model produces a *distinct* nightly failure that does not block PRs.
///
/// ## Scenario subset
///
/// Some registered scenarios assert events that only a *scripted* backend can
/// produce deterministically and that a healthy live model will not emit:
/// - `.errorRaised` — `midStreamErrorRecovery` forces an upstream error; a live
///   backend completes normally.
/// - `.toolCallRequested` — `toolRoundTrip` depends on the model choosing to
///   call a tool, which is nondeterministic.
/// - cancellation turns — `cancelMidStream` drives the scripted backend's
///   emission gate; live cancellation is inherently racy and explicitly *not*
///   part of any gate (see `RuntimeScenarioRunner.driveCancelWithoutGate`).
///
/// These are filtered out by inspecting scenario shape (not hardcoded IDs) so
/// the subset tracks the registry automatically. Everything else — plain
/// streams, multi-turn lifecycles, context assembly, and history compression —
/// is runtime-emitted lifecycle structure that holds regardless of which
/// backend drives the conversation, exactly as documented on
/// ``RuntimeScenario/expectedSubsequence``.
@MainActor
final class GlassBoxScenarioLiveE2ETests: XCTestCase {

    private var backend: OllamaBackend!
    private var modelName: String!

    override func setUp() async throws {
        try await super.setUp()

        try XCTSkipUnless(
            HardwareRequirements.hasOllamaServer,
            "Ollama server not running at localhost:11434 — live Glass Box tier skipped"
        )

        guard let model = HardwareRequirements.findOllamaModel() else {
            throw XCTSkip("No suitable Ollama model installed — live Glass Box tier skipped")
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

    /// Runs every live-eligible registered scenario against the real backend and
    /// asserts the structural `[ConversationEventKind]` subsequence — the same
    /// oracle as the scripted gate. New scenarios added to
    /// ``RuntimeScenarioRegistry`` are picked up automatically.
    func test_allRegisteredScenarios_passInLiveMode() async throws {
        let eligible = RuntimeScenarioRegistry.all.filter(Self.isLiveEligible)
        XCTAssertFalse(
            eligible.isEmpty,
            "Expected at least one live-eligible scenario in the registry"
        )

        for scenario in eligible {
            let result = try await RuntimeScenarioRunner.run(
                scenario,
                mode: .live(backend: backend)
            )
            XCTAssertTrue(
                result.subsequencePassed,
                "Live scenario '\(scenario.id)' (model: \(modelName!)) failed structural subsequence: "
                    + (result.subsequenceFailureReason ?? "<no reason>")
            )
        }
    }

    // MARK: - Live-eligibility filter

    /// A scenario is live-eligible when its expected structural subsequence
    /// contains only runtime-emitted lifecycle events that a healthy live
    /// backend reproduces — i.e. it does *not* depend on the model erroring,
    /// emitting a tool call, or being cancelled mid-stream.
    ///
    /// Determined from scenario shape rather than IDs so the subset tracks the
    /// registry as it grows.
    static func isLiveEligible(_ scenario: RuntimeScenario) -> Bool {
        // Cancellation turns drive the scripted emission gate; live cancel is racy.
        let hasCancelTurn = scenario.turns.contains { $0.cancelAfterTokens != nil }
        if hasCancelTurn { return false }

        // Model-content-dependent events a healthy live backend won't emit on demand.
        let modelDependentKinds: Set<ConversationEventKind> = [.errorRaised, .toolCallRequested]
        if scenario.expectedSubsequence.contains(where: { modelDependentKinds.contains($0) }) {
            return false
        }
        return true
    }
}
