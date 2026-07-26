import Foundation
import os

/// Process-wide, lock-guarded stash of the most recent cloud request
/// diagnostic summary.
///
/// Used when a generation stalls before the first event so the stall log
/// can re-emit the request shape that was in flight — without re-encoding
/// the body or threading a backend reference through `GenerationStream`.
///
/// Callers (today: `OllamaBackend` for tool-continuation turns, #2376)
/// write a compact, log-safe summary at request-build time; the SSE runner
/// re-reads it only on a pre-first-event failure. **Always clear on every
/// completion path** (success or failure) so a later unrelated stall does
/// not re-attribute an old body. Secrets and user content must never be
/// stored here — roles, tool names, byte sizes only.
///
/// Single-slot by design: concurrent generations race last-write-wins; the
/// diagnostic is best-effort evidence for the most recent request, not a
/// multi-session ledger.
///
/// `package` (not `public`): only cloud backends and the SSE runner need it;
/// host apps observe the log lines, not this type.
package enum CloudRequestDiagnostic {
    private static let lock = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Replaces the stored summary. Pass `nil` to clear.
    package static func store(_ summary: String?) {
        lock.withLock { $0 = summary }
    }

    /// Drop any stored summary without logging. Call on every generation
    /// completion (including successful ones).
    package static func clear() {
        lock.withLock { $0 = nil }
    }

    /// Snapshot of the last stored summary, or `nil` when none has been written.
    package static func load() -> String? {
        lock.withLock { $0 }
    }

    /// Logs the last summary (if any) at error level with a stall-oriented
    /// prefix, then clears the stash so a subsequent unrelated stall does not
    /// re-attribute an old body. Only for genuine pre-first-event failures —
    /// not zero-event success paths.
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
