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
}
