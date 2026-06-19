# Pre-1.0 API-cleanup train (post-adversarial review)

**Status:** proposed · **Base:** v0.50.0 (released 2026-06-13) · **Date:** 2026-06-14

> Revised after an adversarial review (refute-by-default) that killed half the original
> draft. The field is much smaller than it first looked. Verified facts below cite `Sources/`.

## Corrected premise

"No consumers, break freely" was **false as stated**: the sibling repos `manifold-mlx` and
`manifold-llama` are live consumers of `ManifoldInference`/`ManifoldContract`, and
manifold-mlx conforms both diffusion backends to `ImageGenerationBackend`
(`MLXDiffusionBackend.swift:60`, `FluxDiffusionBackend.swift:48`) and consumes
`ImageGenerationConfig`/`ImageGenerationEvent`. So any contract break that touches the media
or backend surface is a **coordinated two-repo migration**, the most expensive change shape
here — not free. (manifold-mlx is currently pinned `.upToNextMinor(from: "0.48.0")`, so it
hasn't even picked up current `main` yet — a pin bump is required *and* a source port.)

The shims P7 removes are **companion-safe but NOT consumer-safe.** The companions
(manifold-mlx/llama) do not import `ManifoldCloud`/`ManifoldBackends` (verified — only stale
test-fixture markdown references them). But a **consumer-integration review (2026-06-14)
confirmed at least one live app consumes `ManifoldBackends` + `CloudBackends` +
`FoundationBackends`** and is already watching for the drop. So P7 must ship a **migration
guide** and coordinate a **lockstep consumer update** — not a silent removal.

---

## Dead on arrival (cut from the train)

- **P2.5a `ToolResult.content` shape** — **already shipped (#1741).** `ToolResult` has
  `structuredContent: [ToolResultPart]?` with `.text(String)` + decode-tolerance
  (`ToolTypes.swift:194, :420, :450`). Nothing to do.
- **P2.5b `BackendName` extensibility** — already shipped (#1742); `BackendName` is the
  `RawRepresentable` struct (`BackendName.swift`).
- **P5 trait→product** — done by the v0.48 train; roster is only `Server`/`Macros` + 2 WWDC
  stubs (`Package.swift:123-130`). Tick the stale #1605 P5 checkbox and move on.

## Not a train (non-breaking — ship from the normal backlog anytime)

These have **zero** schema/wire/API-break impact, so grouping them into a "breaking train"
was pointless ceremony:

- **#1796 §A net-new perf** (`looksLikeLooping` tail-scan, `GenerationPreflightTrimmer`
  assemble-once, `PromptTemplate` `.joined()`) — re-verify vs `main` first.
- ~~**#1682 `transaction {}` atomicity**~~ — **WONTFIX (verified 2026-06-14).** Already
  implemented as stage→single-`save()`→manual-`rollback()` in `SwiftDataPersistenceProvider.swift:407-460`
  with an explicit defending comment, and covered by 10 tests in
  `SwiftDataTransactionalMutationTests.swift`. `transaction(block:)` does NOT discard staged
  `.update`s on throw (#1686), so the rewrite would regress atomicity. Do not re-litigate.

---

## The actual remaining pre-1.0 work

### A. Ship now — P7: retire `@_exported` shims (#1605) · `feat!` · companion-safe, breaks 1 consumer

The cleanest breaking cleanup, but it **does** break a live consumer (see corrected premise) —
ship a migration guide + lockstep update. Cut as its own minor (e.g. 0.51).
- Remove `ManifoldCloud` deprecated re-export shim — **relocate `DefaultWebSearchRuntime`
  first**. It imports `ManifoldInference` + `ManifoldRuntime` + `ManifoldCloudCore`, so
  `ManifoldCloudCore` is the only non-cycle home — confirm in the PR.
- Remove the `ManifoldBackends` umbrella (`Sources/ManifoldBackendsUmbrella/`); update
  `ManifoldKit`'s re-export set; point consumers at families directly.
- Remove deprecated `DefaultBackends` glue (~34 reference sites incl. docs/tests/`FeatureMatrix`).
- **Relocate `FoundationBackends`** (`Sources/ManifoldBackendsUmbrella/FoundationBackends.swift`)
  → `ManifoldFoundation` product.
- **Keep** the load-bearing `ChatSessionRecord`/`ChatMessageRecord` aliases (#1717).
- **Migration guide** (verified type mapping — add to `docs/MIGRATION-*.md`):
  | Removed (in `ManifoldBackends`) | Replace with | Module |
  |---|---|---|
  | `CloudBackends` | `OllamaBackends` **+** `CloudSaaSBackends` | `ManifoldOllama` + `ManifoldCloudSaaS` |
  | `FoundationBackends` | `FoundationBackends` (relocated) | `ManifoldFoundation` |
  | `DefaultBackends` | explicit registrar list to `quickStart(backends:)` | per-family |
  | `import ManifoldBackends` | import families directly (or `import ManifoldKit`) | — |
- **Lockstep:** update the known consumer in the same window; announce in release notes.
- **Gate:** full local + trait-combo sweep + readme-snippets (docc compiles) + allowlist entries.

### B. Decide before scheduling — three gating decisions, not code yet

1. **P4 media-generify — NO LONGER DEFERRED (audio designed 2026-06-14).** The 3rd modality
   is now concrete: **one-shot music + one-shot TTS**, both producing an audio *artifact* that
   fits the one-shot `MediaGeneration<Output>` seam (see `audio-generation-modality.md`). The
   realtime/duplex path was rejected, so the abstraction is safe. P4 may proceed: **P4a**
   (additive seam, with `AudioGeneration` a *real* typealias) lands non-breaking; **P4b/P4c**
   (collapse + delete clones) ship as a **lockstep ManifoldKit + manifold-mlx release** with an
   explicit companion-port step (the companions consume `ImageGenerationBackend`/`Config`/`Event`
   — a pin bump cannot repair the delete). P4b is the V10→V11 migration — the **8th** stage,
   not "migration #2" as the source plan says. *Risk-reducer:* the consumer-integration review
   (2026-06-14) confirmed pre-1.0 **clean-break SwiftData resets are accepted/expected** (the
   v0.20 rename already orphaned old stores by design), so even a non-lightweight P4b migration
   is tolerable — though a lightweight V10→V11 should still preserve data.

2. **`GenerationEvent` vocabulary freeze — SCOPED (2026-06-14).** Unblocked by P3b (#1795).
   **Stakes are lower than expected: `GenerationEvent` is runtime-only — NOT `Codable`, not
   persisted, not on-wire** (`GenerationEvent.swift`). So unlike `BackendName`/`MessagePart`,
   the *only* break surface is source-level exhaustive switches (30 sites / 78 files) — no
   stored data or wire format can break. 18 mature cases (text / tool-call / thinking / perf /
   handoff); companions only *consume* the stream, they don't emit custom cases. The
   `GenerationEventClosedAuditTest` tripwire already exists (`Tests/ManifoldRuntimeTests/`).

   **Decision: freeze as a CLOSED enum — no opaque `.custom` escape hatch.** Justified: it's
   runtime-only (no data risk), the vocabulary is complete and core-owned, and an escape case
   would burden all 30 switches for additions that are rare and can ride a major bump.

   **Pre-freeze breaking-while-free changes (one `feat!` PR, runtime-only → no migration):**
   - **`usage(prompt: Int, completion: Int)` → `usage(TokenUsage)` struct.** The one real
     wart: cache-token / reasoning-token accounting is a near-certain post-1.0 need, and a
     struct payload lets fields grow **non-breakingly** (the existing `ToolProgressEvent`
     precedent — a struct already living in `GenerationEvent.swift`). No `TokenUsage` struct
     exists today. **Highest-value item.**
   - **Consider `prefillProgress(...)` → struct** for the same reason (lower priority).
   - **Consumer hygiene:** add `@unknown default:` to cross-module/public-facing switches that
     should tolerate future additions (already used elsewhere in the repo); core-internal
     switches stay exhaustive and update in lockstep.
   - **Declare the whole-enum freeze** (today only the *tool-call* sub-vocabulary is marked
     locked in the doc header); update the doc + keep `GenerationEventClosedAuditTest` +
     sabotage entry as enforcement.
   - Companion impact: minimal — local backends (MLX/Llama) generally don't emit `usage`; any
     construction sites are a trivial source fix, folded into the P4 lockstep window.

3. **P6 `ChatSession`/`ChatMessage` public-name — SCOPED (2026-06-14): Option A, follow the
   `Agent`/`PersistedAgent` precedent.** The `Agent` collision is **already solved this way**:
   `Agent` = public value-type `struct` (`ManifoldContract/Agent.swift`); `PersistedAgent` =
   `typealias PersistedAgent = ManifoldSchemaV9.Agent` (the @Model), done explicitly "to avoid
   shadowing / F3 disambiguation." `ChatSession`/`ChatMessage` just never got the same
   treatment — they still carry the offending bare `public typealias ChatSession =
   ManifoldSchemaV9.ChatSession` (+ `ChatMessage`) in `Sources/ManifoldPersistenceSwiftData/
   Schema/ChatSession.swift|ChatMessage.swift`, which is the exact #1717 ambiguity under
   `import ManifoldKit`.

   **Decision: Option A (stable façade value types decoupled from schema).** Option B (public
   types track schema) is rejected — it contradicts the port/adapter architecture
   (`ManifoldRuntime` has zero SwiftData import; protocols traffic in the value-type structs)
   and would make *every* schema bump (already V10 / 7 stages, with P4b coming) a public
   breaking change — fatal for a 1.0 freeze. The `Agent` precedent already chose A.

   **Concrete change (one `feat!` PR, source-only — no migration):**
   - Rename the persistence bare typealiases → **`PersistedChatSession`/`PersistedChatMessage`**
     (matching `PersistedAgent`). Bare `ChatSession`/`ChatMessage` then unambiguously resolve
     to the public value-type structs (`ConversationRecords.swift`) — the frozen 1.0 vocab.
   - `@available(*, deprecated, renamed: "PersistedChatSession")` on the old bare persistence
     typealias to **start the deprecation clock** (the plan's "long pole"; also start
     `Agent`→`PersistedAgent`'s formal clock if not already).
   - **Keep** `ChatSessionRecord`/`ChatMessageRecord` (→ the structs) until Phase 7 — do NOT
     remove early (#1717, load-bearing).
   - **Window can be compressed:** the verified consumer set is tiny (one app + companions, all
     lockstep-updatable), so the ≥2-minor window is ceremony here — do the rename + lockstep
     update rather than gate 1.0 on a long clock.

---

## Recommended shape (all units now scoped)

Four `feat!` units + two backlog items. None blocks the others except where noted; sequence
by review bandwidth. There is **no 1.0 date** — this sequence is what earns one.

1. **P7 — retire shims (A).** Companion-safe but breaks the known consumer → ship migration
   guide + lockstep update. Self-contained. Good first 0.51 cut.
2. **`GenerationEvent` freeze (B2).** `usage(prompt:completion:)` → `usage(TokenUsage)` struct
   + `@unknown default` hygiene + whole-enum freeze declaration. Runtime-only, no migration.
3. **`ChatSession`/`ChatMessage` naming (B3).** Rename persistence typealiases →
   `Persisted*` (follow `PersistedAgent`), start deprecation clocks, keep `*Record` aliases to
   Phase 7. Source-only, no migration. Resolves #1717.
4. **P4 — media-generify (B1).** Audio = TTS (core) + music (consumer extension). Additive P4a
   lands non-breaking; P4b/P4c are a **lockstep ManifoldKit + manifold-mlx** release. The
   largest unit; can run last / on its own branch.
5. **#1796 §A perf, #1682 `transaction{}`** — non-breaking; normal backlog, anytime.

The headline pre-1.0 deliverables are the three vocabulary items (P7 surface, `GenerationEvent`
freeze, `ChatSession` naming) — they define the frozen 1.0 API. P4 is the big feature, not the
freeze.

## Remaining open decisions (small — all the big ones are resolved)

- [ ] `DefaultWebSearchRuntime` home — confirm `ManifoldCloudCore` (the only non-cycle option)
      at P7 PR time.
- [ ] P2.5a `ToolResult` — already shipped (#1741); confirm nothing further wanted.
- [ ] Pick a 1.0 date once these four units land (gates nothing now).

## Resolved this pass (2026-06-14)

P2/P3/P5 done · #1576/#1747 closed · #1823 audio decision (TTS+consumer-music) · #1415
boundary (3 lanes) · #1605 P5 ticked + P7 scheduled · `GenerationEvent` freeze scoped ·
`ChatSession` naming scoped (Option A) · consumer feedback folded into P7 + P4b.
