# Anatomy of one turn

**Audience:** contributor
**Status:** living

This document traces one message turn end to end: a user calls
`ChatViewModel.sendMessage(_:)`, and some milliseconds-to-seconds later a
persisted assistant `ChatMessage` exists and the UI has observed it. Every
other doc in this repo teaches a recipe (`QUICKSTART*.md`, `RECIPES.md`) or a
layer-ownership boundary (`API-DESIGN.md`); this one is the opposite angle —
one linear walk through the real call stack, with a source anchor at every
hop, so a reader can find their way into any part of the pipeline from a
single starting point. It complements
[`ObservingATurn.md`](../Sources/ManifoldRuntime/ManifoldRuntime.docc/Articles/ObservingATurn.md),
which covers how to *observe* a turn's event stream without racing the
primary consumer — this document is about what produces those events and why
the pipeline is shaped the way it is.

Anchors below name a symbol and its file so they survive line-shuffling
refactors; add `:N` only where the number is load-bearing for the point being
made. If a symbol has moved, `grep` for its name — the shape of the pipeline
is far more stable than any specific line number.

## Vocabulary

| Symbol | What it is |
| --- | --- |
| `TurnInput` | The value `ConversationRuntime.processTurn` accepts — a `TurnKind` (`.send` / `.regenerate` / `.edit` / `.branch`) plus session id and `TurnConfig`. |
| `TurnKind` | Which of the four turn shapes this is. `SingleTurnDriver` switches on it once and never again. |
| `ConversationStreamHandle` | An opaque token identifying one in-flight generation stream, returned by `processTurn` and passed back into `cancel(_:)`. |
| `PromptSlot` | One named block of system-prompt content (persona instructions, RAG context, tool guidance) contributed by a `HistoryProvider`/`PromptContextProvider` and folded into the composed system prompt. |
| `StructuredMessage` | The wire-shaped message (`role` + `[MessagePart]`) that actually crosses to a backend — distinct from the persisted `ChatMessage` and the cloud-wire payload types (see AGENTS.md's message-types table). |
| `GenerationEvent` | The engine-layer event vocabulary (`ManifoldInference`): tokens, thinking, tool calls, completion. |
| `ConversationEvent` | The runtime-layer event vocabulary (`ManifoldRuntime`), a superset: everything `GenerationEvent` has, plus persistence identity (`messageInserted`/`messageRemoved`), history shaping, compression, and multi-agent handoff. |

## The two phases of a turn

Every turn has a bounded, synchronous-ish **assembly phase** and then an
open-ended, cancellable **streaming phase**. They have different failure
modes and different cost profiles, and most bugs live at the boundary
between them (a slot that assembly computed but streaming never uses; a
cancellation that arrives mid-assembly and is checked too late).

**Assembly** builds the system prompt, gathers RAG/tool/agent context, and
constructs the `[StructuredMessage]` history that will cross the wire. It
touches the persistence store (for prior history and session state) but not
the network. It can fail (a `PromptContextProvider` throwing, a RAG retrieval
error) and those failures are reported as `ConversationError` before any
token is requested.

**Streaming** is the `enqueue` call and everything after: the backend request,
the token/thinking/tool-call event flow, and the terminal write-back. It is
long-running, is the only phase a `ConversationStreamHandle` can meaningfully
cancel mid-flight, and its failure modes (network drop, tool loop, stall
timeout, repetition) are different in kind from assembly failures.

The rest of this document walks both phases in call order.

## 1. Entry: `ChatViewModel.sendMessage`

The consumer-facing entry point is
[`ChatViewModel.sendMessage(_:)`](../Sources/ManifoldUI/ViewModels/ChatViewModel+Messages.swift)
— the throwing, `ChatMessage`-returning overload used by scripted drivers and
integration tests. It checks two preconditions before touching the runtime
at all: an active session (`SendMessageError.noActiveSession`) and a loaded
model, distinguishing "nothing selected" (`.noModelLoaded`) from "a load is
already in flight" (`.modelLoading`) so a caller doesn't mistake a
self-resolving state for a hard failure. Once preconditions pass it sets
`inputText` and calls the observable-property overload, `sendMessage()`,
which is what the drop-in `ChatView` actually binds its send button to.

That inner `sendMessage()` is thin: it hands a `TurnInput` to
`ConversationRuntime.processTurn` (or `processTurnWithOutcome`, see below) and
lets the `ChatGenerationCoordinator` wiring (§10) drive `lastTurnState` from
there. The outer, throwing `sendMessage(_:)` polls `lastTurnState` after the
await returns and re-shapes whatever it finds into `SendMessageError` —
`.completed` becomes a return value, `.failed` is rethrown, and an
unexpected `.idle`/`.generating` result falls back to `activeError` or a bare
`.empty`.

## 2. `ConversationRuntime.processTurn`

[`ConversationRuntime`](../Sources/ManifoldRuntime/Services/ConversationRuntime.swift)
is the single turn loop AGENTS.md's Part 0 principle 8 refers to: send,
regenerate, edit, cancel, and branch all funnel through this one type, and
every host (app, server, MCP host) forwards into it rather than
reimplementing turn semantics.

`processTurn(_:)` is a thin public wrapper over a private overload that also
accepts an optional `ConversationTurnOutcomeCompletion` — the mechanism
`processTurnWithOutcome(_:)` uses to hand back a `ConversationTurnHandle`
whose `.outcome` resolves exactly once regardless of how many other
consumers are draining (or not draining) the shared `events` stream. Both
paths do the same one thing: delegate to `turnDriver.executeTurn(...)`. The
runtime itself holds no `TurnKind` switch — that logic lives one layer down,
in whichever `TurnDriver` is wired in.

`cancel(_:)` is the other half of this seam: it marks the handle cancelled in
the runtime's registry, cancels the associated task in the runtime-owned task
registry, and — if a generation token was already registered — calls
`inferenceService.cancelAsync(token)` to propagate the cancellation into the
engine. See §8 for where this is checked from inside the streaming loop.

## 3. `SingleTurnDriver.executeTurn`

[`SingleTurnDriver`](../Sources/ManifoldRuntime/Services/SingleTurnDriver.swift)
is the default `TurnDriver` conformer, and it really is as thin as its doc
comment claims: `executeTurn` switches on `input.kind` and calls exactly one
of `executor.runSendFlow` / `runRegenerateFlow` / `runEditFlow` /
`runBranchFlow`, forwarding the session id, turn config, and task registry
unchanged. No logic lives here — it's the seam that lets `ResumableRunDriver`
(checkpointed multi-step runs, P3b) exist as an alternative conformer without
touching `ConversationTurnExecutor`. For an ordinary chat send, this hop
adds nothing but a case label; the real work starts in the executor.

## 4. Send flow: `ConversationTurnExecutor.runSendFlow`

[`ConversationTurnExecutor.runSendFlow`](../Sources/ManifoldRuntime/Services/ConversationTurnExecutor.swift)
does five things in order, and the order is deliberate:

1. Rejects oversized text against `ManifoldConfiguration.shared.maxUserMessageBytes`
   before any SwiftData work — cheap rejection beats an OOM during UTF-8
   encoding on a constrained device.
  2. Runs `compression.compressBeforeTurnIfNeeded(sessionID:wireSystemPrompt:)`
     — pre-turn compression, so a just-submitted message always falls outside
     whatever gets summarized. Budgets against the turn's base wire system
     prompt (`TurnConfig` / active agent), not merely `ChatSession.systemPrompt`
     (#1957). Only runs for `.send`, never for regenerate/edit/branch.
3. Builds the user `ChatMessage` (splicing text and attachment parts so the
   persisted record and the wire-visible structured history stay in sync)
   and persists it synchronously via `persistence.insertMessage(_:)`, then
   emits `.messageInserted(userMessage)`.
4. Best-effort touches the session's `updatedAt` for sidebar ordering —
   failures here are logged, not thrown; losing a turn over a sidebar
   timestamp would be the wrong trade.
5. Calls `launchGenerationTask(...)`, which spins up the actual streaming
   work on the runtime-owned task registry and returns the handle.

Step 3's ordering is a documented guarantee: a caller sees
`.messageInserted(user)` before `processTurn` returns, because the streaming
task is launched — not awaited to completion — after persistence commits.
`runRegenerateFlow` (fetch history, delete the trailing assistant message,
emit `.messageRemoved`, then the same `launchGenerationTask` call),
`runEditFlow`, and `runBranchFlow` are siblings in the same file with
analogous shapes; `runSendFlow` is the one worth reading first because the
other three are variations on the same launch step.

## 5. Context assembly: `runGenerationTurn`, part one

`launchGenerationTask` hands off to
[`runGenerationTurn`](../Sources/ManifoldRuntime/Services/ConversationTurnExecutor.swift),
the long private method that is the actual body of a turn. Its first half is
pure assembly — no network yet.

It builds a `PromptContextRequest` and unconditionally emits
`.beforeContextAssembly` / `.contextAssembled` (even when no providers are
registered and slots come back empty) — event-ordering stability across
turns matters more than skipping a no-op emission, since adapters pin
against the pair. Slot assembly itself goes through one of two paths: a
`ContextBudgetPlanner` (proportional weight-split allocation across
providers with spillover) if one is wired, otherwise
[`PromptContextPipeline.assemble(totalBudget:contextSize:context:)`](../Sources/ManifoldRuntime/Services/PromptContextPipeline.swift).
Either failure is wrapped as `ConversationError.contextAssembly` and ends the
turn right there — no partial slot set continues into generation.

If a `RAGService` is wired and the turn has user text, `ragService.retrieve(query:)`
runs next, appending its slots to the system prompt and separately capturing
structured `RetrievedDocument`s for the embedded-Jinja `documents` block (a
grounding template consumes these directly; templates without a `documents`
block still see the same content via the system-prompt slots). RAG failures
are logged and swallowed — a broken retriever degrades a turn's grounding,
it does not fail the turn.

The method then reads a `ChatSession` snapshot once per turn (multi-agent
`activeAgentID`, sibling agents for handoff detection) and snapshots the
host-mutable tool-source/hook-registry bindings — deliberately once, so a
`ConversationRuntime.updateSessionToolSources(_:)` call racing a long-running
turn takes effect on the *next* turn rather than reconfiguring one already in
flight. It (re)installs a handoff detector closure and a pre-tool-use hook
adapter on `InferenceService` for this turn — the runtime owns the
`HookRegistry` (Runtime can import Inference, not the reverse), so the
adapter translates registry state into the closure shape the engine's
dispatch loop expects, sanitizing and emitting `.hookFired` on every call.

The composed system prompt is: the active agent's `systemPrompt` (with a
handoff-instructions preamble if the agent has siblings) — or `config.systemPrompt`
for the single-agent case — with the assembled `slots` appended. The prior
`[ChatMessage]` history is filtered to wire-visible records and mapped into
`[StructuredMessage]`, with a synthetic (never persisted) system-role
boundary message spliced in when the last assistant turn was authored by a
different agent than the one about to respond — so the receiving agent sees
an explicit handover marker instead of unexplained context.

## 6. Dispatch to the engine

Assembly ends and streaming begins at the call to
`inferenceService.enqueueAsync(...)` (declared in
[`InferenceService+Nonisolated.swift`](../Sources/ManifoldInference/Services/InferenceService+Nonisolated.swift)),
which forwards sampler parameters, the structured history, the composed
system prompt, and the advertised tool definitions to the queue-based
`enqueue` entry point on
[`GenerationQueue`](../Sources/ManifoldInference/Services/GenerationQueue.swift).
Note the parameter-shape gap called out in the executor's own comment:
`enqueueAsync` takes sampler knobs as individual parameters, so only
temperature/topP/repeatPenalty thread through this path today — the rest of
`config.generation` (topK, seed, an explicit grammar) isn't wired here yet.

`GenerationQueue.enqueue` runs several gates before any request leaves the
process: a loaded-backend check (or a routed/"Deep" backend bypassing that
gate entirely, since it's host-owned and lifecycle-managed outside
`InferenceService`), a queue-depth cap, and a tool-capability gate that
throws immediately if tools were requested against a backend whose
`capabilities.supportsToolCalling` is `false` — better a clear
"backend doesn't support tools" error here than a model looping on "I cannot
access tools" while the dispatch loop silently finds nothing to call. When
tools are present, no explicit grammar was supplied, and the backend
supports grammar-constrained sampling, the queue derives a tool-call GBNF
grammar itself, choice-aware: `.auto` gets a prose-permitting grammar (so the
model isn't forced into a `{` on every turn), `.tool(name:)` gets a
single-tool union, `.none` gets nothing.

The concrete backend for this trace is
[`OllamaBackend`](../Sources/ManifoldOllama/OllamaBackend.swift), which
extends `SSECloudBackend` rather than implementing `InferenceBackend` from
scratch. `SSECloudBackend.generate(prompt:systemPrompt:config:hints:)`
(in [`SSECloudBackend.swift`](../Sources/ManifoldCloudCore/SSECloudBackend.swift))
validates the config, builds the provider-specific HTTP request via the
backend's own `makeGenerationRequest` override, and starts the SSE read loop,
returning a `GenerationStream` immediately — the actual bytes arrive
asynchronously into that stream's continuation. Every cloud-shaped backend
(`OllamaBackend`, `ClaudeBackend`, `OpenAIBackend`, LM-Studio-compatible
endpoints) shares this same `generate` implementation; they differ only in
request/response encoding, which lives in each backend's own
`makeGenerationRequest`/parsing overrides.

## 7. Streaming back up

`runGenerationTurn`'s second half drains `stream.events` in one loop,
mirroring the same four concerns `GenerationQueue`'s own internal consumer
applies (this is the runtime-layer copy of that logic, not a second
implementation of it — see the loop's own comment for the parity claim):

- **Token batching** — a `StreamingTokenBatcher` coalesces per-token deltas
  into UI-cadenced batches (`config.streamingUpdateInterval` /
  `streamingBatchCharacterLimit`) before emitting `.tokenEmitted`, so a fast
  local backend doesn't flood the UI with single-character updates.
- **Thinking-block disclosure** — a second batcher does the same for
  reasoning tokens, and
  [`ThinkingBlockManager`](../Sources/ManifoldCloudCore/ThinkingBlockManager.swift)
  (`.open()` / `.flushIfOpen(into:)`) tracks whether a thinking block is
  currently open so `.thinkingStarted` / `.thinkingUpdated` /
  `.thinkingFinalized` fire at the right boundaries rather than mid-block.
- **Tool dispatch** — a `.dispatchToolCall` event appends a `.toolCall`
  content part to the in-flight assistant message and emits
  `.toolCallRequested`; the matching `.appendToolResult` does the same for
  results. The actual tool execution — including retry policy, sequential vs.
  parallel dispatch, and per-call error classification — happens one layer
  down in
  [`GenerationToolDispatchLoop`](../Sources/ManifoldInference/Services/GenerationToolDispatchLoop.swift):
  `runLoop` drives repeated turns, `dispatchTurn` decides sequential vs.
  parallel dispatch for the calls in one turn, and `dispatchSequential` /
  `dispatchParallel` bottom out in `dispatchOne` / `dispatchWithRetry` for a
  single call. A turn that exceeds the loop's iteration limit or a run-level
  token budget surfaces as `.toolIterationLimitExceeded` /
  `.runTokenBudgetExceeded` rather than hanging — both map to `.errorRaised`
  in the runtime's event stream.
- **Loop detection** — a `RepetitionDetector`, driven by
  `consumer.shouldStopForLoop(content:)`, checks both visible text and
  thinking text after every batch flush; a positive match calls
  `inferenceService.cancelAsync(token)` and emits `.loopDetected` instead of
  letting a repeating model run to its token limit.

A `GenerationStreamConsumer` value sits in front of the raw `GenerationEvent`
switch and classifies each event into one of the cases above (plus
`.recordUsage`, `.recordHandoff`, `.recordThinkingSignature`), so the loop
body itself reads as a flat, single-level `switch` over already-classified
intents rather than a nested decode of the wire event shape.

## 8. Where cancellation branches off

Two independent paths can end a turn early, and both converge on the same
primitive: `inferenceService.cancelAsync(token)`.

**External cancellation** goes through `ConversationRuntime.cancel(_:)`
(§2): a caller holding the `ConversationStreamHandle` from `processTurn`
calls it, the runtime marks the handle cancelled in its registry, and — if
the handle is currently registered with a live token — issues the cancel
into the engine. There's a documented race: if `cancel(_:)` is called
*between* `processTurn` returning and the executor's `registry.register(handle:token:)`
call, the mark-cancelled call finds nothing to cancel yet; the executor
re-checks `registry.isCancelled(handle)` right after registering and issues
the cancel itself if the race went that way, so a cancel that arrives before
registration is never silently lost.

**In-loop cancellation** is the streaming loop checking
`isCancelled(handle:)` at the top of every iteration (§7) — this is what
makes an already-issued cancel actually stop token production rather than
merely stopping future calls to `cancelAsync`. Loop detection and tool-budget
overruns (§7) reuse the exact same `cancelAsync` call as the explicit-cancel
path; from the engine's point of view there is one cancellation mechanism,
triggered from three call sites.

In every case the terminal event is the same shape: a `.streamFinished` /
`generationCompleted` with a `.cancelled` reason, not a silently truncated
stream — a consumer that only watches for a normal completion event will
still see a definite end to the turn.

## 9. Landing the turn

Once the drain loop exits — normally, cancelled, or on error — the executor
writes the final assistant `ChatMessage` via `persistence.insertMessage(assistantMessage)`.
There are three call sites for this in
[`ConversationTurnExecutor.swift`](../Sources/ManifoldRuntime/Services/ConversationTurnExecutor.swift),
one per landing shape (clean completion, empty-content edge case, and the
cancelled/error path that still wants the partial content persisted rather
than discarded) — all three go through the same
[`MessageStore`](../Sources/ManifoldRuntime/Protocols/MessageStore.swift)
port, so a host's persistence layer only ever needs one write path to
support. `completeOutcome(...)` then resolves the optional
`ConversationTurnOutcomeCompletion` exactly once, which is what gives
`processTurnWithOutcome`'s `.outcome` its "completes exactly once regardless
of `events` consumers" guarantee.

## 10. Back to the UI

`ChatViewModel` never talks to `ConversationRuntime` inline inside
`sendMessage` — it wires a `ChatGenerationCoordinator` once at init time
(`installGenerationCoordinatorClosures()` in
[`ChatViewModel+GenerationCoordinator.swift`](../Sources/ManifoldUI/ViewModels/ChatViewModel+GenerationCoordinator.swift)),
and that coordinator's `onSetLastTurnState` closure is what actually writes
`self.lastTurnState`. `sendMessage(_:)` (§1) polls that same property after
its inner `await sendMessage()` returns. This indirection is what lets other
`@Observable` surfaces on `ChatViewModel` — `activityPhase`,
`backgroundTaskError`, `messageIDsWithStreamingThinking` — update from the
identical event flow without each maintaining its own subscription logic.

Separately, and concurrently, the image/video/audio generation surfaces
(`ChatViewModel+ImageGeneration.swift`, `+VideoGeneration.swift`,
`+AudioGeneration.swift`) each run their own `Task` draining `runtime.events`
directly to project progress state — a live example of the multi-consumer
tap pattern
[`ObservingATurn.md`](../Sources/ManifoldRuntime/ManifoldRuntime.docc/Articles/ObservingATurn.md)
documents. That article is the right place to read *how* to add another
independent consumer of the event flow (`addEventTap`, buffering policy,
the yield-outside-lock invariant); this document only needed to show that
the pattern is already load-bearing in the shipped UI, not re-explain it.

## Questions to carry through the codebase

The value of a trace like this fades the moment it's read once and shelved.
Use it as a lens on the next PR that touches this path:

1. **Which layer decided this?** If a value looks wrong at the UI, is the
   bug in assembly (§5), the engine's gates (§6), or the runtime's event
   translation (§7)? The three tiers in `API-DESIGN.md`'s ownership table
   map directly onto sections above.
2. **Is this event emitted on the no-op path too?** `.beforeContextAssembly`
   / `.contextAssembled` fire even with zero providers (§5) specifically so
   adapters don't need a special case. A new event this document doesn't
   mention should ask the same question before it ships.
3. **What happens if the optional collaborator is `nil`?** `pipeline`,
   `budgetPlanner`, `ragService`, `sessionRecord`, `turnHookRegistry` are all
   optional in `runGenerationTurn` — each has a documented `nil` branch. A
   change that adds a new optional collaborator should show the same care.
4. **Does a failure here abort the turn, or degrade it?** Context-assembly
   and inference-dispatch failures abort (§5, §6); RAG-retrieval and
   session-touch failures degrade and log (§5, §4). Getting a new failure
   mode's bucket wrong either silently swallows a real error or aborts a
   turn that should have survived it.
5. **Does cancellation actually reach this code path?** §8's three call
   sites converge on one primitive precisely so a new early-exit path (a
   fourth stopping condition) doesn't need its own cancellation plumbing —
   it should reuse `cancelAsync`, not invent a parallel stop signal.
6. **Is the persisted record and the wire-visible record the same shape?**
   §4 and §5 both note places where the persisted `ChatMessage` and the
   `[StructuredMessage]` sent to the backend are constructed from the same
   source but are not identical (attachment splicing, `kind.isWireVisible`
   filtering, the synthetic boundary message). A change to one without the
   other is the recurring shape of bugs in this pipeline.
