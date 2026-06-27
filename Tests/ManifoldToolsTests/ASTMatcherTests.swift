import XCTest
@testable import ManifoldTools
import ManifoldInference

/// Unit coverage for the argument-level BFCL AST matcher — the axis the name-only
/// `ConformanceScorer` cannot see. Every negative case is a discrimination proof:
/// it confirms the matcher *rejects* a call that gets the arguments wrong, so a
/// passing `test_exactMatch_passes` can't be vacuously green.
final class ASTMatcherTests: XCTestCase {

    // MARK: - Helpers

    private func call(_ name: String, _ argsJSON: String) -> ToolCall {
        ToolCall(id: "c1", toolName: name, arguments: argsJSON)
    }

    /// `add(a, b)` with both required (no `""` optional marker).
    private let addExpected = BFCLExpectedCall(
        functionName: "add",
        acceptedValues: ["a": [.integer(17)], "b": [.integer(4)]]
    )

    /// `calculate_triangle_area` with `unit` optional (accepted list carries `""`).
    private let triangleExpected = BFCLExpectedCall(
        functionName: "calculate_triangle_area",
        acceptedValues: ["base": [.integer(10)], "height": [.integer(5)], "unit": [.string("units"), .string("")]]
    )

    private func hasFailure(_ result: ASTMatcher.MatchResult, where predicate: (ASTMatcher.Failure) -> Bool) -> Bool {
        result.failures.contains(where: predicate)
    }

    // MARK: - requiredParams derivation

    func test_requiredParams_excludesOptionalMarkedParams() {
        // `unit` is optional (its accepted list contains ""), base/height are not.
        XCTAssertEqual(triangleExpected.requiredParams, ["base", "height"])
        XCTAssertEqual(addExpected.requiredParams, ["a", "b"])
    }

    // MARK: - Positive matches

    func test_exactMatch_passes() {
        let result = ASTMatcher.match(call: call("add", #"{"a":17,"b":4}"#), against: addExpected)
        XCTAssertTrue(result.matched)
        XCTAssertTrue(result.failures.isEmpty)
    }

    func test_optionalParamOmitted_passes() {
        // `unit` left out — allowed because its accepted list includes "".
        let result = ASTMatcher.match(
            call: call("calculate_triangle_area", #"{"base":10,"height":5}"#),
            against: triangleExpected
        )
        XCTAssertTrue(result.matched, "omitting an optional param must still match: \(result.failures)")
    }

    func test_optionalParamWithAcceptedValue_passes() {
        let result = ASTMatcher.match(
            call: call("calculate_triangle_area", #"{"base":10,"height":5,"unit":"units"}"#),
            against: triangleExpected
        )
        XCTAssertTrue(result.matched, "\(result.failures)")
    }

    // MARK: - Numeric cross-type tolerance

    func test_integerActual_matchesNumberGroundTruth() {
        let expected = BFCLExpectedCall(functionName: "f", acceptedValues: ["x": [.number(100.0)]])
        let result = ASTMatcher.match(call: call("f", #"{"x":100}"#), against: expected)
        XCTAssertTrue(result.matched, "integer 100 should match ground-truth 100.0")
    }

    func test_numberActual_matchesIntegerGroundTruth() {
        let expected = BFCLExpectedCall(functionName: "f", acceptedValues: ["x": [.integer(4)]])
        let result = ASTMatcher.match(call: call("f", #"{"x":4.0}"#), against: expected)
        XCTAssertTrue(result.matched, "number 4.0 should match ground-truth 4")
    }

    func test_floatValue_matchesExactly() {
        let expected = BFCLExpectedCall(functionName: "bmi", acceptedValues: ["h": [.number(1.75)]])
        XCTAssertTrue(ASTMatcher.match(call: call("bmi", #"{"h":1.75}"#), against: expected).matched)
        // …and a different float is rejected — tolerance is numeric equality, not "any number".
        XCTAssertFalse(ASTMatcher.match(call: call("bmi", #"{"h":1.85}"#), against: expected).matched)
    }

    // MARK: - Negative matches (discrimination proofs)

    func test_wrongArgumentValue_fails() {
        let result = ASTMatcher.match(call: call("add", #"{"a":99,"b":4}"#), against: addExpected)
        XCTAssertFalse(result.matched)
        XCTAssertTrue(hasFailure(result) {
            if case .valueNotAllowed(let p, _, _) = $0 { return p == "a" }
            return false
        }, "wrong value for 'a' must surface a valueNotAllowed failure")
    }

    func test_missingRequiredParam_fails() {
        let result = ASTMatcher.match(call: call("add", #"{"a":17}"#), against: addExpected)
        XCTAssertFalse(result.matched)
        XCTAssertTrue(hasFailure(result) { $0 == .missingRequiredParam("b") })
    }

    func test_hallucinatedParam_fails() {
        let result = ASTMatcher.match(call: call("add", #"{"a":17,"b":4,"c":1}"#), against: addExpected)
        XCTAssertFalse(result.matched)
        XCTAssertTrue(hasFailure(result) { $0 == .hallucinatedParam("c") })
    }

    func test_optionalParamWrongValue_fails() {
        // `unit` is optional, but if supplied it must be an accepted value.
        let result = ASTMatcher.match(
            call: call("calculate_triangle_area", #"{"base":10,"height":5,"unit":"meters"}"#),
            against: triangleExpected
        )
        XCTAssertFalse(result.matched)
        XCTAssertTrue(hasFailure(result) {
            if case .valueNotAllowed(let p, _, _) = $0 { return p == "unit" }
            return false
        })
    }

    func test_nameMismatch_failsAndStopsEarly() {
        let result = ASTMatcher.match(call: call("subtract", #"{"a":17,"b":4}"#), against: addExpected)
        XCTAssertFalse(result.matched)
        // A name mismatch short-circuits: argument diagnostics for a different
        // function would be misleading, so it is the sole reported failure.
        XCTAssertEqual(result.failures, [.nameMismatch(expected: "add", actual: "subtract")])
    }

    func test_unparseableArguments_fails() {
        let result = ASTMatcher.match(call: call("add", "not json at all"), against: addExpected)
        XCTAssertFalse(result.matched)
        XCTAssertTrue(hasFailure(result) {
            if case .argumentsUnparseable = $0 { return true }
            return false
        })
    }

    func test_multipleFaults_allReported() {
        // Wrong value for 'a' AND missing 'b' — both must be reported in one pass.
        let result = ASTMatcher.match(call: call("add", #"{"a":99}"#), against: addExpected)
        XCTAssertFalse(result.matched)
        XCTAssertEqual(result.failures.count, 2, "expected both a wrong-value and a missing-param failure: \(result.failures)")
    }

    // MARK: - scoreCase (case-level rollup)

    func test_scoreCase_anyEmittedCallMatches() {
        let wrong = call("add", #"{"a":1,"b":1}"#)
        let right = call("add", #"{"a":17,"b":4}"#)
        let score = ASTMatcher.scoreCase(emittedCalls: [wrong, right], groundTruth: [addExpected])
        XCTAssertTrue(score.matched)
        XCTAssertTrue(score.bestFailures.isEmpty)
    }

    func test_scoreCase_noEmittedCalls_failsWithDiagnostic() {
        let score = ASTMatcher.scoreCase(emittedCalls: [], groundTruth: [addExpected])
        XCTAssertFalse(score.matched)
        XCTAssertFalse(score.bestFailures.isEmpty, "a no-call case must explain itself")
    }

    func test_scoreCase_surfacesClosestAttempt() {
        // A name-mismatch attempt (1 failure) and a wrong-value attempt (1 failure):
        // the wrong-value attempt is the more informative "closest" miss.
        let wrongName = call("subtract", #"{"a":17,"b":4}"#)
        let wrongValue = call("add", #"{"a":99,"b":4}"#)
        let score = ASTMatcher.scoreCase(emittedCalls: [wrongName, wrongValue], groundTruth: [addExpected])
        XCTAssertFalse(score.matched)
        XCTAssertTrue(score.bestFailures.contains {
            if case .valueNotAllowed(let p, _, _) = $0 { return p == "a" }
            return false
        }, "closest-attempt diagnostics should point at the wrong argument value, got: \(score.bestFailures)")
    }
}
