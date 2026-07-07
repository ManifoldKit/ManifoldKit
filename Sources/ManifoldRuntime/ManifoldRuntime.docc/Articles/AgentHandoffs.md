# Agent Handoffs

Run a multi-agent session where one model "transfers" the conversation to another by emitting a synthetic tool call.

## When to use

Agent handoffs let a session host several personas (e.g. a research agent that hands off to a writer agent) without spinning up parallel actors or copying the conversation. One agent is active per turn; the model invokes `transfer_to_<other_agent_name>` and the runtime swaps the active agent in place.

This is **not** a multi-agent peer system. Agents are sequential and turn-scoped — the active agent owns the next turn entirely. For long-lived peer actors, see the v2 Team / Mailbox proposal.

> Note: There are two `Agent` types in the stack. ``ManifoldInference/Agent`` is the storage-agnostic value type that flows through the runtime. `ManifoldPersistenceSwiftData/PersistedAgent` is the SwiftData `@Model` row backing it (also still exported under the back-compat name `Agent` from that module). When you import both modules, prefer `PersistedAgent` for the persistence row so the bare `Agent` resolves unambiguously to the value type.

## The moving parts

| Piece | Lives in | Role |
|---|---|---|
| ``ManifoldInference/Agent`` | `ManifoldInference` | Value type: `id`, `name`, `systemPrompt`, `description`, `allowedToolNames`. |
| ``ManifoldInference/AgentHandoff`` | `ManifoldInference` | The detected transfer intent: `targetAgentID` + optional `payload`. |
| ``ManifoldInference/HandoffDetectionResult`` | `ManifoldInference` | `regular(ToolCall)` vs `handoff(AgentHandoff)`. |
| ``HandoffToolSource`` | `ManifoldRuntime` | ``SessionToolSource`` that synthesises one `transfer_to_<name>` tool per non-active agent. |
| ``ManifoldInference/ChatSession/agents`` | `ManifoldInference` | The session's agent registry — a `[Agent]` snapshot of the SwiftData rows. |
| ``ManifoldInference/ChatSession/activeAgentID`` | `ManifoldInference` | Drives system-prompt re-derivation each turn. |
| ``ConversationEvent/agentHandoff(from:to:)`` | `ManifoldRuntime` | Telemetry case emitted on every swap. |

## End-to-end setup

```swift,no-build
import Foundation
import ManifoldInference
import ManifoldRuntime

// 1. Define the agents.
let researcher = Agent(
    name: "researcher",
    systemPrompt: "You research topics and produce a tight outline. Hand off to the writer once the outline is ready.",
    description: "Researches a topic and produces a structured outline."
)

let writer = Agent(
    name: "writer",
    systemPrompt: "You take an outline and turn it into a polished long-form post.",
    description: "Turns an outline into a written piece."
)

// 2. Persist them on the session record (or seed via ManifoldPersistenceSwiftData
//    using the V9 schema). The active agent owns the next turn.
let session = ChatSession(
    title: "Blog post on X",
    agents: [researcher, writer],
    activeAgentID: researcher.id
)

// 3. Wire HandoffToolSource through ConversationRuntime.
let handoffSource = HandoffToolSource()
let runtime = ConversationRuntime(
    messageStore: messageStore,
    inferenceService: inferenceService,
    sessionToolSources: [handoffSource]
)
```

On each turn:

1. ``ConversationTurnExecutor`` calls ``HandoffToolSource/toolDefinitions(for:)``, which returns one `transfer_to_<name>` tool per agent other than the active one.
2. The executor re-derives the active system prompt from `session.activeAgentID → session.agents[id].systemPrompt`. **Prior assistant messages keep their `agentID` attribution** — the *active* prompt is recomputed, history is not rewritten.
3. The executor prepends a synthesised **Handoff instructions** block to the active agent's system prompt listing the sibling agents and when to transfer. Without this, weak/local models never trigger handoffs.
4. If the model emits a `transfer_to_<other>` tool call, the dispatch loop intercepts it (it never reaches ``HandoffToolSource/resolve(toolName:arguments:session:)`` — reaching `resolve` indicates missing detector wiring and throws ``HandoffSourceError/handoffMustBeInterceptedUpstream(_:)``).
5. The runtime updates `session.activeAgentID`, injects a synthetic system-role **boundary message** into the next turn's `structuredHistory` (`"[Handoff from researcher to writer] payload: …"`), and emits ``ConversationEvent/agentHandoff(from:to:)``.

## Per-message attribution

Assistant messages persist their authoring agent's UUID in `ChatMessage.agentID`. This intentionally is **not** a SwiftData `@Relationship`: dangling references are correct when an `Agent` row is later deleted, and UI falls back to a role-based render in that case.

## Limits

### Agent count soft cap

``HandoffToolSource/agentCountSoftCap`` is **4**. Exceeding it does not truncate the advertised list, but every extra agent adds one `transfer_to_<name>` tool to every turn and a warning is logged. Beyond 4, prompt-cache hit rate craters because the tool surface changes on every swap.

### Payload not preserved across turns (v1)

The `payload` field on ``ManifoldInference/AgentHandoff`` is included verbatim in the boundary message injected for the **next turn only**. Subsequent turns no longer see it as a distinct field — it merges into the receiving agent's transcript. Hosts that need durable hand-off context should encode it into the receiving agent's prior assistant message (or wait for v2, which lifts payloads onto a structured field on the new turn).

### `model:` hint on agents

Agents don't carry a `modelID` field in v1; the active model is the session's selected model, not the agent's. Per-agent model selection is on the v2 roadmap.

## Telemetry

Subscribe to ``ConversationRuntime/events`` and filter on ``ConversationEvent/agentHandoff(from:to:)`` for UI handoff chips or analytics. Combine with ``ConversationEvent/hookFired(event:sessionID:)`` and ``ConversationEvent/skillInvoked(name:sessionID:)`` for a full picture of which session-scoped sources fired this turn.
