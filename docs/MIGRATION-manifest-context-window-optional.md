# Migration — `ModelManifest.contextWindow` is now `Int?`

**Audience:** consumer
**Status:** living
**Applies to:** v0.75.0 and later (companion-backend authors: see "Producers" below)

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

1. **Consumers could not detect absence.** `ContextWindowManager` trimmed, and
   compression thresholds fired, against a number that described no real model.
   The user saw truncation with no error.
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
`decodeIfPresent`. A payload written before v0.75 that carries
`"contextWindow": 8192` decodes as `.some(8192)` — i.e. an old *unknown*
manifest read off disk still looks like a known 8k model. Re-probe rather than
trusting a persisted manifest across the upgrade if that distinction matters to
you.

## Related

- `docs/API-DESIGN.md` — layer ownership and the pre-1.0 breaking-change policy.
- Principle 6 (*errors are visible*): a fabricated default is a silent failure
  wearing a plausible number.
