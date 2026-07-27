# Migration — `ModelManifest.contextWindow` is now `Int?`

**Audience:** consumer
**Status:** living
**Applies to:** v0.75.0 and later (companion-backend authors: you are a *consumer* here — see "Consumers" and the named sites under "Companion packages")

## The compiler diagnostics you'll hit

```
error: value of optional type 'Int?' must be unwrapped to a value of type 'Int'
error: cannot convert value of type 'Int?' to expected argument type 'Int'
```

…on any expression that reads `manifest.contextWindow`.

## What changed

`ModelManifest.contextWindow` changed from `Int` to `Int?`. `nil` means **the
backend could not determine the model's context window**.

Correspondingly, `ModelManifest.unknown(modelIdentifier:producerKind:)` no
longer fabricates a `contextWindow` of `8192`; it leaves the field `nil`.

## Why

The old shape had no way to say "unknown". `.unknown(...)` returned `8192` —
a plausible number, documented as deliberately underselling — so a fabricated
value was byte-for-byte indistinguishable from a measured one. Two consequences,
both live in the codebase before this change:

1. **Consumers could not detect absence.** Nothing downstream could distinguish
   "we measured 8k" from "we have no idea", so no consumer could react to the
   difference even in principle. (Precisely: `ContextWindowManager` and
   `PromptAssembler` read `BackendCapabilities.contextWindowSize`, not the
   manifest — so what changes is that each *backend* now decides what an
   unknown model's budget should be, and can be reviewed on that choice,
   instead of silently inheriting one target's constant.)
2. **Callers reverse-engineered the sentinel.** `ClaudeBackend` recovered
   "unknown" by comparing against the literal from another module:

   ```swift
   // before — reached across a module boundary into another target's constant
   let resolvedContext = Int32(resolvedManifest.contextWindow == 8192
       ? 200_000
       : resolvedManifest.contextWindow)
   ```

   Nothing linked the two. Moving the constant would have silently shrunk every
   unknown Claude model to 8k; adding a table entry with a genuine 8,192-token
   window (OpenAI's `gpt-4` has exactly that) would have silently claimed 200k.

This is a recurring defect class rather than a one-off — `ffb3fe67`
("fix(inference): detect MLX context length from config.json, not hardcoded
8192") fixed the same literal elsewhere days earlier. Making absence
representable on the type is what stops it recurring: the compiler now forces
every consumer to say what it wants to happen when the window is unknown.

## How to migrate

### Producers — usually no change

The initializer takes `Int?`, and Swift promotes a non-optional `Int`
implicitly, so a backend that measured a real value compiles unchanged:

```swift
ModelManifest(contextWindow: 131_072, /* … */)   // still fine
```

The one change to make is on the *failure* path. If you were substituting a
plausible number when introspection failed, stop — pass `nil`:

```swift
// before
let window = probe.contextLength ?? 8192
// after — absence is now sayable
let window = probe.contextLength
```

### Consumers — name your own fallback

Choose the default that is right for *your* provider, at the call site where
that knowledge lives:

```swift
// Anthropic backend
let context = manifest.contextWindow ?? 200_000

// OpenAI backend
let context = manifest.contextWindow ?? 128_000

// Nested optional: `backend.manifest?.contextWindow` is now `Int??`.
// Use flatMap so "manifest present, window unknown" flattens correctly.
let context = backend.manifest.flatMap(\.contextWindow) ?? 128_000
```

If your consumer can do something better than guess — surface the uncertainty,
skip a trim, ask the user — that option now exists for the first time.

### Persisted manifests

`ModelManifest` is `Codable`, and the synthesised coding for an optional uses
`decodeIfPresent`. Nothing in ManifoldKit itself persists a `ModelManifest`
(there is no SwiftData model and no on-disk cache for it), so this affects
consumer-side persistence only. A payload written before v0.75 that carries
`"contextWindow": 8192` decodes as `.some(8192)` — i.e. an old *unknown*
manifest read off disk still looks like a known 8k model. Re-probe rather than
trusting a persisted manifest across the upgrade if that distinction matters to
you.

## What changes at runtime

Two behaviours are deliberately held constant, but they are easy to break while
adapting, so they are written down:

- **Anthropic** — an unrecognised Claude model still resolves to a 200k budget.
  Previously that came from the `== 8192` comparison; now from `?? 200_000`.
- **OpenAI / LM Studio / custom OpenAI-compatible** — an unrecognised model
  still resolves to a **conservative 8,192** budget
  (`OpenAIBackend.unknownModelContextWindow`), *not* the 128k the capability
  factory nominally defaults to. That 128k branch was structurally unreachable
  before (a table miss produced `unknown()`'s fabricated 8192), and allowing it
  to fire would have raised an unrecognised model's budget 16× — a real
  regression for local endpoints, where unrecognised names are the norm.
- **Ollama** — a `/api/show` response with no `context_length` now leaves the
  manifest's window `nil`; `capabilities` supplies the `num_ctx` the backend
  will actually run with. The resolved number is unchanged.

If you maintain a backend, this is the decision to make consciously: what budget
should *your* provider assume for a model it cannot identify? Prefer
underselling — a short prompt is recoverable, an overflow is not.

## Companion packages

Known sites needing adaptation (compile errors, not silent misbehaviour):

- `manifold-mlx` — `Sources/ManifoldMLX/MLXBackend.swift:66`
  (`Int32(_manifest?.contextWindow ?? 8192)`, now `Int??`) and `:734`
  (`if let trainedMax = _manifest?.contextWindow` binds `Int?`). Use
  `flatMap(\.contextWindow)`.
- `manifold-mlx` — `Sources/ManifoldMLX/MLXModelProbe.swift:330` still
  fabricates `8192` when `max_position_embeddings` is absent. It compiles
  unchanged, so the build will *not* catch it; pass the optional through
  instead. Doing so makes the `contextWindowWasDetected` /
  `_trainedContextWasDetected` side-channel redundant — it exists only because
  the manifest previously could not say "unknown".
- `manifold-llama` — `Sources/manifold-tools-llama/Benchmark.swift:93`
  (`backend.manifest?.contextWindow` is now `Int??` against a declared `Int?`).
- `manifold-eval` — no references; no change required.

## Related

- `docs/API-DESIGN.md` — layer ownership and the pre-1.0 breaking-change policy.
- Principle 6 (*errors are visible*): a fabricated default is a silent failure
  wearing a plausible number.
