import Foundation
import BaseChatInference

// MARK: - ConversationEvent
//
// Contract for ``ConversationRuntime`` *users* (demo, ChatbotUI-iOS).
// Direct ``InferenceService`` consumers (Fireside) drive the ports
// themselves and key off the underlying ``GenerationStream`` directly —
// they do not consume this event surface.
//
// Phase 1.2.5 PR-A ships the full 12-case enum but only emits a subset
// from the send sub-flow:
//   - `.beforeContextAssembly`, `.contextAssembled` — fire each turn (with
//     empty slots when no providers are registered)
//   - `.messageInserted`, `.streamStarted`, `.tokenEmitted`,
//     `.streamFinished`, `.afterGeneration`, `.errorRaised` — fire on the
//     send happy path / cancel / failure
// Tool call cases (`toolCallRequested`, `.toolCallApproved`,
// `.toolCallCompleted`) and `.compressionTriggered` are present on the
// surface so adapters can bind to them today; the runtime emits them in
// later PRs as the corresponding behaviour migrates from
// ``GenerationCoordinator`` and ``ChatViewModel``.

/// Events emitted by ``ConversationRuntime``.
///
/// The case set is the contract for runtime-using consumers — collapsing
/// or renaming any of these is a coordinated breaking change. The four
/// load-bearing cases for runtime-using consumers are
/// ``beforeContextAssembly``, ``contextAssembled``, ``afterGeneration``,
/// and ``compressionTriggered``: those bracket the two phases of generation
/// host adapters need to extend even when they don't drive their own turn
/// loop.
///
/// Adding cases is allowed (source-breaking for exhaustive `switch`
/// consumers — we accept that pre-1.0); renaming or removing requires
/// coordination per the runtime ports plan.
public enum ConversationEvent: Sendable {

    // MARK: Lifecycle

    /// A new message was inserted into the active conversation. Fires for
    /// both the user message the runtime persists at the start of a turn
    /// and the assistant message the runtime persists at the end.
    case messageInserted(ChatMessageRecord)

    /// The runtime queued a generation request and the underlying stream
    /// started. Carries the assistant message ID the stream will write
    /// into so adapters can pair token deltas with the right message slot.
    case streamStarted(messageID: ChatMessageRecord.ID)

    /// A token (or a small batch of tokens) was emitted by the backend.
    /// Adapters concatenate `delta` onto the assistant message body for
    /// display.
    case tokenEmitted(messageID: ChatMessageRecord.ID, delta: String)

    /// The stream terminated. `reason` distinguishes normal completion,
    /// user-initiated cancel, empty output, and length-limited stop.
    case streamFinished(messageID: ChatMessageRecord.ID, reason: FinishReason)

    /// An error surfaced during the turn. Adapters route to user-facing
    /// error UI; the runtime has already cleaned up partial state by the
    /// time this event fires.
    case errorRaised(ConversationError)

    // MARK: Context pipeline (runtime hook points)

    /// Fires immediately before the runtime asks ``PromptContextPipeline``
    /// to assemble slots. Carries the user's prompt text (when applicable)
    /// and the request shape providers will see. Load-bearing for
    /// runtime-using consumers — adapters pin behaviour against this case.
    case beforeContextAssembly(prompt: String, request: PromptContextRequest)

    /// Fires after slots are assembled, before the request is enqueued.
    /// Carries the merged `[PromptSlot]` so adapters can introspect what's
    /// about to be sent (debug overlays, prompt inspectors). Load-bearing.
    case contextAssembled(slots: [PromptSlot])

    /// Fires after the assistant message has been finalised and persisted.
    /// `finalText` is the full visible-content body (concatenated text
    /// parts, thinking blocks excluded). Load-bearing — adapters key
    /// post-turn work (analytics, summarisation) against this case rather
    /// than chasing `.streamFinished` and re-fetching the message.
    case afterGeneration(messageID: ChatMessageRecord.ID, finalText: String)

    /// History was compressed (older messages dropped to fit the context
    /// window, or via a host-driven compression command). Load-bearing,
    /// although PR-A does not emit it from the send sub-flow — context
    /// management still lives in `GenerationCoordinator` for the pre-PR-A
    /// surface. Reserved for later sub-flows that route compression
    /// through the runtime.
    case compressionTriggered(removed: [ChatMessageRecord.ID], reason: CompressionReason)

    // MARK: Tool calls

    /// The model requested a tool invocation. Adapters that gate tools
    /// behind user approval pause for explicit `.toolCallApproved` before
    /// dispatching. PR-A does not emit this — the existing tool-loop
    /// orchestration stays in `ChatViewModel`/`GenerationCoordinator`
    /// until a follow-up PR routes it through the runtime.
    case toolCallRequested(ToolCall)

    /// A tool call previously surfaced via ``toolCallRequested(_:)`` was
    /// approved (either auto-approved or by an explicit user gate).
    case toolCallApproved(ToolCall.ID)

    /// A tool call completed; `ToolResult` carries the outcome (success
    /// payload or error classification).
    case toolCallCompleted(ToolCall.ID, ToolResult)
}

// `ToolCall.ID` is `String` (see `BaseChatInference.ToolCall.id`). The
// associated values use the structural type rather than introducing a
// nominal alias here so the event enum's shape is explicit at the
// pattern-match site.
extension ToolCall {
    public typealias ID = String
}
