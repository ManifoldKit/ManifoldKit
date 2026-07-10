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

    // MARK: - unpinnedCredentialedHost (H1)

    func test_unpinnedCredentialedHost_isNotRetryable() {
        XCTAssertFalse(
            CloudBackendError.unpinnedCredentialedHost("api.example.com").isRetryable,
            "unpinnedCredentialedHost must not retry — host configuration must change"
        )
    }

    func test_unpinnedCredentialedHost_descriptionMentionsHostAndPins() {
        let error = CloudBackendError.unpinnedCredentialedHost("api.example.com")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("api.example.com"), description)
        XCTAssertTrue(description.lowercased().contains("pin"), description)
    }

    // MARK: - New cases: quotaExceeded / providerOverloaded / contentFiltered

    func test_quotaExceeded_description_includesProvider() {
        let error = CloudBackendError.quotaExceeded(provider: "Claude")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("Claude"),
                      "quotaExceeded should mention the provider: \(description)")
        XCTAssertTrue(description.lowercased().contains("quota") || description.lowercased().contains("billing"),
                      "quotaExceeded should mention quota or billing: \(description)")
    }

    func test_quotaExceeded_isNotRetryable() {
        // Billing cap: the user must act; retrying within the same period won't help.
        // Sabotage check: moving quotaExceeded into the retryable arm would flip this.
        XCTAssertFalse(CloudBackendError.quotaExceeded(provider: "Claude").isRetryable,
                       "quotaExceeded must not be retryable — user action required")
    }

    func test_providerOverloaded_description_withRetryAfter() {
        let error = CloudBackendError.providerOverloaded(provider: "Claude", retryAfter: 15)
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("Claude"),
                      "providerOverloaded should mention the provider: \(description)")
        XCTAssertTrue(description.contains("15"),
                      "providerOverloaded should include the retry delay: \(description)")
    }

    func test_providerOverloaded_description_withoutRetryAfter() {
        let error = CloudBackendError.providerOverloaded(provider: "Claude", retryAfter: nil)
        let description = error.errorDescription ?? ""
        XCTAssertFalse(description.isEmpty,
                       "providerOverloaded should have a description even without retryAfter")
    }

    func test_providerOverloaded_isRetryable() {
        // Provider at capacity is transient — exponential backoff should help.
        // Sabotage check: removing providerOverloaded from the retryable arm flips this.
        XCTAssertTrue(CloudBackendError.providerOverloaded(provider: "Claude", retryAfter: nil).isRetryable,
                      "providerOverloaded must be retryable — capacity issues are transient")
    }

    func test_contentFiltered_description_withReason() {
        let error = CloudBackendError.contentFiltered(provider: "Claude", reason: "violence")
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("Claude"),
                      "contentFiltered should mention the provider: \(description)")
        XCTAssertTrue(description.contains("violence"),
                      "contentFiltered should include the reason: \(description)")
    }

    func test_contentFiltered_description_withoutReason() {
        let error = CloudBackendError.contentFiltered(provider: "OpenAI", reason: nil)
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("OpenAI"),
                      "contentFiltered should mention the provider when no reason: \(description)")
    }

    func test_contentFiltered_isNotRetryable() {
        // Content must change for the request to succeed — retrying the same prompt won't help.
        // Sabotage check: adding contentFiltered to the retryable arm flips this.
        XCTAssertFalse(CloudBackendError.contentFiltered(provider: "Claude", reason: nil).isRetryable,
                       "contentFiltered must not be retryable — content must change")
    }

    // MARK: - CategorizedError conformance

    func test_category_rateLimited_passesRetryAfter() {
        let error = CloudBackendError.rateLimited(retryAfter: 30)
        XCTAssertEqual(error.category, .rateLimited(retryAfter: 30),
                       "rateLimited category must preserve the retryAfter value")
    }

    func test_category_rateLimited_nilRetryAfter() {
        let error = CloudBackendError.rateLimited(retryAfter: nil)
        XCTAssertEqual(error.category, .rateLimited(retryAfter: nil))
    }

    func test_category_quotaExceeded() {
        let error = CloudBackendError.quotaExceeded(provider: "Claude")
        XCTAssertEqual(error.category, .quotaExceeded)
    }

    func test_category_providerOverloaded_passesRetryAfter() {
        let error = CloudBackendError.providerOverloaded(provider: "Claude", retryAfter: nil)
        XCTAssertEqual(error.category, .providerOverloaded(retryAfter: nil),
                       "providerOverloaded category must preserve the retryAfter value")
    }

    func test_category_authenticationFailed() {
        XCTAssertEqual(CloudBackendError.authenticationFailed(provider: "Claude").category, .authenticationFailed)
        XCTAssertEqual(CloudBackendError.missingAPIKey.category, .authenticationFailed)
    }

    func test_category_contentFiltered() {
        let error = CloudBackendError.contentFiltered(provider: "Claude", reason: nil)
        XCTAssertEqual(error.category, .contentFiltered)
    }

    func test_category_networkErrors_areRetryableTransient() {
        XCTAssertEqual(CloudBackendError.networkError(underlying: URLError(.notConnectedToInternet)).category, .retryableTransient)
        XCTAssertEqual(CloudBackendError.streamInterrupted.category, .retryableTransient)
        XCTAssertEqual(CloudBackendError.timeout(.seconds(30)).category, .retryableTransient)
    }

    func test_category_5xxServerError_isRetryableTransient() {
        XCTAssertEqual(CloudBackendError.serverError(statusCode: 503, message: "unavailable").category, .retryableTransient)
    }

    func test_category_4xxServerError_isNonRetryable() {
        XCTAssertEqual(CloudBackendError.serverError(statusCode: 400, message: "bad request").category, .nonRetryable)
    }
}
