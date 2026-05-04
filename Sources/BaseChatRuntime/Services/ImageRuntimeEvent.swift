import Foundation
import BaseChatInference

// MARK: - ImageRuntimeEvent
//
// Sibling to `ConversationEvent` for the image-generation runtime. Per the
// umbrella-#1002 architectural call, image-side runtime events ride a
// parallel enum rather than landing as new cases on `ConversationEvent`:
// text-side consumers exhaustively switch over `ConversationEvent`, and
// adding image cases would gain unreachable switch arms in every text
// consumer with no upside.
//
// `ImageRuntimeEvent` is also distinct from the backend-level
// `ImageGenerationEvent` (`progress(step:total:)` / `completed(URL)`):
// the runtime translates between layers, keying every event to a
// `ChatMessageRecord.ID` so adapters can pair UI state to the right
// placeholder slot.

/// Events emitted by ``ImageGenerationRuntime``.
///
/// Sibling to ``ConversationEvent`` — image-side events are deliberately a
/// parallel enum rather than additional cases on the text-side surface so
/// exhaustive switches in text consumers stay closed. The runtime translates
/// the backend-level ``ImageGenerationEvent`` (raw step + URL) into these
/// runtime-level events keyed to a placeholder ``ChatMessageRecord/ID``.
public enum ImageRuntimeEvent: Sendable, Equatable {

    /// Generation started for the placeholder message at `messageID`. The
    /// placeholder has been persisted via ``MessageStore`` with empty
    /// `contentParts` — adapters render a "generating" affordance until the
    /// terminal ``completed(messageID:payload:)`` event updates the message
    /// in place.
    case started(messageID: ChatMessageRecord.ID, prompt: String)

    /// Denoising progress. `step` is 1-indexed; `totalSteps` is the value
    /// the caller passed in ``ImageGenerationConfig/steps`` (after any
    /// backend-side clamping). Intermediate state is **not** persisted —
    /// adapters subscribe to events for progressive UI; persistence stays
    /// minimal until completion.
    case progress(messageID: ChatMessageRecord.ID, step: Int, totalSteps: Int)

    /// Generation completed; the persisted message at `messageID` now
    /// carries a single ``MessagePart/generatedImage(_:)`` part with
    /// `payload`. Adapters refresh their view-state for `messageID` from
    /// the store (the runtime has already written through ``MessageStore``).
    case completed(messageID: ChatMessageRecord.ID, payload: ImageMessagePayload)

    /// Generation failed. Carries the underlying error so adapters can
    /// surface user-facing error UI; the placeholder message at `messageID`
    /// remains in the store with its original (empty) `contentParts` so
    /// adapters can either render an inline failure indicator or call
    /// ``MessageStore/deleteMessage(_:)`` to drop the slot — the runtime
    /// emits the event, the host decides UX.
    case failed(messageID: ChatMessageRecord.ID, error: any Error)

    /// User cancelled before completion. The placeholder message at
    /// `messageID` remains in the store with empty `contentParts`; same
    /// host-decides-UX policy as ``failed(messageID:error:)``.
    case cancelled(messageID: ChatMessageRecord.ID)

    // MARK: - Equatable

    // Custom because `any Error` is not `Equatable`. Two `.failed` events
    // are considered equal when their message IDs match and the localized
    // descriptions of their errors match — sufficient for tests asserting
    // event sequences without forcing every error type through `Equatable`.
    public static func == (lhs: ImageRuntimeEvent, rhs: ImageRuntimeEvent) -> Bool {
        switch (lhs, rhs) {
        case let (.started(lid, lp), .started(rid, rp)):
            return lid == rid && lp == rp
        case let (.progress(lid, ls, lt), .progress(rid, rs, rt)):
            return lid == rid && ls == rs && lt == rt
        case let (.completed(lid, lp), .completed(rid, rp)):
            return lid == rid && lp == rp
        case let (.failed(lid, le), .failed(rid, re)):
            return lid == rid && le.localizedDescription == re.localizedDescription
        case let (.cancelled(lid), .cancelled(rid)):
            return lid == rid
        default:
            return false
        }
    }
}
