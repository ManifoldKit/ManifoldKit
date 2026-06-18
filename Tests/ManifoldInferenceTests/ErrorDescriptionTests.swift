import XCTest
@testable import ManifoldInference

final class ErrorDescriptionTests: XCTestCase {

    // MARK: - HuggingFaceError

    func test_huggingFaceError_allCases_haveNonEmptyDescription() {
        let cases: [HuggingFaceError] = [
            .searchFailed(underlying: NSError(domain: "test", code: 1)),
            .modelNotFound(repoID: "org/model"),
            .downloadFailed(underlying: NSError(domain: "test", code: 2)),
            .networkUnavailable,
            .insufficientDiskSpace(required: 5_000_000_000, available: 1_000_000_000),
            .invalidDownloadedFile(reason: "bad magic"),
            .invalidRepoID("not-a-repo"),
        ]

        for error in cases {
            let desc = error.errorDescription
            XCTAssertNotNil(desc, "errorDescription should not be nil for \(error)")
            XCTAssertFalse(desc!.isEmpty, "errorDescription should not be empty for \(error)")
        }
    }

    func test_insufficientDiskSpace_formatsBytes() {
        let error = HuggingFaceError.insufficientDiskSpace(
            required: 4_000_000_000,
            available: 500_000_000
        )
        let desc = error.errorDescription!

        // ByteCountFormatter uses "GB" / "MB" style formatting
        XCTAssertTrue(desc.contains("Not enough disk space"), "Should mention disk space")
        XCTAssertTrue(desc.contains("available"), "Should mention available space")
    }

    func test_invalidRepoID_includesOffendingString() {
        let badID = "no-slash-here"
        let error = HuggingFaceError.invalidRepoID(badID)
        let desc = error.errorDescription!

        XCTAssertTrue(desc.contains(badID),
                       "Error description should include the invalid repo ID")
    }

    func test_modelNotFound_includesRepoID() {
        let error = HuggingFaceError.modelNotFound(repoID: "org/missing-model")
        let desc = error.errorDescription!

        XCTAssertTrue(desc.contains("org/missing-model"))
    }

    // MARK: - InferenceError

    func test_inferenceError_allCases_haveNonEmptyDescription() {
        let cases: [InferenceError] = [
            .modelNotFound(path: "/tmp/missing.gguf"),
            .modelLoadFailed(underlying: NSError(domain: "test", code: 1)),
            .inferenceFailure("context overflow"),
            .memoryInsufficient(required: 8_589_934_592, available: 4_294_967_296),
            .alreadyGenerating,
            .generationError("token limit"),
            .noBackendSatisfiesRequirements([.toolCalling]),
            .idleTimeout(.seconds(30)),
        ]

        for error in cases {
            let desc = error.errorDescription
            XCTAssertNotNil(desc, "errorDescription should not be nil for \(error)")
            XCTAssertFalse(desc!.isEmpty, "errorDescription should not be empty for \(error)")
        }
    }

    func test_noBackendSatisfiesRequirements_emptyPayload_hasGenericMessage() {
        // Empty payload must not produce a dangling colon. Constructed defensively
        // even though `RouterBackend` always sends at least one requirement.
        let error = InferenceError.noBackendSatisfiesRequirements([])
        let desc = error.errorDescription!
        XCTAssertFalse(desc.contains(":"), "Empty payload should not produce dangling colon: \(desc)")
        XCTAssertFalse(desc.isEmpty)
    }

    func test_memoryInsufficient_calculatesMB() {
        let required: UInt64 = 8 * 1024 * 1024   // 8 MB
        let available: UInt64 = 4 * 1024 * 1024   // 4 MB
        let error = InferenceError.memoryInsufficient(required: required, available: available)
        let desc = error.errorDescription!

        XCTAssertTrue(desc.contains("8"), "Should show required MB (8)")
        XCTAssertTrue(desc.contains("4"), "Should show available MB (4)")
        XCTAssertTrue(desc.contains("MB"), "Should include MB unit")
    }

    func test_modelNotFound_includesPath() {
        let path = "/var/data/models/test.gguf"
        let error = InferenceError.modelNotFound(path: path)
        let desc = error.errorDescription!

        XCTAssertTrue(desc.contains(path))
    }

    func test_alreadyGenerating_mentionsInProgress() {
        let error = InferenceError.alreadyGenerating
        let desc = error.errorDescription!

        XCTAssertTrue(desc.contains("generation") || desc.contains("progress"),
                       "Should mention generation in progress")
    }

    func test_idleTimeout_isRetryableTransient() {
        // The backend-neutral idle-timeout error (formerly CloudBackendError.timeout)
        // is a transient stall — retry may succeed.
        let error = InferenceError.idleTimeout(.seconds(30))
        XCTAssertEqual(error.category, .retryableTransient)
        XCTAssertTrue(error.isRetryable)
    }

    func test_idleTimeout_subSecondDescription_usesMilliseconds() {
        let error = InferenceError.idleTimeout(.milliseconds(250))
        let desc = error.errorDescription!
        XCTAssertTrue(desc.contains("250ms"), "Sub-second timeout should render ms: \(desc)")
    }

    // MARK: - BackendError conformance

    func test_inferenceError_conformsToBackendError() {
        let error: any BackendError = InferenceError.alreadyGenerating
        // The cast succeeds if InferenceError conforms to BackendError.
        XCTAssertTrue(error is InferenceError)
    }

    func test_cloudBackendError_conformsToBackendError() {
        let error: any BackendError = CloudBackendError.missingAPIKey
        // The cast succeeds if CloudBackendError conforms to BackendError.
        XCTAssertTrue(error is CloudBackendError)
    }

    // MARK: - InferenceErrorCategory (InferenceError)

    func test_inferenceError_contextExhausted_category_isContextExceeded() {
        let error = InferenceError.contextExhausted(promptTokens: 1000, maxOutputTokens: 100, contextSize: 512)
        XCTAssertEqual(error.category, .contextExceeded,
                       "contextExhausted must map to .contextExceeded — callers branch on this to offer compression")
    }

    func test_inferenceError_unsupportedModelArchitecture_category_isUnsupportedRequest() {
        let error = InferenceError.unsupportedModelArchitecture("clip")
        XCTAssertEqual(error.category, .unsupportedRequest)
    }

    func test_inferenceError_unsupportedGrammar_category_isUnsupportedRequest() {
        let error = InferenceError.unsupportedGrammar(reason: "backend lacks GBNF support")
        XCTAssertEqual(error.category, .unsupportedRequest)
    }

    func test_inferenceError_noBackendSatisfiesRequirements_category_isUnsupportedRequest() {
        let error = InferenceError.noBackendSatisfiesRequirements([.toolCalling])
        XCTAssertEqual(error.category, .unsupportedRequest)
    }

    func test_inferenceError_alreadyGenerating_category_isRetryableTransient() {
        // The caller can wait for the active generation to finish and retry.
        // Sabotage check: moving alreadyGenerating to .nonRetryable flips this.
        XCTAssertEqual(InferenceError.alreadyGenerating.category, .retryableTransient,
                       "alreadyGenerating must be retryableTransient — the caller should wait and retry")
    }

    func test_inferenceError_permanentErrors_category_isNonRetryable() {
        let permanentErrors: [InferenceError] = [
            .modelNotFound(path: "/missing.gguf"),
            .modelLoadFailed(underlying: NSError(domain: "test", code: 1)),
            .inferenceFailure("crash"),
            .memoryInsufficient(required: 8_589_934_592, available: 0),
            .generationError("decode error"),
        ]
        for error in permanentErrors {
            XCTAssertEqual(error.category, .nonRetryable,
                           "\(error) must map to .nonRetryable")
        }
    }

    func test_inferenceError_conformsToCategorizedError() {
        // Protocol conformance is verified via protocol existential.
        let error: any CategorizedError = InferenceError.alreadyGenerating
        XCTAssertNotNil(error.category as InferenceErrorCategory?)
    }

    func test_cloudBackendError_conformsToCategorizedError() {
        let error: any CategorizedError = CloudBackendError.missingAPIKey
        XCTAssertNotNil(error.category as InferenceErrorCategory?)
    }
}
