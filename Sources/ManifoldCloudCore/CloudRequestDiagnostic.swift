import Foundation
import os

/// Process-wide, lock-guarded stash of the most recent cloud request
/// diagnostic summary.
///
/// Used when a generation later stalls (`InferenceError.idleTimeout`, or a
/// zero-event completion) so the stall log line can re-emit the request
/// shape that was in flight — without re-encoding the body or threading a
/// backend reference through `GenerationStream`.
///
/// Callers (today: `OllamaBackend` for tool-continuation turns, #2376)
/// write a compact, log-safe summary at request-build time; the SSE runner
/// re-reads it if the stream produces zero events or errors before the
/// first event. Secrets and user content must never be stored here —
/// roles, tool names, byte sizes only.
///
/// `package` (not `public`): only cloud backends and the SSE runner need it;
/// host apps observe the log lines, not this type.
package enum CloudRequestDiagnostic {
    private static let lock = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Replaces the stored summary. Pass `nil` to clear.
    package static func store(_ summary: String?) {
        lock.withLock { $0 = summary }
    }

    /// Snapshot of the last stored summary, or `nil` when none has been written.
    package static func load() -> String? {
        lock.withLock { $0 }
    }

    /// Logs the last summary (if any) at error level with a stall-oriented
    /// prefix, then clears the stash so a subsequent unrelated stall does not
    /// re-attribute an old body.
    package static func logAndClearOnStall(backendName: String, context: String) {
        let summary = lock.withLock { value -> String? in
            let current = value
            value = nil
            return current
        }
        guard let summary else { return }
        Log.network.error(
            "\(backendName, privacy: .public) stall diagnostic (\(context, privacy: .public)): \(summary, privacy: .public)"
        )
    }
}
