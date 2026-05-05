import Foundation
import BaseChatInference

/// A targeted end-to-end fuzz scenario.
///
/// Scenarios differ from ``Detector`` in direction of travel:
///
/// - A ``Detector`` inspects a recorded ``RunRecord`` **post-hoc** and flags a
///   bug shape across many runs.
/// - A `FuzzScenario` **drives** a backend with a specific input pattern (budget
///   setting, cancellation timing, retry storm, …) and asserts an invariant on
///   the resulting event stream.
///
/// Scenarios live next to detectors so the harness can enumerate them via
/// ``ScenarioRegistry`` the same way it enumerates detectors, and so the
/// XCTest harness can execute each scenario's invariant as a focused test.
///
/// Scenarios are deliberately **not** part of `FuzzRunner.runSingle`'s loop —
/// they are a separate axis of coverage that exercises control-flow shapes
/// (cancel, retry, disable-thinking) a random corpus can't reach reliably.
public protocol FuzzScenario: Sendable {
    /// Stable identifier — used as the scenario's trigger string and for
    /// discovery via `--scenario=<id>` on the CLI (future work).
    var id: String { get }

    /// One-line description shown in harness logs and CI reports.
    var humanName: String { get }

    /// Runs the scenario end-to-end. The implementation is expected to:
    ///
    /// 1. Build (or accept) an ``InferenceBackend`` that can be driven through
    ///    a known event sequence.
    /// 2. Invoke `generate(…)` with the configuration the scenario needs.
    /// 3. Consume the resulting ``GenerationStream`` and collect the event
    ///    timeline.
    /// 4. Evaluate the scenario's invariant against that timeline.
    ///
    /// Returns a ``ScenarioOutcome`` so tests can assert on the structured
    /// result without having to re-run the scenario themselves.
    func run() async throws -> ScenarioOutcome
}

/// The structured result of a single ``FuzzScenario`` invocation.
///
/// `invariantHeld` is the bit the test harness asserts on. `events` is the
/// post-filter timeline the scenario saw, retained so failure diagnostics can
/// surface the exact shape that broke the invariant.
public struct ScenarioOutcome: Sendable, Equatable {
    public let scenarioId: String
    public let invariantHeld: Bool
    public let failureReason: String?
    public let events: [GenerationEvent]
    /// Free-form key/value payload scenarios can use to surface measurements
    /// alongside the invariant result — e.g. ``WarmupCostScenario`` records
    /// `ttft1Ms`, `ttft2Ms`, and `warmupDeltaMs` so the perf-audit summary
    /// script can aggregate them into a Markdown table without re-running.
    /// Defaults to empty so existing scenarios stay source-compatible.
    public let extras: [String: String]

    public init(
        scenarioId: String,
        invariantHeld: Bool,
        failureReason: String? = nil,
        events: [GenerationEvent] = [],
        extras: [String: String] = [:]
    ) {
        self.scenarioId = scenarioId
        self.invariantHeld = invariantHeld
        self.failureReason = failureReason
        self.events = events
        self.extras = extras
    }

    public func finding(modelId: String) -> Finding? {
        guard !invariantHeld else { return nil }
        return Finding(
            detectorId: "scenario/\(scenarioId)",
            subCheck: "invariant",
            severity: .confirmed,
            trigger: failureReason ?? "invariant violated",
            modelId: modelId
        )
    }
}

/// Enumerates the scenarios shipped with the harness. Parallel in spirit to
/// ``DetectorRegistry``.
///
/// Scenario construction is kept cheap (no network, no large allocations) so
/// the registry itself is a pure function of the build. Scenarios that need
/// configuration (e.g. a specific retry count) expose initialiser arguments;
/// the registry returns instances configured with defaults that are sensible
/// for CI.
public enum ScenarioRegistry {
    public static var all: [any FuzzScenario] {
        [
            ThinkingBudgetZeroScenario(),
            CancelDuringThinkingScenario(),
            ThinkingAcrossRetryScenario(),
            WarmupCostScenario(),
        ]
    }

    public static func resolve(_ filter: Set<String>?) -> [any FuzzScenario] {
        guard let filter else { return all }
        return all.filter { filter.contains($0.id) }
    }
}
