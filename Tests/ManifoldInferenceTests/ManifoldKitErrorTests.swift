import XCTest
@testable import ManifoldInference

/// Unit coverage for ``ManifoldKitError``, the unified user-facing error rim.
///
/// Covers:
/// - `URLError → ManifoldKitError` mapping across every bucket that the
///   inference / cloud / HuggingFace stacks can produce.
/// - `errorDescription` is non-empty for every case (so consumers presenting
///   `error.localizedDescription` always get a usable string).
/// - Idempotency of `from(_:)` — passing a `ManifoldKitError` returns the same
///   value, so it is safe to call at any layer.
/// - Wrapping: `CloudBackendError.networkError(underlying:)` and
///   `HuggingFaceError.downloadFailed(underlying:)` produce sanitised
///   user-facing strings rather than raw CFNetwork codes.
final class ManifoldKitErrorTests: XCTestCase {

    // MARK: - URLError mapping

    func test_from_URLError_timedOut() {
        XCTAssertEqual(ManifoldKitError.from(URLError(.timedOut)), .timedOut)
    }

    func test_from_URLError_cancelled() {
        XCTAssertEqual(ManifoldKitError.from(URLError(.cancelled)), .cancelled)
    }

    func test_from_URLError_notConnectedBuckets() {
        XCTAssertEqual(ManifoldKitError.from(URLError(.notConnectedToInternet)), .notConnectedToInternet)
        XCTAssertEqual(ManifoldKitError.from(URLError(.networkConnectionLost)), .notConnectedToInternet)
        XCTAssertEqual(ManifoldKitError.from(URLError(.dataNotAllowed)), .notConnectedToInternet)
        XCTAssertEqual(ManifoldKitError.from(URLError(.internationalRoamingOff)), .notConnectedToInternet)
    }

    func test_from_URLError_dnsBuckets() {
        XCTAssertEqual(ManifoldKitError.from(URLError(.cannotFindHost)), .dnsFailure)
        XCTAssertEqual(ManifoldKitError.from(URLError(.dnsLookupFailed)), .dnsFailure)
        XCTAssertEqual(ManifoldKitError.from(URLError(.cannotConnectToHost)), .dnsFailure)
    }

    func test_from_URLError_tlsBuckets() {
        XCTAssertEqual(ManifoldKitError.from(URLError(.secureConnectionFailed)), .tlsFailure)
        XCTAssertEqual(ManifoldKitError.from(URLError(.serverCertificateUntrusted)), .tlsFailure)
        XCTAssertEqual(ManifoldKitError.from(URLError(.serverCertificateHasBadDate)), .tlsFailure)
        XCTAssertEqual(ManifoldKitError.from(URLError(.serverCertificateNotYetValid)), .tlsFailure)
        XCTAssertEqual(ManifoldKitError.from(URLError(.serverCertificateHasUnknownRoot)), .tlsFailure)
        XCTAssertEqual(ManifoldKitError.from(URLError(.clientCertificateRejected)), .tlsFailure)
        XCTAssertEqual(ManifoldKitError.from(URLError(.clientCertificateRequired)), .tlsFailure)
    }

    func test_from_URLError_malformedResponseBucketsToServerErrorZero() {
        let mapped = ManifoldKitError.from(URLError(.badServerResponse))
        guard case .serverError(let code, let message) = mapped else {
            return XCTFail("Expected .serverError, got \(mapped)")
        }
        XCTAssertEqual(code, 0)
        XCTAssertEqual(message, "Malformed server response")
    }

    func test_from_URLError_redirectAndBadURLBucketsToServerErrorZero() {
        if case .serverError(0, _) = ManifoldKitError.from(URLError(.httpTooManyRedirects)) {} else {
            XCTFail("redirect URLError should map to serverError(0, _)")
        }
        if case .serverError(0, _) = ManifoldKitError.from(URLError(.badURL)) {} else {
            XCTFail("badURL URLError should map to serverError(0, _)")
        }
    }

    func test_from_URLError_unknownCodeFallsThrough() {
        let mapped = ManifoldKitError.from(URLError(.userCancelledAuthentication))
        guard case .unknown = mapped else {
            return XCTFail("Unmapped URLError code should fall through to .unknown, got \(mapped)")
        }
    }

    // MARK: - NSError(NSURLErrorDomain) bridging

    func test_from_NSURLErrorDomain_NSError_mapsLikeURLError() {
        let nsError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertEqual(ManifoldKitError.from(nsError), .notConnectedToInternet)
    }

    // MARK: - CancellationError

    func test_from_CancellationError_isCancelled() {
        XCTAssertEqual(ManifoldKitError.from(CancellationError()), .cancelled)
    }

    // MARK: - DecodingError

    func test_from_DecodingError_keyNotFound_capturesFieldName() {
        struct Box: Decodable { let needed: String }
        let json = Data("{}".utf8)
        do {
            _ = try JSONDecoder().decode(Box.self, from: json)
            XCTFail("expected decode to throw")
        } catch {
            let mapped = ManifoldKitError.from(error)
            guard case .decodingFailure(let detail) = mapped else {
                return XCTFail("expected .decodingFailure, got \(mapped)")
            }
            XCTAssertTrue(detail.contains("needed"), "detail should reference the missing field, got: \(detail)")
        }
    }

    // MARK: - Keychain detection

    func test_from_KeychainError_mapsToKeychainUnavailable() {
        let err = KeychainError.storeFailed(-25291)
        XCTAssertEqual(ManifoldKitError.from(err), .keychainUnavailable)
    }

    // MARK: - Idempotency

    func test_from_existingManifoldKitError_returnsUnchanged() {
        let original = ManifoldKitError.tlsFailure
        XCTAssertEqual(ManifoldKitError.from(original), original)

        let server = ManifoldKitError.serverError(statusCode: 503, message: "down")
        XCTAssertEqual(ManifoldKitError.from(server), server)
    }

    // MARK: - errorDescription coverage

    func test_errorDescription_isNonEmptyForEveryCase() {
        let cases: [ManifoldKitError] = [
            .notConnectedToInternet,
            .timedOut,
            .cancelled,
            .tlsFailure,
            .dnsFailure,
            .serverError(statusCode: 0, message: nil),
            .serverError(statusCode: 0, message: ""),
            .serverError(statusCode: 0, message: "Malformed server response"),
            .serverError(statusCode: 503, message: nil),
            .serverError(statusCode: 503, message: "service unavailable"),
            .keychainUnavailable,
            .decodingFailure("missing field: foo"),
            .unknown(underlyingDescription: ""),
            .unknown(underlyingDescription: "weird thing happened"),
        ]
        for c in cases {
            let desc = c.errorDescription ?? ""
            XCTAssertFalse(desc.isEmpty, "case \(c) had empty errorDescription")
        }
    }

    // MARK: - User-facing string never contains CFNetwork codes

    func test_errorDescription_doesNotLeakCFNetworkCode() {
        // The whole point of the rim. A consumer that catches `notConnectedToInternet`
        // (whether constructed directly or mapped from URLError) must NOT see the
        // CFNetwork prefix in `localizedDescription`.
        let mapped = ManifoldKitError.from(URLError(.notConnectedToInternet))
        let desc = mapped.errorDescription ?? ""
        XCTAssertFalse(desc.contains("CFNetwork"), "leaked CFNetwork code: \(desc)")
        XCTAssertFalse(desc.contains("kCFErrorDomain"), "leaked CF error domain: \(desc)")
    }

    // MARK: - Round-trip via CloudBackendError

    func test_cloudBackendError_networkError_routesThroughRim() {
        let err = CloudBackendError.networkError(underlying: URLError(.notConnectedToInternet))
        let desc = err.errorDescription ?? ""
        // The rim's string for `.notConnectedToInternet` is "Not connected to the internet."
        XCTAssertTrue(
            desc.contains("Not connected to the internet"),
            "CloudBackendError did not route through the rim; got: \(desc)"
        )
        XCTAssertFalse(desc.contains("CFNetwork"), "rim should strip CFNetwork codes; got: \(desc)")
    }

    func test_huggingFaceError_downloadFailed_routesThroughRim() {
        let err = HuggingFaceError.downloadFailed(underlying: URLError(.timedOut))
        let desc = err.errorDescription ?? ""
        XCTAssertTrue(
            desc.contains("The request timed out"),
            "HuggingFaceError did not route through the rim; got: \(desc)"
        )
        XCTAssertFalse(desc.contains("CFNetwork"), "rim should strip CFNetwork codes; got: \(desc)")
    }

    // MARK: - Sendable

    // Compile-time assertion: ManifoldKitError must be Sendable so it can cross
    // actor boundaries without `@unchecked` (see CLAUDE.md "Swift 6 concurrency
    // gotchas" #2).
    func test_isSendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(ManifoldKitError.self)
    }
}
