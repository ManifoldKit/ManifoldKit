import Foundation
import ManifoldInference

// MARK: - AudioRuntimeEvent
//
// Sibling to `ImageRuntimeEvent` / `VideoRuntimeEvent` for the audio-generation
// (TTS) runtime. Per the umbrella-#1002 architectural call, audio-side runtime
// events ride a parallel enum rather than landing as new cases on the
// image/video/text event surfaces, so exhaustive switches in those consumers
// stay closed.
//
// `AudioRuntimeEvent` is distinct from the backend-level `AudioGenerationEvent`
// (`.progress(step:total:)` / `.completed(URL)`): the runtime translates between
// layers, keying every event to a `ChatMessage.ID` so adapters can pair UI
// state to the right placeholder slot.

/// Events emitted by ``AudioGenerationRuntime``.
///
/// Sibling to ``ImageRuntimeEvent`` / ``VideoRuntimeEvent``. The runtime
/// translates the backend-level ``AudioGenerationEvent`` (raw step + URL) into
/// these runtime-level events keyed to a placeholder ``ChatMessage/ID``.
///
/// Unlike the image and video runtime events — whose terminal `.completed`
/// carries a legacy typed payload (`ImageMessagePayload` / `VideoMessagePayload`)
/// — audio has no legacy typed payload, so `.completed` carries the unified
/// ``GeneratedMediaPayload`` directly (with ``MediaKind/audio``). This is the
/// shape the persisted ``MessagePart/generatedMedia(_:)`` part already uses.
public enum AudioRuntimeEvent: Sendable, Equatable {

    /// Generation started for the placeholder message at `messageID`. The
    /// placeholder has been persisted via ``MessageStore`` with empty
    /// `contentParts` — adapters render a "generating" affordance until the
    /// terminal ``completed(messageID:payload:)`` event updates the message in
    /// place.
    case started(messageID: ChatMessage.ID, prompt: String)

    /// Render progress. `step` is 1-indexed; `totalSteps` is the backend's
    /// estimate (after clamping). Intermediate state is **not** persisted —
    /// adapters subscribe to events for progressive UI; persistence stays
    /// minimal until completion.
    case progress(messageID: ChatMessage.ID, step: Int, totalSteps: Int)

    /// Generation completed; the persisted message at `messageID` now carries a
    /// single ``MessagePart/generatedMedia(_:)`` part with `payload` (a
    /// ``GeneratedMediaPayload`` of ``MediaKind/audio``). Adapters refresh their
    /// view-state for `messageID` from the store (the runtime has already
    /// written through ``MessageStore``).
    case completed(messageID: ChatMessage.ID, payload: GeneratedMediaPayload)

    /// Generation failed. Carries the underlying error so adapters can surface
    /// user-facing error UI; the placeholder message at `messageID` remains in
    /// the store with its original (empty) `contentParts` — the runtime emits
    /// the event, the host decides UX.
    case failed(messageID: ChatMessage.ID, error: any Error)

    /// User cancelled before completion. The placeholder message at `messageID`
    /// remains in the store with empty `contentParts`; same host-decides-UX
    /// policy as ``failed(messageID:error:)``.
    case cancelled(messageID: ChatMessage.ID)

    // MARK: - Equatable

    // Custom because `any Error` is not `Equatable`. Two `.failed` events are
    // considered equal when their message IDs match — sufficient for tests
    // asserting event sequences without forcing every error type through
    // `Equatable`.
    public static func == (lhs: AudioRuntimeEvent, rhs: AudioRuntimeEvent) -> Bool {
        switch (lhs, rhs) {
        case let (.started(lid, lp), .started(rid, rp)):
            return lid == rid && lp == rp
        case let (.progress(lid, ls, lt), .progress(rid, rs, rt)):
            return lid == rid && ls == rs && lt == rt
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
