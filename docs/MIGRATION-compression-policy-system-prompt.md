# Migration: `systemPrompt` on `CompressionPolicy` / `PreTurnCompressionPolicy` (#1957, #2288)

**Audience:** consumer (anyone implementing a custom compression policy)
**Status:** living

**Applies to:** custom conformers of `CompressionPolicy` or
`PreTurnCompressionPolicy` that budget history compression against a token
count.

## Why

`TurnCompressionCoordinator` budgeted compression against
`ChatSession.systemPrompt` only. The turn loop puts a different, and usually
larger, prompt on the wire — `TurnConfig.systemPrompt`, the active agent's
system prompt plus handoff instructions (multi-agent), and post-turn the fully
composed prompt including prompt slots / RAG context. A policy sizing its
compression budget off `ChatSession.systemPrompt` alone under-counted that
gap and could under-compress, letting the actual wire prompt overflow the
context window.

Both protocol methods now receive the turn's real wire system prompt directly,
so a policy's token accounting matches what the backend will actually see —
pre-turn gets the base prompt (before prompt-slot/RAG composition, since
those aren't assembled yet at that seam); post-turn gets the fully composed
prompt.

## What changed

| Protocol | Before | After |
|---|---|---|
| `CompressionPolicy.compress` | `compress(history:sessionID:generate:)` | `compress(history:sessionID:systemPrompt:generate:)` |
| `PreTurnCompressionPolicy.compressBeforeTurn` | `compressBeforeTurn(history:sessionID:generate:)` | `compressBeforeTurn(history:sessionID:systemPrompt:generate:)` |

`systemPrompt: String?` is the turn's wire system prompt — not
`ChatSession.systemPrompt`. Hosts that stored the prompt only on the session
must also put it on `TurnConfig.systemPrompt` (as `ChatViewModel` does via
`effectiveSystemPrompt()`) for it to reach a custom policy.

## Migrating a custom policy

**Before:**

```swift
struct MyPolicy: CompressionPolicy {
    func compress(
        history: [ChatMessage],
        sessionID: UUID,
        generate: @Sendable ([ChatMessage]) async throws -> String
    ) async throws -> [ChatMessage] {
        let budget = estimateTokens(history) // no system-prompt accounting
        ...
    }
}
```

**After:**

```swift
struct MyPolicy: CompressionPolicy {
    func compress(
        history: [ChatMessage],
        sessionID: UUID,
        systemPrompt: String?,
        generate: @Sendable ([ChatMessage]) async throws -> String
    ) async throws -> [ChatMessage] {
        let budget = estimateTokens(history) + estimateTokens(systemPrompt ?? "")
        ...
    }
}
```

**`reservedTokens` double-count note:** if your policy previously folded an
*estimated* system-prompt cost into a `reservedTokens`-style constant to
compensate for the missing parameter, remove that padding now that the real
`systemPrompt` is passed — keeping both double-counts and over-compresses.

## Built-in conformers

`DefaultCompressionPolicy`, `ContextWindowPreTurnCompressionPolicy`, and
`FixedCountPreTurnCompressionPolicy` (ManifoldAppEval) are already updated;
no action needed if you only use those.
