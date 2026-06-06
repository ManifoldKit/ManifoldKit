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
/// or renaming any of these is a coordinated breaking change. The stream
/// carrying these values is single-consumer and bounded; it is intended for
/// lifecycle observation, ordering assertions, UI adapters, and host-side
/// event consumers that continuously drain the stream.
///
/// Token, thinking, tool-call, skill, hook, and handoff cases are
/// observational progress signals. They help adapters render incremental
/// state, but they are not a durable command-completion protocol and can be
/// dropped if the single consumer falls behind the bounded buffer.
///
/// Terminal-looking and mutation cases such as ``streamFinished(messageID:reason:)``,
/// ``errorRaised(_:)``, ``messageInserted(_:)``, ``messageRemoved(messageID:)``,
/// and ``messageUpdated(_:)`` remain important for event-stream consumers: a
/// UI adapter should still reconcile visible state from them. Command-style
/// callers that need to know when a specific turn has completed should instead
/// call ``ConversationRuntime/processTurnWithOutcome(_:)`` and await the
/// returned ``ConversationTurnHandle/outcome``. That per-turn path is not
/// affected by event buffering, dropped events, or another component owning
/// the global stream.
///
/// The four load-bearing extension points for runtime-using consumers are
/// ``beforeContextAssembly(prompt:request:)``, ``historyShaped(sessionID:diagnostics:)``,
/// ``contextAssembled(slots:)``,
/// ``afterGeneration(messageID:finalText:)``, and
/// ``compressionTriggered(removed:reason:)``: those bracket the two phases of
/// generation host adapters need to extend even when they don't drive their
/// own turn loop.
///
/// Adding cases is allowed (source-breaking for exhaustive `switch`
/// consumers — we accept that pre-1.0); renaming or removing requires
/// coordination per the runtime ports plan.
public enum ConversationEvent: Sendable {

    // MARK: Lifecycle

    /// A new message was inserted into the active conversation. Fires for
    /// both the user message the runtime persists at the start of a turn
    /// and the assistant message the runtime persists at the end.
    case messageInserted(ChatMessage)

    /// A previously persisted message was removed from the conversation.
    /// Fires when the runtime deletes a message on behalf of a sub-flow
    /// (e.g. regenerate deletes the last assistant message before replacing
    /// it). Adapters remove the matching message from their view-state array.
    case messageRemoved(messageID: ChatMessage.ID)

    /// A previously persisted message's content was updated in place.
    /// Fires when the runtime modifies an existing message (e.g. edit
    /// sub-flow changes a message's content). Adapters update the matching
    /// message in their view-state array.
    case messageUpdated(ChatMessage)

    /// A new session was created by branching from an existing conversation.
    /// Fires synchronously (before `branch` returns) after the copied messages
    /// are persisted. `copiedCount` is the number of messages inserted into
    /// the new session.
    case sessionBranched(newSessionID: UUID, copiedCount: Int)

    /// The runtime queued a generation request and the underlying stream
    /// started. Carries the assistant message ID the stream will write
    /// into so adapters can pair token deltas with the right message slot.
    case streamStarted(messageID: ChatMessage.ID)

    /// A token (or a small batch of tokens) was emitted by the backend.
    /// Adapters concatenate `delta` onto the assistant message body for
    /// display.
    case tokenEmitted(messageID: ChatMessage.ID, delta: String)

    /// The backend reported token usage for the turn. Fires before the
    /// terminal stream event when usage is available, including partial-output
    /// error and cancellation paths. The runtime also copies these counts onto
    /// the persisted assistant message when one is saved.
    case tokenUsageRecorded(messageID: ChatMessage.ID, promptTokens: Int, completionTokens: Int)

    /// The model began emitting a thinking block. Fires when the first thinking
    /// token arrives. Adapters use this to show a "Thinking…" indicator.
    case thinkingStarted(messageID: ChatMessage.ID)

    /// A batch of thinking tokens was flushed. Same cadence as `.tokenEmitted`
    /// (batcher-controlled). Adapters concatenate `partialText` for progressive
    /// display. Does not carry the signature — that arrives with `.thinkingFinalized`.
    case thinkingUpdated(messageID: ChatMessage.ID, partialText: String)

    /// The thinking block completed. `text` is the full thinking content;
    /// `signature` is the server-verification value (non-nil for extended-thinking
    /// backends) that must be round-tripped on the next request. Adapters persist
    /// both and hide the thinking content behind a disclosure UI.
    case thinkingFinalized(messageID: ChatMessage.ID, text: String, signature: String?)

    /// The repetition detector fired. The runtime has already called `cancelAsync`
    /// on the in-flight token; adapters surface this as a user-visible warning
    /// (distinct from `.errorRaised` — the model ran, it just looped).
    case loopDetected(messageID: ChatMessage.ID)

    /// The stream terminated. `reason` distinguishes normal completion,
    /// user-initiated cancel, empty output, and length-limited stop.
    case streamFinished(messageID: ChatMessage.ID, reason: FinishReason)

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

    /// Fires after a registered ``HistoryShaper`` has produced the prompt-
    /// visible base history, before additive ``HistoryProvider`` records and
    /// prompt-context slots are assembled.
    ///
    /// `diagnostics` identify canonical records that were removed or rewritten
    /// for prompt visibility. No event is emitted when no shaper is registered.
    case historyShaped(sessionID: UUID, diagnostics: [HistoryShapingDiagnostic])

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
    case afterGeneration(messageID: ChatMessage.ID, finalText: String)

    /// History was compressed (older messages dropped to fit the context
    /// window, or via a host-driven compression command). Load-bearing,
    /// although PR-A does not emit it from the send sub-flow — context
    /// management still lives in `GenerationQueue` for the pre-PR-A
    /// surface. Reserved for later sub-flows that route compression
    /// through the runtime.
    case compressionTriggered(removed: [ChatMessage.ID], reason: CompressionReason)

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
    case historyCompressed(sessionID: UUID, insertedRecords: [ChatMessage])

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

    // MARK: Multi-agent + skills + hooks (W2B / W2C / W3A telemetry)

    /// The active agent for a session changed via a ``HandoffDetector``
    /// detection. `from` is `nil` when the session had no prior active
    /// agent. The runtime has already persisted the swap and injected the
    /// boundary message into the next turn's structured history by the
    /// time this event fires.
    case agentHandoff(from: UUID?, to: UUID)

    /// A skill was invoked through the skill dispatcher tool (W2C path —
    /// stubbed here so adapters can begin pattern-matching against it
    /// today; emission lands when the W2C wiring sees the skill dispatch
    /// callsite).
    case skillInvoked(name: String, sessionID: UUID)

    /// A registered hook fired in response to an internal event boundary
    /// (preToolUse / preCompact for now). Stub for observational adapters
    /// before W2C/W3A wire the emission callsites.
    case hookFired(event: String, sessionID: UUID)
}

// `ToolCall.ID` is `String` (see `ManifoldInference.ToolCall.id`). The
// associated values use the structural type rather than introducing a
// nominal alias here so the event enum's shape is explicit at the
// pattern-match site.
extension ToolCall {
    public typealias ID = String
}

// MARK: - Kind

extension ConversationEvent {

    /// The kind of this event, stripped of associated values.
    ///
    /// Used as the stable discriminant in JSONL traces and
    /// ``XCTAssertEventSubsequence(_:contains:file:line:)`` assertions.
    public var kind: ConversationEventKind {
        switch self {
        case .messageInserted:          return .messageInserted
        case .messageRemoved:           return .messageRemoved
        case .messageUpdated:           return .messageUpdated
        case .sessionBranched:          return .sessionBranched
        case .streamStarted:            return .streamStarted
        case .tokenEmitted:             return .tokenEmitted
        case .tokenUsageRecorded:       return .tokenUsageRecorded
        case .thinkingStarted:          return .thinkingStarted
        case .thinkingUpdated:          return .thinkingUpdated
        case .thinkingFinalized:        return .thinkingFinalized
        case .loopDetected:             return .loopDetected
        case .streamFinished:           return .streamFinished
        case .errorRaised:              return .errorRaised
        case .sessionTouchFailed:       return .sessionTouchFailed
        case .beforeContextAssembly:    return .beforeContextAssembly
        case .historyShaped:            return .historyShaped
        case .contextAssembled:         return .contextAssembled
        case .afterGeneration:          return .afterGeneration
        case .compressionTriggered:     return .compressionTriggered
        case .historyCompressed:        return .historyCompressed
        case .toolCallRequested:        return .toolCallRequested
        case .toolCallApproved:         return .toolCallApproved
        case .toolCallCompleted:        return .toolCallCompleted
        case .agentHandoff:             return .agentHandoff
        case .skillInvoked:             return .skillInvoked
        case .hookFired:                return .hookFired
        }
    }
}
