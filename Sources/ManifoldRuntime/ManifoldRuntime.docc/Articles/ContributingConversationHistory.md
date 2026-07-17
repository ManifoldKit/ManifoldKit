# Contributing Conversation History

Insert or shape the message-level history a turn sees, and thread per-turn host data through to the providers that need it.

## Overview

``HistoryProvider`` is the seam for content that behaves like a *message* —
something that should read back as part of the conversation transcript, in
its own turn slot, at a specific point in history — rather than content
assembled into the surrounding prompt. It is a turn-semantics concern that
belongs to this module, `ManifoldRuntime`, because a history insertion
requires session and turn context that `ManifoldInference` (the assembly
tier) deliberately does not have. `ManifoldInference`'s
"Contributing Prompt Context" article covers the sibling prompt-slot seam
— read that first if you haven't already; this article assumes its
vocabulary (``PromptContextProvider``, ``PromptSlot``, ``TurnContext``).

## Which seam do I want?

| You want to… | Use |
|---|---|
| Inject retrieved documents, world/lore text, or other content into the assembled prompt under a token budget | ``PromptContextProvider`` (`ManifoldInference`) |
| Insert or reshape *messages* in the history array the model sees this turn | ``HistoryProvider`` (this module) |
| Make host-app state (a feature flag, an active persona, a request ID) available to providers on both seams | The `turnContextProvider` closure on ``ConversationRuntime``'s initializer, read back as `TurnContext.appData` — see below |
| React to every persisted write, regardless of whether it happened during a generation turn | `MessageStorePostWriteHook` / `SessionStorePostWriteHook` — see the note at the end of this article |

A history insertion is not expressible as a prompt slot, and the two seams
are not merged: `HistoryProvider` produces real ``ChatMessage``-shaped
content with message-array insertion semantics (`atDepth`, `beforeRecord`,
`head`, `tail`); `PromptContextProvider` produces prompt-only text with
budget accounting and position sorting. Reach for whichever tier owns the
concern you're extending rather than bending one seam to do the other's job.

## Implementing a `HistoryProvider`

A conformer receives the current prompt-visible history and turn context,
and returns zero or more ``HistoryContribution`` values:

```swift,no-build
import ManifoldInference
import ManifoldRuntime

struct RecapProvider: HistoryProvider {
    func contribute(
        history: [ChatMessage],
        context: TurnContext
    ) async throws -> [HistoryContribution] {
        guard context.messageCount > 40 else { return [] }
        let recap = ChatMessage(
            sessionID: context.sessionID,
            role: .system,
            content: [.text("Recap: the party has reached the harbor district.")]
        )
        return [HistoryContribution(record: recap, position: .atDepth(20))]
    }
}
```

``HistoryInsertionPosition`` mirrors ``PromptSlotPosition/atDepth(_:)`` for
the `atDepth` case (`atDepth(0)` = the tail) and adds record-relative
positions — `.beforeRecord(_:)` / `.afterRecord(_:)`, silently dropped if the
referenced ID isn't present — plus `.head` and `.tail` for the array
endpoints.

Providers must not reorder existing `.chat`-kind records; they may only
inject new ones at the declared position. `ConversationRuntime` enforces a
chronological-order invariant in debug builds, so an insertion that violates
it fails loudly during development rather than silently corrupting the
transcript.

## Ordering and failure semantics

Multiple `HistoryProvider`s run in registration order, each seeing the
history as augmented by every provider before it — provider *N* observes
provider *N-1*'s insertions, not just the canonical fetched history. This is
the opposite of `PromptContextProvider`'s fan-out-then-merge model
(see `ManifoldInference`'s "Contributing Prompt Context" article), because history insertions are
positional relative to each other and concurrent evaluation would make that
position ambiguous.

A throwing provider aborts the current turn with
``ConversationError/persistence(_:)``. There is no partial-contribution mode
here, same as the prompt-slot seam: a surface that wants "best effort, log
the rest" composes that behavior itself around the provider.

`IdentityHistoryProvider` is the shipped no-op — returns `[]` unconditionally
— used as a test fixture and as the implicit default when no providers are
registered.

## Wiring providers into `ConversationRuntime`

Register providers through ``ConversationRuntime``'s initializer:

```swift,no-build
import ManifoldRuntime

let runtime = ConversationRuntime(
    messageStore: myMessageStore,
    inferenceService: myInferenceService,
    historyShaper: nil,
    historyProviders: [RecapProvider()]
)
```

`historyProviders` run after an optional `historyShaper` (a host-owned
transform of the *canonical* history — see that type's own documentation)
and before prompt-context slot assembly and RAG, so later stages see the
augmented history, not just the shaper's output.

## Per-turn host data — `turnContextProvider` and `TurnContext.appData`

Host-app state (a feature flag, an active persona, a request ID) that
providers on both seams need reaches them through `appData`. Pass a
`turnContextProvider` closure to ``ConversationRuntime``'s initializer —
it receives the session ID and returns any `Sendable` payload:

```swift,no-build
import ManifoldRuntime

let runtime = ConversationRuntime(
    messageStore: myMessageStore,
    inferenceService: myInferenceService,
    turnContextProvider: { sessionID in
        personaStore.activePersonaSync(for: sessionID)
    }
)
```

The returned value flows through to every `HistoryProvider` and
`PromptContextProvider` as `context.appData` (see ``ContextBudgetPlanner``,
which reads it off ``TurnContext`` for budget-aware providers), and to
`GenerationHook`'s `postGeneration(_:)` via `CompletedTurn.appData` — one
payload, read anywhere a provider or hook needs host state without a
side-channel registry. This `turnContextProvider` closure is the supported
public seam for per-turn host data (a richer async/throwing alternative
existed pre-1.0 but had zero adopters and was retired from the public
contract; see `docs/MIGRATION-api-demotions-0.71.md`). Hosts that need
throwing/async per-turn data resolution should compute it ahead of the turn
and capture it in the closure, or store it centrally and read it inside a
``HistoryProvider``/``PromptContextProvider`` conformance.

## Store post-write hooks are a different seam

`MessageStorePostWriteHook` and `SessionStorePostWriteHook` (registered via
`MessageStore.addPostWriteHook(_:)` / the `SessionStore` equivalent) look
similar but answer a different question: they fire after *any* store write
commits, whether or not that write happened inside a generation turn — a
manual import, a background sync, a debug tool all trigger them the same
way a turn's message insert does. They are a persistence-tier seam, live
outside the generation lifecycle, cannot see `TurnContext` or `appData`, and
must not throw (errors are logged and swallowed; a failing hook cannot roll
back the write). Use a `HistoryProvider` or the `turnContextProvider`/
`appData` handoff for anything that needs to reason about a specific turn;
reach for a store post-write hook only for unconditional per-write side
effects like audit logging or search indexing.

## Topics

### History contribution

- ``HistoryProvider``
- ``HistoryContribution``
- ``HistoryInsertionPosition``
- ``IdentityHistoryProvider``

### Host-owned per-turn context

- ``TurnContextBuildRequest``
