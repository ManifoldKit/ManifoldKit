import XCTest
@testable import ManifoldInference

/// Tests for `InferenceError.unsupportedGrammar(reason:)` introduced in #663.
final class InferenceErrorUnsupportedGrammarTests: XCTestCase {

    // MARK: - errorDescription

    func test_unsupportedGrammar_errorDescription_isNonNil() {
        let error = InferenceError.unsupportedGrammar(reason: "GBNF sampling not implemented")
        XCTAssertNotNil(error.errorDescription)
    }

    func test_unsupportedGrammar_errorDescription_containsReason() {
        let reason = "GBNF sampling not implemented"
        let error = InferenceError.unsupportedGrammar(reason: reason)
        let desc = error.errorDescription!
        XCTAssertTrue(desc.contains(reason),
                      "errorDescription should include the reason string")
    }

    // MARK: - isRetryable

    func test_unsupportedGrammar_isNotRetryable() {
        let error = InferenceError.unsupportedGrammar(reason: "not supported")
        XCTAssertFalse(error.isRetryable)
    }
}
