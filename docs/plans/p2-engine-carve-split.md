# P2 Engine Carve — sub-phase split (post persona review)

Parent: #1605. Plan: `docs/plans/target-architecture-migration.md` §Phase 2.
Gates satisfied: P0a decision + P0c harness (#1607). Persona plan review: done (concurrency,
module-graph, test/behavior-preservation lenses).

## Path decision: extract the Contract *downward*, not the engine *upward*

The review measured both directions against the real import graph:

| Direction | Mechanism | Lockstep edits | Risk |
|---|---|---|---|
| Evict engine UP (`InferenceService`+cluster → `ManifoldEngine`) | move engine out of kernel | **246 files / 35 modules**, 44 hard (conformances/extensions), +~60 DocC | catastrophic |
| Seam-first (`BackendRegistering` protocol) | decouple before move | removes only ~4 of ~200 touchpoints | no help |
| **Extract Contract DOWN (new leaf `ManifoldContract`)** | kernel `@_exported import`s it | **~30 files move, 0 consumer import-edits**, ~4 Package lines | low |

Why down wins: the inference engine (`InferenceService` → owns `GenerationQueue` → `ToolRegistry`
→ dispatch → streaming) is welded to the kernel by `BackendRegistrar.register(with: InferenceService)`
plus concrete use from `ManifoldMCP` (`MCPToolExecutor: ToolExecutor`, `ToolRegistry`) and
`ManifoldLlama`/`ManifoldMLX` (`extension InferenceService` / `extension ImageGenerationService`).
Moving it up forces 246 lockstep imports and is cycle-prone. Moving the **Contract** down is the
pattern already shipped 4× in this repo (P1 #1608/#1611: `ManifoldHardware`, `ManifoldModelCatalog`,
`ManifoldNetworking`, `ManifoldSecrets`), is cycle-legal (`@_exported` shim points down), and needs
zero consumer source edits. Same end-state dependency shape, ~1/8th the churn.

End state: `ManifoldContract` (leaf, thin kernel) ← backends ; `ManifoldInference` (the engine,
keeps its name, never moves, `@_exported import ManifoldContract`) ; `ManifoldRuntime` (turn loop,
stays put).

## Naming decision (resolved): keep `ManifoldInference`
No rename to `ManifoldEngine`. The heavy module keeps `InferenceService`+queue and stays
`ManifoldInference`; "Inference" is metaphor-neutral and the name is liked. **Consequence:** there
is no `ManifoldEngine` module to create and nothing to fold — the target doc's "ManifoldEngine =
Runtime + evicted orchestration" motion is dropped. The clean 3-layer shape (Contract ← Inference ←
Runtime) is delivered by the downward Contract extraction alone. This removes the MED-risk
rename/rehome/CI-lockstep phase entirely.

## The split (separate issues, parent #1605 → P2)

The original P2 conflated two things the review shows are independent. Decoupled into three:

- **[#1719] P2a — Extract `ManifoldContract` leaf (delivers the thin Contract kernel).** ~30 protocol/
  event/config/stream/message files move down; `@_exported import ManifoldContract` shim in
  `ManifoldInference`; repoint `ManifoldFoundation`+`ManifoldCloud` deps to Contract-only; leave
  MLX/Llama/MCP on `ManifoldInference` (real engine use); `BackendRegistrar` stays with the engine.
  Closure-taint check per file. New target has zero deps (tripwire test). Behavior-neutral. **Risk: LOW.**
- **[#1720] P2b — Grow the P0c harness (test-only, prereq for P2c).** Extend `EventTraceCanonicalizer`
  to emit `agentID`/`sessionID`/`promptTokens`/`completionTokens` (today dropped → handoff/usage
  bugs diff clean). Add `test_handoff_midStream` + `test_tokenUsage` goldens. **Risk: LOW.**
  Parallel-able with P2a (disjoint files; serialize pushes).
- **[#1721] P2c — De-tangle `ConversationTurnExecutor` (the real refactor, inside `ManifoldRuntime`).**
  1,740 L → thin per-turn executor; lift `eventSink` emissions + persistence writes behind narrow
  ports; make the tool-dispatch seam explicit. No module move. INVARIANTS: `sessionRecord` stays a
  function-local re-pinned var, never re-fetched mid-stream (the headline race trap); #965; #1606;
  KV discipline; `@Sendable` sinks don't capture `@MainActor` state. Diff clean vs the grown goldens.
  Persona-review the diff. **Risk: HIGH.** Depends on P2b.

Sequencing: (P2a ∥ P2b) → P2c. P2a/P2b are parallel-safe (disjoint files, serialize the push);
P2c is sequential after P2b (needs the grown goldens) and rewrites the turn-loop files. The
migration's "fewer, larger units" exception applies; cap in-flight PRs.
