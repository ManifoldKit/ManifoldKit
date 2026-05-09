import Foundation
import ManifoldInference

/// Drives a backend through two prefix-sharing turns and records whether any
/// `.kvCacheReuse(promptTokensReused:)` events appear, intended primarily for
/// MLX VLMs where reuse is gated off today.
///
/// The audit's ground-truth claim is "VLM sessions pay full prompt-prefill on
/// every turn because `MLXBackend` ANDs `enableKVCacheReuse` with
/// `!routeThroughVLMFactory`." This scenario captures the empirical evidence
/// for that claim against a real MLX VLM via ``MLXFuzzFactory`` and stores it
/// in ``ScenarioOutcome/events`` so a follow-up summary script can compare
/// pre- and post-gate-removal runs.
///
/// **When the gate is removed in a future PR**, the scenario starts seeing
/// `.kvCacheReuse(promptTokensReused: > 0)` on the second turn and the
/// invariant in ``run()`` will need to flip from "must be empty" to "must
/// fire on turn 2". Until then a held invariant means the gate is intact.
///
/// The scenario is skip-only when no factory is supplied, which is how the
/// default registry registration works — `ManifoldFuzz` cannot import
/// `MLXFuzzFactory` directly because `ManifoldFuzz` has no MLX dependency.
/// The fuzz CLI and the Xcode-hosted MLX harness construct the scenario
/// explicitly with a real factory when it's their turn to run.
///
/// **For the gate-detection invariant to be meaningful**, the supplied
/// factory must produce an MLX backend constructed with
/// `enableKVCacheReuse: true`. A reuse-disabled backend would also emit zero
/// `.kvCacheReuse` events and would falsely confirm an "intact" gate. The
/// canonical wiring lives next to `MLXFuzzFactory` in `ManifoldFuzzBackends`.
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
                failureReason: "skipped: no FuzzBackendFactory supplied (wire MLXFuzzFactory to record VLM-gate events)",
                events: []
            )
        }

        let handle = try await factory.makeHandle()
        let backend = handle.backend
        let receiver = backend as? ConversationHistoryReceiver

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

        // Fold the first turn into history before running turn 2 so the
        // shared prefix is what a real chat client would re-send. Backends
        // without `ConversationHistoryReceiver` proceed without the explicit
        // history wiring — `MLXBackend` is the primary target here and does
        // conform.
        receiver?.setConversationHistory([
            ("user", Self.firstUserPrompt),
            ("assistant", turn1Text),
            ("user", Self.secondUserPrompt),
        ])

        let turn2Stream = try backend.generate(
            prompt: Self.secondUserPrompt,
            systemPrompt: nil,
            config: deterministicConfig
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
