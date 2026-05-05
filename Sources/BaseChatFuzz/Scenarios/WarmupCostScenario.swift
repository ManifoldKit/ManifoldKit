import Foundation
import BaseChatInference

/// Measures the warmup penalty paid by a freshly-loaded backend on its first
/// generate call vs. its second.
///
/// `LlamaBackend.swift:250` and `MLXBackend.swift:851` both flip
/// `isModelLoaded = true` before any Metal shader has compiled — so the
/// **first** turn TTFT silently absorbs JIT compilation, kernel build, and
/// any one-shot allocator warmup. Audit claim #2 in the perf-audit plan.
///
/// This scenario times two consecutive `generate("hi")` calls with
/// `maxOutputTokens = 1` against the configured ``FuzzBackendFactory`` and
/// records both raw values plus their delta into ``ScenarioOutcome/extras``.
/// The summary script in `scripts/perf-audit/` reads the per-scenario JSON
/// `RunRecord`s and groups by backend so the audit-ground-truth report has
/// concrete TTFT-1 / TTFT-2 / delta figures per backend.
///
/// The scenario is backend-agnostic on purpose: it goes through the public
/// ``FuzzBackendFactory`` seam and ``InferenceBackend`` protocol, so plugging
/// MLX, Llama, or Foundation into it requires no scenario-side changes.
public struct WarmupCostScenario: FuzzScenario {
    public let id = "warmup-cost"
    public let humanName = "Warmup TTFT-1 vs TTFT-2 across backends"

    private let factory: any FuzzBackendFactory

    /// Default-init keeps the scenario discoverable through ``ScenarioRegistry``.
    /// The default factory wraps a ``ScenarioTestBackend`` so the scenario
    /// runs end-to-end in unit tests without needing a real model on disk —
    /// the assertion of value comes from running it via `scripts/fuzz.sh`
    /// against MLX/Llama/Foundation factories where TTFT-1 vs TTFT-2 actually
    /// reflects shader compile cost.
    public init() {
        self.factory = WarmupCostMockFactory()
    }

    /// Factory-injecting init for fuzz CLI runs and integration coverage.
    public init(factory: any FuzzBackendFactory) {
        self.factory = factory
    }

    public func run() async throws -> ScenarioOutcome {
        let handle: FuzzRunner.BackendHandle
        do {
            handle = try await factory.makeHandle()
        } catch {
            return ScenarioOutcome(
                scenarioId: id,
                invariantHeld: false,
                failureReason: "factory.makeHandle() threw: \(error)"
            )
        }

        var config = GenerationConfig()
        config.maxOutputTokens = 1

        // First turn — pays JIT / shader / allocator cost.
        let (ttft1Ms, events1) = try await timeFirstToken(
            backend: handle.backend,
            prompt: "hi",
            config: config
        )

        // Second turn — same prompt, same config, same backend instance. Any
        // remaining delta after this is steady-state TTFT.
        let (ttft2Ms, events2) = try await timeFirstToken(
            backend: handle.backend,
            prompt: "hi",
            config: config
        )

        let merged = events1 + events2

        guard let ttft1Ms else {
            return ScenarioOutcome(
                scenarioId: id,
                invariantHeld: false,
                failureReason: "first turn produced no token before stream end",
                events: merged
            )
        }
        guard let ttft2Ms else {
            return ScenarioOutcome(
                scenarioId: id,
                invariantHeld: false,
                failureReason: "second turn produced no token before stream end",
                events: merged
            )
        }

        let warmupDeltaMs = ttft1Ms - ttft2Ms
        let extras: [String: String] = [
            "ttft1Ms": String(format: "%.3f", ttft1Ms),
            "ttft2Ms": String(format: "%.3f", ttft2Ms),
            "warmupDeltaMs": String(format: "%.3f", warmupDeltaMs),
            "backendName": handle.backendName,
            "modelId": handle.modelId,
        ]

        // Invariant: both turns produced at least one token. We deliberately
        // do NOT fail when delta is small or negative — the value of this
        // scenario is the recorded numbers, not a pass/fail bound. A
        // regression to "second turn slower than first" would still show up
        // in the summary table.
        return ScenarioOutcome(
            scenarioId: id,
            invariantHeld: true,
            events: merged,
            extras: extras
        )
    }

    /// Drives a single `generate(...)` call and reports the wall-clock time
    /// from `generate(...)` return to the first emitted token, in
    /// milliseconds. Returns `nil` for the timing if the stream never yields
    /// a `.token` event.
    private func timeFirstToken(
        backend: any InferenceBackend,
        prompt: String,
        config: GenerationConfig
    ) async throws -> (Double?, [GenerationEvent]) {
        let start = ContinuousClock.now
        let stream = try backend.generate(
            prompt: prompt,
            systemPrompt: nil,
            config: config
        )
        var firstTokenAt: ContinuousClock.Instant?
        var observed: [GenerationEvent] = []
        for try await event in stream.events {
            if firstTokenAt == nil, case .token = event {
                firstTokenAt = ContinuousClock.now
            }
            observed.append(event)
        }
        let firstTokenMs = firstTokenAt.map {
            start.duration(to: $0).milliseconds
        }
        return (firstTokenMs, observed)
    }
}

// MARK: - Default factory for registry construction

/// Wraps ``ScenarioTestBackend`` as a ``FuzzBackendFactory`` so the
/// scenario is constructible without arguments and still produces a
/// deterministic outcome under unit tests. Real backend factories live in
/// the fuzz CLI / integration host and inject themselves via
/// ``WarmupCostScenario/init(factory:)``.
private struct WarmupCostMockFactory: FuzzBackendFactory {
    func makeHandle() async throws -> FuzzRunner.BackendHandle {
        let backend = ScenarioTestBackend(
            tokensToYield: ["hi"],
            thinkingTokensToYield: [],
            emitThinkingComplete: false
        )
        try await backend.loadModel(
            from: URL(string: "mem://warmup-cost")!,
            plan: .cloud()
        )
        return FuzzRunner.BackendHandle(
            backend: backend,
            modelId: "warmup-cost-mock",
            modelURL: URL(string: "mem://warmup-cost")!,
            backendName: "ScenarioTestBackend",
            templateMarkers: nil
        )
    }
}

private extension Duration {
    var seconds: Double {
        let comps = self.components
        return Double(comps.seconds) + Double(comps.attoseconds) / 1e18
    }
    var milliseconds: Double { seconds * 1000 }
}
