import Foundation
import ManifoldInference

// MARK: - ConversationEvent
//
// Contract for ``ConversationRuntime`` *users* (demo, ChatbotUI-iOS).
// Direct ``InferenceService`` consumers (Fireside) drive the ports
// themselves and key off the underlying ``GenerationStream`` directly —
// they do not consume this event surface.
//
// Phase 1.2.5 PR-A ships the initial event enum but only emits a subset
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
// ``GenerationQueue`` and ``ChatViewModel``.
//
// Phase 1.2.5 PR-B adds `.messageRemoved` and emits it
// from the regenerate sub-flow when the runtime deletes the last assistant
// message before replacing it.
//
// Phase 1.2.5 PR-C adds `.messageUpdated` and emits it
// from the edit sub-flow when the runtime updates an existing message's
// content in place.

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

    /// A previously persisted message was removed from the conversation.
    /// Fires when the runtime deletes a message on behalf of a sub-flow
    /// (e.g. regenerate deletes the last assistant message before replacing
    /// it). Adapters remove the matching message from their view-state array.
    case messageRemoved(messageID: ChatMessageRecord.ID)

    /// A previously persisted message's content was updated in place.
    /// Fires when the runtime modifies an existing message (e.g. edit
    /// sub-flow changes a message's content). Adapters update the matching
    /// message in their view-state array.
    case messageUpdated(ChatMessageRecord)

    /// A new session was created by branching from an existing conversation.
    /// Fires synchronously (before `branch` returns) after the copied messages
    /// are persisted. `copiedCount` is the number of messages inserted into
    /// the new session.
    case sessionBranched(newSessionID: UUID, copiedCount: Int)

    /// The runtime queued a generation request and the underlying stream
    /// started. Carries the assistant message ID the stream will write
    /// into so adapters can pair token deltas with the right message slot.
    case streamStarted(messageID: ChatMessageRecord.ID)

    /// A token (or a small batch of tokens) was emitted by the backend.
    /// Adapters concatenate `delta` onto the assistant message body for
    /// display.
    case tokenEmitted(messageID: ChatMessageRecord.ID, delta: String)

    /// The backend reported token usage for the turn. Fires before the
    /// terminal stream event when usage is available, including partial-output
    /// error and cancellation paths. The runtime also copies these counts onto
    /// the persisted assistant message when one is saved.
    case tokenUsageRecorded(messageID: ChatMessageRecord.ID, promptTokens: Int, completionTokens: Int)

    /// The model began emitting a thinking block. Fires when the first thinking
    /// token arrives. Adapters use this to show a "Thinking…" indicator.
    case thinkingStarted(messageID: ChatMessageRecord.ID)

    /// A batch of thinking tokens was flushed. Same cadence as `.tokenEmitted`
    /// (batcher-controlled). Adapters concatenate `partialText` for progressive
    /// display. Does not carry the signature — that arrives with `.thinkingFinalized`.
    case thinkingUpdated(messageID: ChatMessageRecord.ID, partialText: String)

    /// The thinking block completed. `text` is the full thinking content;
    /// `signature` is the server-verification value (non-nil for extended-thinking
    /// backends) that must be round-tripped on the next request. Adapters persist
    /// both and hide the thinking content behind a disclosure UI.
    case thinkingFinalized(messageID: ChatMessageRecord.ID, text: String, signature: String?)

    /// The repetition detector fired. The runtime has already called `cancelAsync`
    /// on the in-flight token; adapters surface this as a user-visible warning
    /// (distinct from `.errorRaised` — the model ran, it just looped).
    case loopDetected(messageID: ChatMessageRecord.ID)

    /// The stream terminated. `reason` distinguishes normal completion,
    /// user-initiated cancel, empty output, and length-limited stop.
    case streamFinished(messageID: ChatMessageRecord.ID, reason: FinishReason)

    /// An error surfaced during the turn. Adapters route to user-facing
    /// error UI; the runtime has already cleaned up partial state by the
    /// time this event fires.
    case errorRaised(ConversationError)

    /// Updating the session timestamp failed. This is intentionally distinct
    /// from ``errorRaised(_:)`` because sidebar recency is best-effort and
    /// must not fail the user's turn.
    case sessionTouchFailed(sessionID: UUID)

    // MARK: Context pipeline (runtime hook points)

    /// Fires immediately before the runtime asks ``PromptContextPipeline``
    /// to assemble slots. Carries the user's prompt text when available
    /// (non-nil for send sub-flows; `nil` for regenerate / edit sub-flows
    /// that have no user-supplied text) and the request shape providers
    /// will see. Load-bearing for runtime-using consumers — adapters pin
    /// behaviour against this case.
    case beforeContextAssembly(prompt: String?, request: PromptContextRequest)

    /// Fires after slots are assembled, before the request is enqueued.
    /// Carries the merged `[PromptSlot]` so adapters can introspect what's
    /// about to be sent (debug overlays, prompt inspectors). Load-bearing.
    case contextAssembled(slots: [PromptSlot])

    /// Fires after generation has completed and the runtime has determined
    /// the turn's final visible output. `finalText` is the full
    /// visible-content body (concatenated text parts, thinking blocks
    /// excluded) and may be empty. Consumers must not assume the assistant
    /// message was persisted when this event fires — empty generations fire
    /// `afterGeneration` without creating a stored assistant record for
    /// `messageID`. Load-bearing — adapters key post-turn work (analytics,
    /// summarisation) against this case rather than chasing
    /// `.streamFinished` and re-fetching the message.
    case afterGeneration(messageID: ChatMessageRecord.ID, finalText: String)

    /// History was compressed (older messages dropped to fit the context
    /// window, or via a host-driven compression command). Load-bearing,
    /// although PR-A does not emit it from the send sub-flow — context
    /// management still lives in `GenerationQueue` for the pre-PR-A
    /// surface. Reserved for later sub-flows that route compression
    /// through the runtime.
    case compressionTriggered(removed: [ChatMessageRecord.ID], reason: CompressionReason)

    /// Emitted when ``CompressionPolicy`` has replaced the session's message
    /// history with a compressed version. Consumers that cache the message
    /// list should invalidate their cache on this event.
    ///
    /// `insertedRecords` contains the full replacement set in insertion order —
    /// consumers that need to reconcile side-channel data (e.g. knowledge-graph
    /// nodes) can use these records without re-querying the store.
    ///
    /// This case is emitted by the ``ConversationTurnExecutor`` inline
    /// compression path introduced alongside ``CompressionPolicy``.
    case historyCompressed(sessionID: UUID, insertedRecords: [ChatMessageRecord])

    // MARK: Tool calls

    /// The model requested a tool invocation. Adapters that gate tools
    /// behind user approval pause for explicit `.toolCallApproved` before
    /// dispatching. PR-A does not emit this — the existing tool-loop
    /// orchestration stays in `ChatViewModel`/`GenerationQueue`
    /// until a follow-up PR routes it through the runtime.
    case toolCallRequested(ToolCall)

    /// A tool call previously surfaced via ``toolCallRequested(_:)`` was
    /// approved (either auto-approved or by an explicit user gate).
    case toolCallApproved(ToolCall.ID)

    /// A tool call completed; `ToolResult` carries the outcome (success
    /// payload or error classification).
    case toolCallCompleted(ToolCall.ID, ToolResult)
}

// `ToolCall.ID` is `String` (see `ManifoldInference.ToolCall.id`). The
// associated values use the structural type rather than introducing a
// nominal alias here so the event enum's shape is explicit at the
// pattern-match site.
extension ToolCall {
    public typealias ID = String
}
