# Migration: cloud provider vocabulary struct-ified; 8 wire enums frozen (#2208)

**This is a breaking change** for exhaustive `switch` statements over
`CloudMessageEncoder` and `CloudPayloadHandler.Provider`. Everything else in
this sweep is additive (doc comments, a new audit test).

## Why

Pre-1.0 enum-growth audit: two public enums modelled a genuinely open-ended
provider vocabulary as a closed `enum`, and eight public sum-type enums that
already are the stable cross-module contract had no stated growth policy —
neither frozen (à la `GenerationEvent`) nor documented-growable (à la
`ToolResultPart`). Left alone, the first shape means every third-party/future
provider forces a source-breaking case addition, and the second means nobody
had actually decided what happens when one of these eight needs a new case —
a decision made under pressure during some future breaking-change review
instead of up front. Both are fixed here; see `docs/API-DESIGN.md` § 4b for
the standing policy this sweep establishes.

## What changed — struct-ified (breaking)

| Type | Before | After |
|------|--------|-------|
| `CloudPayloadHandler.Provider` | `enum: String` (`.openAI`, `.openAIResponses`, `.claude`, `.ollama`) | `RawRepresentable` struct, same four `public static let` constants |
| `CloudMessageEncoder` | `enum` (`.openAI`, `.openAIResponses`, `.claude`, `.ollama`) | `RawRepresentable` struct, same four `public static let` constants |

Both follow the `BackendName` (`Notification.Name` / `URLResourceKey`)
pattern already established in `ManifoldContract` — see `BackendName.swift`
for the full rationale.

### What keeps working unchanged

- Every existing `== .openAI` / `== .claude` / `== .ollama` /
  `== .openAIResponses` equality comparison — no source change needed.
- Every existing static-member call site (`CloudMessageEncoder.claude.encodeMessages(...)`,
  `CloudPayloadHandler(provider: .ollama, wrapping: ...)`, etc.) — no source
  change needed.
- Wire/persistence shape — neither type round-trips on the wire, so there is
  no encode/decode compatibility concern.

### What needs a one-line fix

An **exhaustive `switch` statement over `CloudMessageEncoder` or
`CloudPayloadHandler.Provider`** no longer compiles — the struct's absence of
a closed case set means the compiler can't prove exhaustiveness. Add a
`default:` arm. Six such switches existed inside `CloudMessageEncoder.swift`
itself; they were converted in this PR to this shape:

```swift
// Before
switch self {
case .openAI, .openAIResponses:
    return tools.map { OpenAIToolEncoding.encodeToolDefinition($0, strict: strict) }
case .claude:
    return tools.map { Self.claudeEncodeToolDefinition($0, strict: strict) }
case .ollama:
    return tools.map(Self.ollamaEncodeToolDefinition)
}

// After
switch self {
case .claude:
    return tools.map { Self.claudeEncodeToolDefinition($0, strict: strict) }
case .ollama:
    return tools.map(Self.ollamaEncodeToolDefinition)
default: // .openAI, .openAIResponses, and any unknown provider
    return tools.map { OpenAIToolEncoding.encodeToolDefinition($0, strict: strict) }
}
```

**Unknown-provider default:** every converted switch's `default:` arm routes
an unrecognised provider through the OpenAI Chat-Completions-compatible path.
This mirrors existing behaviour — `CloudSaaSBackends` already routes
`.custom` / `.lmStudio` endpoints through `OpenAIBackend`, which always
constructs `CloudMessageEncoder.openAI` — so an unrecognised provider degrades
to the most broadly compatible wire shape rather than failing outright.

## What changed — documented and frozen (non-breaking)

`MessagePart`, `Message`, `ToolChoice`, `ToolExecutionEvent`,
`InferenceError`, `ChatError.Kind`, `ChatError.Recovery`, and
`WebSearchRuntimeError` each gained a "Vocabulary freeze (1.0)" doc-comment
block (same wording pattern as `GenerationEvent`'s pre-existing one). Their
shape is unchanged — this is a documentation-only change to these eight
types themselves.

Case additions to a documented-non-exhaustive enum are still source-breaking
for exhaustive `switch` statements, so they land only in a major (`feat!:`)
release — same as `GenerationEvent` today. Cross-module consumer switches
over these eight that were exhaustive with no `default:`/`@unknown default:`
gained one in this PR (7 call sites across `ManifoldInference`,
`ManifoldCloudCore`, `ManifoldCloudSaaS`, `ManifoldFuzz`, and `ManifoldUI` —
see the PR diff for the full list, including `ChatError.Recovery`'s
`recoveryButton(for:)` in `ChatShellViews.swift`, which previously dropped a
button silently on an unhandled case rather than erroring).

If your own code has an exhaustive `switch` over any of these eight types,
add an `@unknown default:` arm now — it costs nothing today and avoids a
compile break the next time ManifoldKit adds a case to one of them.

## New: `PublicEnumFreezeAuditTest`

A new audit test (`Tests/ManifoldInferenceTests/PublicEnumFreezeAuditTest.swift`)
fails CI if a `public enum` in `Sources/` has neither a "Vocabulary freeze" /
"Vocabulary growth" doc-comment marker nor an entry in
`Tests/ManifoldInferenceTests/public_enum_freeze_allowlist.txt`. The
allowlist was seeded with every pre-existing public enum this PR did not
individually assess — it is an "unassessed" bucket, not a clearance list. A
future PR touching one of those enums should add the marker and remove the
allowlist line rather than leaving both.

## Not in scope

`ToolResultPart` already carries its own "Vocabulary growth (1.x)" doc-comment
block and an `.unknown(type:)` decode-tolerance case — it is deliberately
open-vocabulary, not frozen, and was left unchanged by this sweep.
