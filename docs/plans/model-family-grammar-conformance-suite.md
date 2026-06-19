# Spec: Model-Family Grammar Conformance Suite

**Status:** proposed
**Lives in:** `roryford/manifold-llama` — `Tests/ManifoldLlamaTests/Conformance/LlamaGrammarConformanceTests.swift`
**Tier:** E2E / integration, hardware-gated (Apple Silicon + physical device + real GGUF on disk), opt-in discovery.
**Motivation:** Today grammar *behavior* across model families is verified by exactly one happy-path Llama test (`LlamaGrammarSamplerTests.test_grammar_constrainsOutput`, grammar `root ::= [0-9]+`). The trivial digit grammar is precisely the case the Gemma carve-out says *still works*; the real failure modes (JSON-object stall, alternation, tokenizer/leading-space accuracy, tool-call envelopes) are unguarded on every family. This suite makes grammar conformance a per-family, per-grammar-shape matrix.

---

## 1. Design

### 1.1 Parametrization over families

Drive the suite from a static family table. Each entry resolves a GGUF on disk by name fragment via the existing `HardwareRequirements.findGGUFModel(nameContains:)` (honors `LLAMA_TEST_MODEL` and `MANIFOLD_DISCOVER_LOCAL_MODELS=1`). Families with no model on disk **skip**, never fail.

```swift
struct GrammarFamily {
    let id: String                 // "llama", "qwen", "mistral", "gemma", "phi"
    let nameFragment: String       // passed to findGGUFModel(nameContains:)
    let expectsGrammarSupport: Bool // false for gemma (capability gated off)
    let toolCallDialect: ToolCallMarker.Dialect  // qwen-json / hermes / gemma4 / generic
}
```

Default roster (extend as models land in `~/Documents/Models/`):

| id | fragment | grammar support | tool dialect | notes |
|----|----------|-----------------|--------------|-------|
| llama   | `llama`   | yes | hermes/generic | reference family |
| qwen    | `qwen`    | yes | qwen-json | thinking-capable (Qwen3) — exercises phase gate |
| mistral | `mistral` | yes | generic | no current grammar test at all |
| gemma   | `gemma`   | **no** | gemma4 | capability gated off — asserts the carve-out is *correct*, not just present |
| phi     | `phi`     | yes | generic | optional |

A per-family run is skipped (not failed) when `findGGUFModel(nameContains: fragment)` returns nil. Discovery requires `MANIFOLD_DISCOVER_LOCAL_MODELS=1` or an explicit `LLAMA_TEST_MODEL` path, matching existing tests — so routine `swift test` runs skip the whole suite cleanly.

### 1.2 Grammar case battery (run per supporting family)

| case | grammar shape | assertion | catches |
|------|---------------|-----------|---------|
| **C1 smoke** | `root ::= [0-9]+` | output all digits | sampler wiring (already covered for llama; now all families) |
| **C2 json-object** | object grammar: `root ::= "{" ws "\"city\"" ws ":" ws string ... "}"` | output parses as JSON **and** has required keys | the Gemma stall class — open `{`, whitespace-loop to EOG |
| **C3 alternation** | `root ::= "yes" | "no"` | output ∈ {yes,no} | GBNF `|` alternation actually constrains (the construct the dead pre-validator wrongly calls inexpressible) |
| **C4 leading-space** | C3 grammar built two ways: with and without a leading optional ` `-permitting prefix | both variants stay valid; record agreement/divergence of the *chosen* branch | tokenizer boundary sensitivity ([Lost in Space], Llama-3.1 leading-space effect) |
| **C5 tool-envelope** | grammar constraining to the family's `<tool_call>{json}</tool_call>` envelope | `ToolCallTransform`/marker parser extracts a `ToolCall` with the expected name | grammar + tool-calling end to end — the actual product use case (#1859) |

C4 is the one behavioral (not pass/fail-only) case: it asserts both grammar variants produce *schema-valid* output, and **logs** whether the model picked the same branch with vs. without the leading-space allowance. Divergence is recorded as a known-characteristic, not a failure (it's model-intrinsic) — but a *crash* or *invalid output* under either variant fails.

### 1.3 Gemma (and any `expectsGrammarSupport == false` family)

Do **not** push grammars through it. Instead assert the carve-out holds end-to-end:
- `backend.capabilities.supportsGrammarConstrainedSampling == false` after load (real load, not `injectArchitectureForTesting`).
- A `GenerationConfig.grammar`-bearing request is routed to JSON-mode/prompt fallback by the caller layer — i.e. the backend does not silently apply a broken grammar. (If the contract says it should throw when a grammar is passed to a non-supporting backend, assert the throw — mirroring the MLX fix in manifold-mlx#13.)

This converts the Gemma comment's rationale ("truncates under structured GBNF") into a guarded invariant: if a future llama.cpp bump makes Gemma grammar-safe, C2-against-Gemma can be promoted and the carve-out removed deliberately.

### 1.4 Thinking-capable families (Qwen3)

For families flagged thinking-capable, run C2/C3 **with thinking enabled** and assert:
- reasoning tokens appear as `.thinkingToken` (unconstrained — `GrammarPhaseGate` permissive during `<think>`),
- post-`</think>` output satisfies the grammar (gate flipped strict on `.thinkingCompleted`).

This is the first behavioral test of the #1595 two-chain gate against a real thinking model rather than the unit-level `GrammarPhaseGateTests`.

---

## 2. Conventions to match

- `XCTestCase`, async/await, no `withKnownIssue`.
- File-level `setUp`: `XCTSkipUnless(HardwareRequirements.isPhysicalDevice)` + `isAppleSilicon`, exactly as `LlamaGrammarSamplerTests`.
- Per-family model resolve via `findGGUFModel(nameContains:)`; `throw XCTSkip` with the standard "No GGUF on disk…" message when nil.
- Determinism: `temperature: 0.1`, fixed `seed`, small `maxOutputTokens` (≤ 64), `effectiveContextSize: 512` (`.testStub`) to stay inside the simulator/CI context cap.
- `addTeardownBlock { await backend.unloadAndWait() }` per loaded backend.
- Each `@Test`/`func` carries a **sabotage check** comment naming the exact source edit that should break it (per repo convention — remove before commit is *not* required here since these are doc comments, matching `LlamaGrammarSamplerTests`).
- Do **not** run under `--parallel` if it touches the capability-claims registry (per `ManifoldBackendTestKit` DocC note) — keep single-process.

---

## 3. Helper: grammar fixtures

Add a small `GrammarFixtures` enum in the test target (not core) holding the five grammar strings + a JSON validator for C2 (reuse core `JSONSchemaValidator` for the key-presence assertion). Keep grammars as literals next to the cases for readability — no schema→GBNF generation (none exists; callers hand-author GBNF, which is the point of testing the literals directly).

---

## 4. What this does NOT cover (explicit non-goals)

- **Schema→GBNF conversion** — there is no emitter in any repo; out of scope until #1859 adds one. When it lands, add a golden-file suite that snapshots emitted GBNF and feeds it through C1–C5.
- **MLX** — has no grammar path; covered by the contract-violation fix (manifold-mlx#13), not here.
- **Cloud backends** — grammar unsupported by contract; covered by `SSECloudBackend` throw tests in core.

---

## 5. Rollout

1. Land the suite skipping-empty (no models in CI → all skip), so it's merged and discoverable.
2. Document in `manifold-llama` README which model fragments to drop in `~/Documents/Models/` to light it up, and the `MANIFOLD_DISCOVER_LOCAL_MODELS=1` switch.
3. Run locally against whatever families the user has on disk (Qwen + Llama at minimum per their env) and record the C4 divergence characteristics per family as a baseline comment.
4. Optional: a `weekly`-cadence CI lane (like fuzz) that runs it against a cached small GGUF per family — only if the local signal proves worth the minutes.

[Lost in Space]: https://arxiv.org/pdf/2502.14969
