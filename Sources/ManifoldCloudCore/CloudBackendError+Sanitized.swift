import Foundation
import ManifoldInference

public extension CloudBackendError {

    /// Construction chokepoint for the two `CloudBackendError` cases that carry
    /// free-form, upstream-controlled text (`serverError`'s message and
    /// `parseError`'s detail).
    ///
    /// An upstream error can reach the UI by two paths — a non-2xx HTTP body and
    /// an error event delivered *inside* a 200-OK SSE stream — and the footgun
    /// audit (2026-06-05) found the sanitize invariant wired into only the first
    /// (class A, "two paths, one guard"). Routing every upstream-text
    /// construction through `sanitizedServerError`/`sanitizedParseError` makes
    /// the invariant uniform and greppable: a raw `.serverError(message:)` /
    /// `.parseError(_:)` in the cloud modules now means the text is a trusted
    /// literal, and any new error path reaches for the `sanitized*` factory
    /// rather than re-deriving sanitization and risking a bypass.
    ///
    /// `CloudErrorSanitizer.sanitize` is pure and idempotent, so it is safe for
    /// callers that already sanitized (e.g. the HTTP path's
    /// ``SSECloudBackend/drainAndSanitizeErrorBody(_:extractor:)``, which adds
    /// host-aware fallbacks the static stream paths cannot) to route through the
    /// factory as a second, no-op pass.
    ///
    /// These factories live in `ManifoldCloudCore` rather than beside
    /// `CloudBackendError` (declared in the `ManifoldInference` kernel) because
    /// the sanitizer lives here — the kernel must not depend on `CloudCore`.
    static func sanitizedServerError(
        statusCode: Int,
        rawMessage: String?,
        host: String? = nil
    ) -> CloudBackendError {
        .serverError(statusCode: statusCode, message: CloudErrorSanitizer.sanitize(rawMessage, host: host))
    }

    /// In-stream counterpart to ``sanitizedServerError(statusCode:rawMessage:host:)``
    /// for upstream error text surfaced as a parse failure. See that factory for
    /// the chokepoint rationale.
    static func sanitizedParseError(
        _ rawMessage: String?,
        host: String? = nil
    ) -> CloudBackendError {
        .parseError(CloudErrorSanitizer.sanitize(rawMessage, host: host))
    }
}
