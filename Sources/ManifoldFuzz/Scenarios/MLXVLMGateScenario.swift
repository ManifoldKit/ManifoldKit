import Foundation
import ManifoldInference

/// Drives a backend through two prefix-sharing turns and records whether any
/// `.kvCacheReuse(promptTokensReused:)` events appear, intended primarily for
/// MLX VLMs where reuse is gated off today.
///
/// The audit's ground-truth claim is "VLM sessions pay full prompt-prefill on
/// every turn because `MLXBackend` ANDs `enableKVCacheReuse` with
/// `!routeThroughVLMFactory`." This scenario is *designed* to capture the
/// empirical evidence for that claim against a real MLX VLM, stashing it in
/// ``ScenarioOutcome/events`` so a follow-up summary script could compare
/// pre- and post-gate-removal runs — but nothing currently supplies that
/// factory (see below), so today it only ever exercises the skip branch.
///
/// **When the gate is removed in a future PR**, the scenario starts seeing
/// `.kvCacheReuse(promptTokensReused: > 0)` on the second turn and the
/// invariant in ``run()`` will need to flip from "must be empty" to "must
/// fire on turn 2". Until then a held invariant means either the gate is
/// intact *or* the scenario was skipped — see the caveat below.
///
/// **As of 2026-07 this scenario is unwired and effectively inert.**
/// `ScenarioRegistry.all` registers it with the default `factory: nil`, so
/// `run()` always takes the skip-only path and trivially reports
/// `invariantHeld: true` without ever driving a backend. Neither
/// `Sources/fuzz-chat/FuzzChatCLI.swift` nor `Sources/ManifoldFuzzBackends`
/// references this scenario or a type named `MLXFuzzFactory` — no such type
/// exists anywhere in this repo or in the manifold-mlx companion package
/// (checked 2026-07). Making the invariant meaningful again requires the
/// manifold-mlx repo (or a future MLX-aware fuzz driver) to construct
/// `MLXVLMGateScenario(factory:)` explicitly with a real
/// `FuzzBackendFactory` whose backend was built with
/// `enableKVCacheReuse: true` — a reuse-disabled backend would also emit
/// zero `.kvCacheReuse` events and falsely confirm an "intact" gate.
public struct MLXVLMGateScenario: FuzzScenario {
    public let id = "mlx-vlm-gate"
    public let humanName = "MLX VLM gate currently disables KV-cache reuse"

    /// Optional factory that produces a `BackendHandle` for a VLM. When
    /// `nil`, ``run()`` short-circuits with a held invariant and a
    /// `failureReason` explaining the skip, so the scenario can sit in the
    /// default registry without forcing a real-MLX dependency on every
    /// caller.
    public let factory: (any FuzzBackendFactory)?

    public init(factory: (any FuzzBackendFactory)? = nil) {
        self.factory = factory
    }

    private var deterministicConfig: GenerationConfig {
        GenerationConfig(
            temperature: 0.0,
            topP: 1.0,
            repeatPenalty: 1.0,
            seed: 749,
            maxOutputTokens: 16,
            maxThinkingTokens: 0
        )
    }

    private static let firstUserPrompt = "Tell me about cats."
    private static let secondUserPrompt = "Now tell me about dogs."

    public func run() async throws -> ScenarioOutcome {
        guard let factory else {
            // Skip-only path. Invariant trivially holds because no run
            // happened — the scenario is informational at this layer.
            return ScenarioOutcome(
                scenarioId: id,
                invariantHeld: true,
                failureReason: "skipped: no FuzzBackendFactory supplied — see this type's doc comment; nothing in-repo wires one today",
                events: []
            )
        }

        let handle = try await factory.makeHandle()
        let backend = handle.backend

        var merged: [GenerationEvent] = []

        // Turn 1 — first user message. With the gate intact, no .kvCacheReuse
        // is expected on the first turn anyway because there's no prior cache.
        let turn1Stream = try backend.generate(
            prompt: Self.firstUserPrompt,
            systemPrompt: nil,
            config: deterministicConfig
        )
        var turn1Text = ""
        for try await event in turn1Stream.events {
            merged.append(event)
            if case .token(let chunk) = event {
                turn1Text += chunk
            }
        }

        // Fold the first turn into history before running turn 2 so the shared
        // prefix is what a real chat client would re-send. History rides
        // `hints.history` on the call stack (#2312); backends that ignore it
        // proceed without the explicit history wiring — `MLXBackend` is the
        // primary target here and consumes it.
        let turn2Hints = GenerationRuntimeHints(history: [
            StructuredMessage(role: "user", content: Self.firstUserPrompt),
            StructuredMessage(role: "assistant", content: turn1Text),
            StructuredMessage(role: "user", content: Self.secondUserPrompt),
        ])
        let turn2Stream = try backend.generate(
            prompt: Self.secondUserPrompt,
            systemPrompt: nil,
            config: deterministicConfig,
            hints: turn2Hints
        )
        for try await event in turn2Stream.events {
            merged.append(event)
        }

        let reuseEvents = merged.filter {
            if case .kvCacheReuse = $0 { return true }
            return false
        }

        // Today's invariant: the VLM gate is on, so we must not see any
        // .kvCacheReuse events across either turn. When the gate is removed,
        // this assertion will need to flip.
        if !reuseEvents.isEmpty {
            return ScenarioOutcome(
                scenarioId: id,
                invariantHeld: false,
                failureReason: "VLM gate appears removed: observed \(reuseEvents.count) .kvCacheReuse event(s) across two turns; flip this scenario's assertion",
                events: merged
            )
        }
        return ScenarioOutcome(scenarioId: id, invariantHeld: true, events: merged)
    }
}
