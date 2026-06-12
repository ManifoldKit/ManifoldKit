import XCTest
@testable import ManifoldCloudCore
@testable import ManifoldInference

/// Tests for the ``CloudBackendError`` sanitizing factories
/// (``CloudBackendError/sanitizedServerError(statusCode:rawMessage:host:)`` and
/// ``CloudBackendError/sanitizedParseError(_:host:)``).
///
/// The footgun audit found cloud error text reaching the UI unsanitized on the
/// in-stream SSE path because the sanitize invariant was wired into only the
/// non-2xx HTTP branch (class A — "two paths, one guard"). These factories are
/// the construction chokepoint that closes that class: every upstream-text
/// `CloudBackendError` now routes through `CloudErrorSanitizer` at construction,
/// so no current or future error path can surface raw HTML / tokens / URLs.
///
/// XCTest (not Swift Testing) so this file stays clear of the `SwiftTestingAuditTest`
/// merged-filter allowlist (#681).
final class CloudBackendErrorSanitizedFactoryTests: XCTestCase {

    func test_serverErrorFactory_stripsHTML_beforeErrorDescription() {
        let error = CloudBackendError.sanitizedServerError(
            statusCode: 500,
            rawMessage: "<img src=x onerror=alert(1)>",
            host: "api.example.com"
        )
        let description = error.errorDescription ?? ""
        XCTAssertFalse(description.contains("<img"))
        XCTAssertFalse(description.contains("onerror"))
        // HTML-shaped bodies collapse to the host-aware generic fallback.
        XCTAssertTrue(description.contains("api.example.com"))
    }

    func test_serverErrorFactory_redactsLeakedJWT() {
        let error = CloudBackendError.sanitizedServerError(
            statusCode: 502,
            rawMessage: "auth failed for eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.sig"
        )
        XCTAssertFalse((error.errorDescription ?? "").contains("eyJ"))
    }

    func test_parseErrorFactory_sanitizesInStreamErrorText() {
        let error = CloudBackendError.sanitizedParseError("see https://evil.example/callback?token=abc")
        let description = error.errorDescription ?? ""
        XCTAssertFalse(description.contains("https://"))
        XCTAssertFalse(description.contains("evil.example"))
    }

    func test_benignMessage_survivesBoundedButIntact() {
        let error = CloudBackendError.sanitizedServerError(statusCode: 503, rawMessage: "Service temporarily unavailable")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("Service temporarily unavailable"))
        XCTAssertTrue(description.contains("503"))
    }

    func test_sanitization_isIdempotent_onAlreadyCleanText() {
        let once = CloudErrorSanitizer.sanitize("Rate limit reached", host: nil)
        let viaFactory = CloudBackendError.sanitizedServerError(statusCode: 429, rawMessage: once)
        XCTAssertEqual(viaFactory.errorDescription?.contains(once), true)
    }
}
