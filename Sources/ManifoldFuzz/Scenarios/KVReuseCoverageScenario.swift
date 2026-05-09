import Foundation
import ManifoldInference

/// Drives a known-reuse backend through the five chat shapes most likely to
/// hide a silent KV-reuse regression and asserts the invariant "every
/// post-first turn that re-uses a prefix emits exactly one `.kvCacheReuse`
/// event, with a non-decreasing token count across rounds".
///
/// The five paths come straight from the perf-audit α-1 plan:
///
/// 1. **chat-2-turns** — baseline shape. Turn 2's prompt is turn 1's prompt
///    plus a follow-up. Reuse must fire.
/// 2. **regenerate** — the user re-runs the same prompt. Same prefix → reuse.
/// 3. **edit-last-user** — the user edits the most recent message; the new
///    prompt diverges late. The shared head must still reuse.
/// 4. **tool-loop-3-rounds** — three tool-call rounds, each backend turn
///    extending the prior turn's prompt. Reuse must fire on every round
///    after the first.
/// 5. **system-prompt-change** — system prompt swaps between turns; reuse
///    must NOT fire (or must report zero) because the prefix moved.
///
/// The scenario runs all five paths against `ScenarioTestBackend` (the same
/// fuzz-side fake `ThinkingAcrossRetryScenario` uses), with
/// `kvCacheReuseToYieldPerTurn` configured per path. The invariant is
/// expressed against the recorded event timeline so the same scenario plugs
/// into the harness's CSV/JSON sink without further wiring — `EventRecorder`
/// already records `.kvCacheReuse` as `kind: "kvCacheReuse"`.
///
/// What this scenario does NOT do: it does not load a real model. The
/// scenarios that exercise real backends live in
/// `Tests/ManifoldBackendsTests/LlamaKVReuseTests.swift` (Llama) and
/// `Tests/ManifoldMLXIntegrationTests/MLXKVReuseIntegrationTests.swift`
/// (MLX, work unit α-2). This scenario provides the harness-shape that those
/// integration tests can be replayed against once they emit JSON records.
public struct KVReuseCoverageScenario: FuzzScenario {
    public let id = "kv-reuse-coverage"
    public let humanName = "KV reuse fires on every reuse-eligible turn across the five canonical chat paths"

    public init() {}

    public func run() async throws -> ScenarioOutcome {
        var allEvents: [GenerationEvent] = []
        var failures: [String] = []

        // 1. chat-2-turns: turn 2 reuses turn 1's prefix.
        do {
            let pathEvents = try await runMultiTurnReuse(
                pathName: "chat-2-turns",
                turnPrompts: ["Hello, how are you?", "Hello, how are you? That is great."],
                kvReusePerTurn: [0, 12]
            )
            assertReuseAtIndex(events: pathEvents, turnIndex: 1, path: "chat-2-turns", failures: &failures)
            allEvents.append(contentsOf: pathEvents)
        }

        // 2. regenerate: identical prompt re-issued; reuse should fire on
        // turn 2 because the entire prompt re-tokenises identically.
        do {
            let pathEvents = try await runMultiTurnReuse(
                pathName: "regenerate",
                turnPrompts: ["Tell me about Swift.", "Tell me about Swift."],
                kvReusePerTurn: [0, 9]
            )
            assertReuseAtIndex(events: pathEvents, turnIndex: 1, path: "regenerate", failures: &failures)
            allEvents.append(contentsOf: pathEvents)
        }

        // 3. edit-last-user: shared prefix, late divergence. Real backends
        // reuse the shared head and re-decode only the diverging tail.
        do {
            let pathEvents = try await runMultiTurnReuse(
                pathName: "edit-last-user",
                turnPrompts: [
                    "The weather today is sunny.",
                    "The weather today is rainy."
                ],
                kvReusePerTurn: [0, 5]
            )
            assertReuseAtIndex(events: pathEvents, turnIndex: 1, path: "edit-last-user", failures: &failures)
            allEvents.append(contentsOf: pathEvents)
        }

        // 4. tool-loop-3-rounds: every round's prompt extends the prior
        // round's. Reuse must fire on rounds 2 and 3, and the per-round
        // count must be non-decreasing.
        do {
            let pathEvents = try await runMultiTurnReuse(
                pathName: "tool-loop-3-rounds",
                turnPrompts: [
                    "ask",
                    "ask + tool result 1",
                    "ask + tool result 1 + tool result 2"
                ],
                kvReusePerTurn: [0, 3, 7]
            )
            assertReuseAtIndex(events: pathEvents, turnIndex: 1, path: "tool-loop-3-rounds", failures: &failures)
            assertReuseAtIndex(events: pathEvents, turnIndex: 2, path: "tool-loop-3-rounds", failures: &failures)
            assertMonotonicReuse(events: pathEvents, path: "tool-loop-3-rounds", failures: &failures)
            allEvents.append(contentsOf: pathEvents)
        }

        // 5. system-prompt-change: prefix moved → no reuse, or reuse reports
        // zero. Anything else flags a regression.
        do {
            let pathEvents = try await runMultiTurnReuse(
                pathName: "system-prompt-change",
                turnPrompts: ["[sys=A] hello", "[sys=B] hello"],
                kvReusePerTurn: [0, 0]
            )
            // Acceptable shapes: turn 2 has no `.kvCacheReuse`, or has one
            // with value 0. Anything else fails.
            let turn2Events = pathEvents.dropFirst(eventsForTurnIndex(in: pathEvents, turnIndex: 1))
            for event in turn2Events {
                if case .kvCacheReuse(let n) = event, n > 0 {
                    failures.append("system-prompt-change emitted .kvCacheReuse(\(n)) — system change must not preserve KV state")
                    break
                }
            }
            allEvents.append(contentsOf: pathEvents)
        }

        if !failures.isEmpty {
            return ScenarioOutcome(
                scenarioId: id,
                invariantHeld: false,
                failureReason: failures.joined(separator: "; "),
                events: allEvents
            )
        }
        return ScenarioOutcome(scenarioId: id, invariantHeld: true, events: allEvents)
    }

    // MARK: - Path runner

    /// Runs N turns against a single backend, configuring per-turn reuse
    /// counts before the first call. Returns the merged event timeline so
    /// the caller can assert path-specific invariants.
    private func runMultiTurnReuse(
        pathName: String,
        turnPrompts: [String],
        kvReusePerTurn: [Int]
    ) async throws -> [GenerationEvent] {
        precondition(turnPrompts.count == kvReusePerTurn.count,
                     "turnPrompts and kvReusePerTurn must align per round")

        let backend = ScenarioTestBackend(
            tokensToYield: ["ok", "."],
            thinkingTokensToYield: [],
            emitThinkingComplete: false
        )
        // Per-turn counts. The backend yields the value verbatim — including
        // `0` — to mirror MLX, which emits `.kvCacheReuse(0)` after a cache
        // miss on the snapshot path. Llama omits the event entirely on
        // misses; this scenario takes the more permissive shape so future
        // backends that emit the explicit-zero event still pass.
        backend.kvCacheReuseToYieldPerTurn = kvReusePerTurn

        try await backend.loadModel(from: URL(string: "mem://kv-reuse/\(pathName)")!, plan: .cloud())

        var merged: [GenerationEvent] = []
        for prompt in turnPrompts {
            let stream = try backend.generate(prompt: prompt, systemPrompt: nil, config: GenerationConfig())
            for try await event in stream.events {
                merged.append(event)
            }
        }
        return merged
    }

    // MARK: - Invariant helpers

    /// Asserts the turn at `turnIndex` (0-based) emitted at least one
    /// `.kvCacheReuse` event with a positive count.
    private func assertReuseAtIndex(
        events: [GenerationEvent],
        turnIndex: Int,
        path: String,
        failures: inout [String]
    ) {
        let turnEvents = eventsForTurn(in: events, turnIndex: turnIndex)
        let reuseValues = turnEvents.compactMap { event -> Int? in
            if case .kvCacheReuse(let n) = event { return n } else { return nil }
        }
        guard let first = reuseValues.first else {
            failures.append("\(path): turn \(turnIndex) emitted no .kvCacheReuse event — KV prefix not reused")
            return
        }
        if first <= 0 {
            failures.append("\(path): turn \(turnIndex) emitted .kvCacheReuse(\(first)) — reuse must report a positive count")
        }
    }

    /// Asserts every turn's reuse count is greater than or equal to the
    /// previous turn's. A real backend that reused 5 tokens then 3 tokens has
    /// thrown away the prefix between rounds — that's the regression we care
    /// about.
    private func assertMonotonicReuse(
        events: [GenerationEvent],
        path: String,
        failures: inout [String]
    ) {
        let reuseValues = events.compactMap { event -> Int? in
            if case .kvCacheReuse(let n) = event { return n } else { return nil }
        }
        for i in 1..<reuseValues.count {
            if reuseValues[i] < reuseValues[i - 1] {
                failures.append("\(path): reuse dropped between rounds: \(reuseValues)")
                return
            }
        }
    }

    /// Returns the event slice for the turn at `turnIndex` (0-based). Each
    /// path the scenario runs emits exactly one `.kvCacheReuse` per turn (the
    /// first thing the backend yields), so partitioning the merged timeline
    /// on `.kvCacheReuse` boundaries gives one slice per turn.
    private func eventsForTurn(in events: [GenerationEvent], turnIndex: Int) -> [GenerationEvent] {
        var turns: [[GenerationEvent]] = []
        var current: [GenerationEvent] = []
        for event in events {
            if case .kvCacheReuse = event {
                if !current.isEmpty {
                    turns.append(current)
                }
                current = [event]
            } else {
                current.append(event)
            }
        }
        if !current.isEmpty {
            turns.append(current)
        }
        return turnIndex < turns.count ? turns[turnIndex] : []
    }

    /// Index into `events` at which turn `turnIndex` starts (0-based). Used by
    /// the system-prompt-change branch to scan only the second turn's events.
    private func eventsForTurnIndex(in events: [GenerationEvent], turnIndex: Int) -> Int {
        var seenTurns = 0
        for (offset, event) in events.enumerated() {
            if case .kvCacheReuse = event {
                if seenTurns == turnIndex {
                    return offset
                }
                seenTurns += 1
            }
        }
        return events.count
    }
}
