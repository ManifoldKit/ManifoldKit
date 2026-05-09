import XCTest
@testable import ManifoldInference

/// Tests for CloudBackendError descriptions.
final class CloudBackendErrorTests: XCTestCase {

    func test_authenticationFailed_includesProvider() {
        let error = CloudBackendError.authenticationFailed(provider: "Claude")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("Claude"),
                      "Error should include the provider name: \(description)")
    }

    func test_rateLimited_withRetryAfter() {
        let error = CloudBackendError.rateLimited(retryAfter: 30)
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("30"),
                      "Should include retry-after seconds: \(description)")
    }

    func test_rateLimited_withoutRetryAfter() {
        let error = CloudBackendError.rateLimited(retryAfter: nil)
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.lowercased().contains("rate limited"),
                      "Should mention rate limiting: \(description)")
        XCTAssertFalse(description.contains("seconds"),
                       "Should not mention seconds when retryAfter is nil")
    }

    func test_serverError_includesCodeAndMessage() {
        let error = CloudBackendError.serverError(statusCode: 500, message: "Internal failure")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("500"),
                      "Should include status code: \(description)")
        XCTAssertTrue(description.contains("Internal failure"),
                      "Should include error message: \(description)")
    }

    func test_missingAPIKey_description() {
        let error = CloudBackendError.missingAPIKey
        let description = error.errorDescription ?? ""
        XCTAssertFalse(description.isEmpty, "missingAPIKey should have a description")
        XCTAssertTrue(description.lowercased().contains("api key"),
                      "Should mention API key: \(description)")
    }

    func test_invalidURL_descriptionContainsURL() {
        let urlString = "https://bad url"
        let error = CloudBackendError.invalidURL(urlString)
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains(urlString),
                      "errorDescription should contain the URL string '\(urlString)': \(description)")
    }

    func test_invalidURL_localizedDescriptionIsNonEmpty() {
        let error = CloudBackendError.invalidURL("https://bad url")
        XCTAssertFalse(error.localizedDescription.isEmpty,
                       "localizedDescription should be non-empty for invalidURL")
    }

    func test_allCases_haveNonEmptyLocalizedDescription() {
        let errors: [CloudBackendError] = [
            .invalidURL("https://bad url"),
            .authenticationFailed(provider: "Test"),
            .rateLimited(retryAfter: 10),
            .rateLimited(retryAfter: nil),
            .serverError(statusCode: 503, message: "Service unavailable"),
            .networkError(underlying: URLError(.notConnectedToInternet)),
            .parseError("unexpected token"),
            .missingAPIKey,
            .streamInterrupted,
            .backendDeallocated,
            .timeout(.seconds(120)),
            .blockedAddress("Hostname evil.com resolved to 10.0.0.1"),
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription,
                            "\(error) errorDescription should be non-nil")
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true,
                           "\(error) errorDescription should be non-empty")
        }
    }

    func test_allCases_haveNonNilDescription() {
        let errors: [CloudBackendError] = [
            .invalidURL("https://bad"),
            .authenticationFailed(provider: "Test"),
            .rateLimited(retryAfter: 10),
            .rateLimited(retryAfter: nil),
            .serverError(statusCode: 503, message: "Service unavailable"),
            .networkError(underlying: URLError(.notConnectedToInternet)),
            .parseError("unexpected token"),
            .missingAPIKey,
            .streamInterrupted,
            .backendDeallocated,
            .timeout(.seconds(60)),
            .blockedAddress("10.0.0.1"),
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription,
                            "\(error) should have a non-nil description")
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true,
                           "\(error) should have a non-empty description")
        }
    }

    // MARK: - Retryability

    func test_backendDeallocated_isNotRetryable() {
        XCTAssertFalse(CloudBackendError.backendDeallocated.isRetryable)
    }

    func test_timeout_isRetryable() {
        XCTAssertTrue(CloudBackendError.timeout(.seconds(120)).isRetryable)
    }

    func test_streamInterrupted_isRetryable() {
        XCTAssertTrue(CloudBackendError.streamInterrupted.isRetryable)
    }

    // MARK: - blockedAddress

    func test_blockedAddress_isNotRetryable() {
        // Sabotage check: adding blockedAddress to the retryable cases causes this to fail.
        XCTAssertFalse(CloudBackendError.blockedAddress("10.0.0.1").isRetryable,
                       "A blocked-address error must never be retried — the address is still private")
    }

    func test_blockedAddress_descriptionContainsDetail() {
        let detail = "Hostname evil.example.com resolved to 192.168.1.1"
        let error = CloudBackendError.blockedAddress(detail)
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains(detail),
                      "errorDescription should contain the blocking detail: \(description)")
    }

    func test_allCases_includeBlockedAddress_haveNonEmptyDescription() {
        let error = CloudBackendError.blockedAddress("test detail")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
    }
}
