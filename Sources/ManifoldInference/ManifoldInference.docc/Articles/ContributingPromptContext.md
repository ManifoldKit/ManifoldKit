# Contributing Prompt Context

Inject retrieved documents, lore, or other budget-aware text into the assembled prompt without touching history or persistence.

## Overview

``PromptContextProvider`` is the seam for content that competes for a slice of
the context window on every turn: retrieved passages, character/world
definitions, system-setup text, anything that is *assembled into the prompt*
rather than *stored as a message*. It is an assembly-tier concern — the
provider protocol, the budget types, and the sort semantics all live here in
`ManifoldInference`. The layer above (`ManifoldRuntime`) only composes
providers into a pipeline and wires the result into ``ConversationRuntime``;
it does not change what a slot means or how it sorts.

If what you actually want is to inject or reshape *past messages* rather than
inject prompt content, this is the wrong seam — see
`ManifoldRuntime`'s "Contributing Conversation History" article for the
message-level equivalent and a decision table between the two.

## The provider contract

A conformer returns zero or more ``PromptSlot`` values for the upcoming turn:

```swift,no-build
import ManifoldInference

struct LoreProvider: PromptContextProvider {
    func contributeSlots(messageCount: Int) async throws -> [PromptSlot] {
        [
            PromptSlot(
                id: "lore.tavern",
                content: "The Rusty Anchor is a tavern on the harbor district's east pier.",
                position: .contextSetup,
                role: .userInstruction,
                label: "Tavern lore"
            )
        ]
    }
}
```

``PromptContextProvider/contributeSlots(messageCount:)`` is the minimum
conformance — it only receives the conversation's message count, which is
enough to compute ``PromptSlotPosition/atDepth(_:)`` sort indices. Providers
that need to vary their output by remaining token budget (truncate a
retrieval list, drop low-priority lore when the window is tight) override the
budget-aware overload instead:

```swift,no-build
func contributeSlots(
    budget: ProviderBudget,
    context: TurnContext
) async throws -> [PromptSlot] {
    let affordablePassages = retrievedPassages.prefix(while: { runningTokenEstimate($0) < budget.allocated })
    return affordablePassages.map { passage in
        PromptSlot(id: passage.id, content: passage.text, role: .retrieval, label: passage.title)
    }
}
```

The default implementation of the budget-aware overload forwards to
``contributeSlots(messageCount:)`` and ignores the budget, so existing
message-count-only conformers keep compiling unchanged — only override the
budget-aware form when the provider's output actually depends on budget.

A throwing provider aborts assembly for that turn; ``ManifoldRuntime``'s
``PromptContextPipeline`` and ``ContextBudgetPlanner`` both propagate the
error rather than silently dropping the provider's contribution. Surfaces
that need partial-failure semantics ("show what we have, log the rest")
compose that behavior at the use-case layer, above this protocol.

## `ProviderBudget` and `TurnContext`

``ProviderBudget`` carries the token allowance a provider was given for this
turn (`allocated`) and the full backend context window
(`totalContextSize`, `0` when unknown). `allocated` is advisory: a provider
may return less than its allocation (unused tokens roll to the next provider
when the caller is ``ContextBudgetPlanner``), but should not return
meaningfully more — doing so wastes the overflow on low-priority content
that a higher-priority provider could have used.

``TurnContext`` is the read side: `sessionID`, `messageCount`,
`conversationText` (lowercased, whitespace-joined history text for
keyword/semantic matching — `nil` on the first turn or in tests that don't
need it), an optional `tokenizer` for cost estimation, and `appData` — an
opaque host-supplied payload the host seeds via ``ConversationRuntime``'s
`turnContextProvider` closure (see the "Per-turn host data —
`turnContextProvider` and `TurnContext.appData`" section of
`ManifoldRuntime`'s "Contributing Conversation History" article). A provider reads `appData` when it
needs per-turn host state (feature flags, a request ID, an active persona)
that isn't derivable from the conversation itself.

## Slot position, role, and ordering

``PromptSlot`` declares *where* it lands (``PromptSlotPosition``) and *what
kind* of content it is (``PromptSlotRole``):

- `.systemPreamble` and `.contextSetup` place a slot before conversation
  history; `.topOfHistory` / `.atDepth(n)` / `.bottomOfHistory` interleave it
  with history at a computed depth; `.inline` appends it after all messages,
  immediately before the model's turn.
- `role` (`.system`, `.characterContext`, `.retrieval`, `.archival`,
  `.userInstruction`, `.conversationHistory`, or `.custom(_:)`) drives
  per-role priority and caps when a ``BudgetPolicy`` trims content that
  doesn't fit — see ``BudgetPolicy/defaultPriorities`` for the shipped order.

When multiple providers are composed, their slots are merged and sorted by
``PromptSlotPosition/sortIndex(messageCount:)``. Slots that land at the same
sort index keep the order their providers were registered in — this
tie-break is a caller-visible contract, not an accident of sort stability;
don't build logic that depends on the *opposite* order.

## Where assembly happens

`ManifoldInference` defines the contract; it does not compose providers or
own the pipeline that turns `[PromptSlot]` plus trimmed history into an
``AssembledPrompt`` — that is ``PromptAssembler``, also in this module, and
the multi-provider composition (``ContextBudgetPlanner``,
`PromptContextPipeline`) lives one layer up in `ManifoldRuntime`, wired into
``ConversationRuntime`` via its `pipeline:` / `budgetPlanner:` initializer
parameters. See `ManifoldRuntime`'s "Contributing Conversation History"
article for that wiring and for the sibling history-contribution seam.

## Topics

### Provider protocol

- ``PromptContextProvider``

### Budget and turn context

- ``ProviderBudget``
- ``TurnContext``

### Slots

- ``PromptSlot``
- ``PromptSlotPosition``
- ``PromptSlotRole``
- ``BudgetPolicy``
- ``ResolvedSlot``
- ``AssembledPrompt``
