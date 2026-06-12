# Why ManifoldKit — and how it's built to last

> AI made writing the code easy. It made *keeping the project alive* hard.
> This doc is the honest version of what ManifoldKit is, what it solves, and —
> because the hard part is everything that happens after the demo — how it's
> built so it survives past week 10. Every claim points at the source or test
> that backs it. Where ManifoldKit doesn't do something, it says so.

---

## The hard part was never the model

You can wrap an LLM in an afternoon. That's not where AI apps die. They die in the
weeks after the demo — in the parts every iOS developer building with AI keeps
running into:

- **Integration is "nightmarish."** Wiring OpenAI or Anthropic into a real app
  means certificates, keys, secrets, provisioning, latency rules, retries,
  cancellation — before you've shown a single token.
- **SwiftData migrations break users on update.** Evolve a schema casually and the
  next release wipes or corrupts existing users' data. It's the single most-cited
  gotcha in shipping AI apps.
- **On-device models fight the hardware.** Memory pressure, thermal throttling,
  cache eviction, model swaps mid-load — the systems work around the model is most
  of the work.
- **AI-assisted codebases rot.** Without strict boundaries, typed seams, and tests
  that actually fail when something breaks, an agent quietly fills your project
  with duplicate patterns and silent regressions. It looks great in week 1 and
  collapses in week 10.

ManifoldKit exists because all of that is real, recurring, and *the same for
everyone*. It's the assembled product — UI, the turn loop, persistence, and every
backend behind one import — but the reason to trust it is the part underneath:
it's built like the maintenance matters, and that work is open for you to read,
run, and copy.

---

## Built to survive: the receipts

These are the practices that keep ManifoldKit from rotting — and the ones you can
lift into your own project. Most are unusual; a few we haven't seen anywhere else.

### Tests that try to break the product

- **A fuzzer that drives real chat traffic.** `ManifoldFuzz` (`scripts/fuzz.sh`)
  pushes generated conversations through every backend looking for divergence. It
  caught a real Ollama `thinking`-token drop on its first smoke run. It's not "we
  have tests" — it's a robot whose job is to break the backends and file the bugs.
- **Audit tests that read the source as data.** A test walks `Sources/` and bans an
  entire class of regression: a stray `try?` swallowing an error, a `URLSession(`
  outside the one file allowed to construct one, a UI layer importing a backend.
  Nineteen of these stand guard so a bad pattern can't quietly creep back in.
- **A suite that checks the guards still guard.** This is the unusual one. Audit
  tests are grep heuristics with allowlists — they can rot into no-ops without
  anyone noticing. So there's a *sabotage suite* whose only job is to verify each
  audit still catches what it claims: it writes a known violation into a temp
  directory and asserts the tripwire fires. Who watches the watchers — in CI.
- **Tests that prove they can fail.** Every assertion is paired, during
  development, with a deliberate break to confirm the test goes red — then the
  break is removed before commit. A test that can't fail is theater.

### Built so a fresh consumer — or an AI agent — can actually work in it

- **Cold-start gates run from outside the repo.** Three scripts scaffold a brand-new
  SwiftPM consumer in a temp directory and exercise ManifoldKit's public API as a
  stranger would. They catch the "compiles in-tree, broken from outside" failures
  every internal test misses — a forgotten `internal`, a missing export, a broken
  link shape.
- **Strict, enforced module boundaries.** A layered graph of 28 library products (plus two companion backend packages) with
  dependency rules the build *enforces* — UI can't import a backend, cross-family
  protocols can't drift out of place. The boundaries an AI agent needs to
  contribute without creating debt aren't a guideline here; they're a failing test
  if you cross them.
- **The agent's rules can't go stale.** `CLAUDE.md` and `AGENTS.md` carry the
  project's conventions for any AI tool working in the repo — and an audit fails CI
  if the two ever drift apart. The "essential rules" file other developers
  copy-paste into every session is, here, kept honest by the build.

### Data that doesn't break on update

- **Versioned schemas with tested migrations.** SwiftData gets a bad rap for exactly
  the day-one migration footgun above. ManifoldKit answers it the way you're
  supposed to: explicit versioned schema models, an explicit migration plan, and a
  migration *fixture test* that loads an old store and proves it upgrades cleanly.
  You get SwiftData's ergonomics without the update-day surprise.

### Whatever Apple ships next is one more backend, not a rewrite

Foundation Models is one model, on one OS, gated to recent hardware. Apps wired
directly to it face a migration the day Apple ships the next thing. ManifoldKit
wraps it as *one backend behind the same protocol as everything else* — so when
the platform moves, absorbing it is a new backend behind a stable interface, not a
teardown. The trait stubs for the next framework are already in `Package.swift`.

---

## What you actually get

Because the foundation holds, the product on top is small to adopt. The whole
app is a single `try await ManifoldKit.quickStart()` call that builds the
SwiftData container, registers the compiled-in backends, and returns a wired
chat view model. The copy-paste-ready, compile-tested Hello World lives in one
canonical place — [`docs/QUICKSTART.md` → Hello World](QUICKSTART.md#hello-world)
(mirrored in the [README](../README.md#hello-world)) — so there is exactly one
form to keep correct. From there:

![One GenerationStream protocol fans out to MLX, llama.cpp, Apple Foundation Models, OpenAI, Anthropic, Ollama, LAN, and the AnyLanguageModel bridge](images/product/generationstream-backends-fan.svg)

- **One protocol, every backend.** MLX, llama.cpp/GGUF, Apple Foundation Models,
  OpenAI, Anthropic, Ollama, LAN — plus Gemini / xAI / Groq / Mistral through the
  AnyLanguageModel bridge. Streaming, tool calling, structured output, and thinking
  tokens work the same across all of them because they live above the protocol.
- **The whole turn loop, owned.** `ConversationRuntime` is the single path for
  send / regenerate / edit / cancel / branch. No second path to keep consistent.
- **Already in the box:** streaming, MCP (client *and* server), RAG with citations,
  tool-approval gating, metrics + cost, and on-device image generation.

See [`docs/QUICKSTART.md`](QUICKSTART.md) to go deeper, and
[`POSITIONING.md`](POSITIONING.md) for the full category and comparison.

---

## What ManifoldKit does *not* do

Credibility is the point, so the boundaries are explicit:

- **It doesn't make your model faster.** ManifoldKit owns the resource and lifecycle
  layer — memory admission, KV-cache policy, model handoff, memory-pressure unload —
  so an optimized model doesn't OOM or thermal-stall the app. It does *not* do
  Core ML / Neural Engine kernel optimization. That surgery is still yours.
- **It doesn't do your App Store distribution or ASO.** It helps you build the kind
  of app that retains — reliability, privacy, polish — not the listing that ranks.
- **It doesn't sync via CloudKit.** Persistence is local SwiftData.
- **It's pre-1.0.** Expect breaking changes between minor versions until the public
  surface settles. [`POSITIONING.md` §10](POSITIONING.md) keeps a standing list of
  what isn't done and what isn't guaranteed.

---

## Where to look

| You want to see… | Start here |
|---|---|
| The QA practices above, in full | [`docs/QA-PRACTICES.md`](QA-PRACTICES.md) |
| Architecture rules the build enforces | [`CONTRIBUTING.md`](../CONTRIBUTING.md) · [`CLAUDE.md`](../CLAUDE.md) |
| The reliability contract (source-backed) | [`docs/RELIABILITY.md`](RELIABILITY.md) |
| The threat model | [`docs/THREAT_MODEL.md`](THREAT_MODEL.md) |
| A 30-minute first chat app | [`docs/QUICKSTART.md`](QUICKSTART.md) · [`Example/`](../Example) |
