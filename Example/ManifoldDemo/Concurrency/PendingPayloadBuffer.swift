import Foundation
import ManifoldInference

/// Single-slot buffer for inbound payloads that arrive before the app is
/// ready to handle them.
///
/// The demo opens a SwiftData container asynchronously inside `.task` on
/// the root `ProgressView`, which means a deep-link URL (App Intent,
/// Share Extension, `manifolddemo://` scheme) can fire *before*
/// ``ChatViewModel`` has been wired to persistence. When that happens the
/// view model's ``ChatViewModel/ingest(_:)`` would no-op — the payload
/// would be lost.
///
/// This actor holds the latest payload until the post-mount hook drains
/// it. If a second payload arrives before the first is drained, the
/// **later** one wins — we intentionally do not queue, because a user
/// firing two intents in quick succession almost certainly meant the
/// most recent one.
actor PendingPayloadBuffer {

    private var pending: InboundPayload?

    /// Stores `payload`, replacing any previously-buffered payload.
    ///
    /// - Parameter payload: The payload to buffer.
    func store(_ payload: InboundPayload) {
        pending = payload
    }

    /// Returns the buffered payload without consuming it, or `nil` if
    /// the buffer is empty.
    ///
    /// Use this to check whether a payload is pending before taking an
    /// action that would conflict with the drain path (e.g. creating an
    /// empty session that `ingest(_:)` would duplicate).
    func peek() -> InboundPayload? {
        pending
    }

    /// Removes and returns the buffered payload, or `nil` if the buffer
    /// is empty.
    func drain() -> InboundPayload? {
        let value = pending
        pending = nil
        return value
    }
}
