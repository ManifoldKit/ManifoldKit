import Foundation
import ManifoldInference

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
// `ChatMessage.ID` so adapters can pair UI state to the right
// placeholder slot.

/// Events emitted by ``ImageGenerationRuntime``.
///
/// Sibling to ``ConversationEvent`` — image-side events are deliberately a
/// parallel enum rather than additional cases on the text-side surface so
/// exhaustive switches in text consumers stay closed. The runtime translates
/// the backend-level ``ImageGenerationEvent`` (raw step + URL) into these
/// runtime-level events keyed to a placeholder ``ChatMessage/ID``.
public enum ImageRuntimeEvent: Sendable, Equatable {

    /// Generation started for the placeholder message at `messageID`. The
    /// placeholder has been persisted via ``MessageStore`` with empty
    /// `contentParts` — adapters render a "generating" affordance until the
    /// terminal ``completed(messageID:payload:)`` event updates the message
    /// in place.
    case started(messageID: ChatMessage.ID, prompt: String)

    /// Denoising progress. `step` is 1-indexed; `totalSteps` is the
    /// backend's actually-resolved step count — the caller's
    /// ``ImageGenerationConfig/steps`` when it was set (after any
    /// backend-side clamping), or the backend's own model-preset default
    /// when the caller left `steps` `nil`. The runtime relays the compliant
    /// backend's real count starting with the first tick; `0` only appears
    /// if a backend violates the "Step-count resolution contract" on
    /// ``ImageGenerationBackend/generate(prompt:config:)`` and reports an
    /// unresolved `total`. Intermediate state is **not** persisted —
    /// adapters subscribe to events for progressive UI; persistence stays
    /// minimal until completion.
    case progress(messageID: ChatMessage.ID, step: Int, totalSteps: Int)

    /// Intermediate denoise preview for the placeholder at `messageID`.
    ///
    /// Emitted only when the caller opted in via
    /// ``ImageGenerationConfig/previewStride``; the runtime forwards the
    /// backend's ``ImageGenerationEvent/preview(step:total:image:)`` without
    /// touching the store. `image` carries encoded image bytes (PNG/JPEG)
    /// for a progressively-refining thumbnail — adapters render it directly
    /// and discard prior previews; previews are **not** persisted (only the
    /// terminal ``completed(messageID:payload:)`` writes through
    /// ``MessageStore``).
    case preview(messageID: ChatMessage.ID, step: Int, totalSteps: Int, image: Data)

    /// Generation completed; the persisted message at `messageID` now
    /// carries a single ``MessagePart/generatedImage(_:)`` part with
    /// `payload`. Adapters refresh their view-state for `messageID` from
    /// the store (the runtime has already written through ``MessageStore``).
    case completed(messageID: ChatMessage.ID, payload: ImageMessagePayload)

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
    // are considered equal when their message IDs match and the localized
    // descriptions of their errors match — sufficient for tests asserting
    // event sequences without forcing every error type through `Equatable`.
    public static func == (lhs: ImageRuntimeEvent, rhs: ImageRuntimeEvent) -> Bool {
        switch (lhs, rhs) {
        case let (.started(lid, lp), .started(rid, rp)):
            return lid == rid && lp == rp
        case let (.progress(lid, ls, lt), .progress(rid, rs, rt)):
            return lid == rid && ls == rs && lt == rt
        case let (.preview(lid, ls, lt, li), .preview(rid, rs, rt, ri)):
            return lid == rid && ls == rs && lt == rt && li == ri
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
