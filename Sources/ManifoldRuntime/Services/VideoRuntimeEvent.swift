import Foundation
import ManifoldInference

// MARK: - VideoRuntimeEvent
//
// Sibling to `ImageRuntimeEvent` for the video-generation runtime. Per the
// umbrella-#1002 architectural call, video-side runtime events ride a
// parallel enum rather than landing as new cases on `ImageRuntimeEvent` or
// `ConversationEvent`.
//
// `VideoRuntimeEvent` is distinct from the backend-level
// `VideoGenerationEvent` (`.queued`, `.generating(fractionComplete:)`,
// `.completed(URL)`): the runtime translates between layers, keying every
// event to a `ChatMessage.ID` so adapters can pair UI state to the
// right placeholder slot.

/// Events emitted by ``VideoGenerationRuntime``.
///
/// Sibling to ``ImageRuntimeEvent`` — video-side events are deliberately a
/// parallel enum so exhaustive switches in image and text consumers stay
/// closed. The runtime translates the backend-level ``VideoGenerationEvent``
/// (raw fraction + URL) into these runtime-level events keyed to a
/// placeholder ``ChatMessage/ID``.
public enum VideoRuntimeEvent: Sendable, Equatable {

    /// Generation started for the placeholder message at `messageID`. The
    /// placeholder has been persisted via ``MessageStore`` with empty
    /// `contentParts` — adapters render a "generating" affordance until the
    /// terminal ``completed(messageID:payload:)`` event updates the message
    /// in place.
    case started(messageID: ChatMessage.ID, prompt: String)

    /// Generation progress. `fractionComplete` is a backend-estimated value
    /// in 0.0–1.0. Intermediate state is **not** persisted — adapters
    /// subscribe to events for progressive UI; persistence stays minimal
    /// until completion.
    case progress(messageID: ChatMessage.ID, fractionComplete: Double)

    /// Generation completed; the persisted message at `messageID` now
    /// carries a single ``MessagePart/generatedVideo(_:)`` part with
    /// `payload`. Adapters refresh their view-state for `messageID` from
    /// the store (the runtime has already written through ``MessageStore``).
    case completed(messageID: ChatMessage.ID, payload: VideoMessagePayload)

    /// Generation failed. Carries the underlying error so adapters can
    /// surface user-facing error UI; the placeholder message at `messageID`
    /// remains in the store with its original (empty) `contentParts` so
    /// adapters can either render an inline failure indicator or call
    /// ``MessageStore/deleteMessage(_:)`` to drop the slot — the runtime
    /// emits the event, the host decides UX.
    case failed(messageID: ChatMessage.ID, error: any Error)

    /// User cancelled before completion. The placeholder message at
    /// `messageID` remains in the store with empty `contentParts`; same
    /// host-decides-UX policy as ``failed(messageID:error:)``.
    case cancelled(messageID: ChatMessage.ID)

    // MARK: - Equatable

    // Custom because `any Error` is not `Equatable`. Two `.failed` events
    // are considered equal when their message IDs match — sufficient for
    // tests asserting event sequences without forcing every error type
    // through `Equatable`.
    public static func == (lhs: VideoRuntimeEvent, rhs: VideoRuntimeEvent) -> Bool {
        switch (lhs, rhs) {
        case let (.started(lid, lp), .started(rid, rp)):
            return lid == rid && lp == rp
        case let (.progress(lid, lf), .progress(rid, rf)):
            return lid == rid && lf == rf
        case let (.completed(lid, lp), .completed(rid, rp)):
            return lid == rid && lp == rp
        case let (.failed(lid, _), .failed(rid, _)):
            return lid == rid
        case let (.cancelled(lid), .cancelled(rid)):
            return lid == rid
        default:
            return false
        }
    }
}
