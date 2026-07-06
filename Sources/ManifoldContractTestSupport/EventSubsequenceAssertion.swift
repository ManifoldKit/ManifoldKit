import XCTest
import ManifoldRuntime
import ManifoldAppEval

// MARK: - XCTAssertEventSubsequence

/// Asserts that `kinds` appears as a subsequence of `trace`, in order.
///
/// A subsequence match means every kind in `kinds` appears in `trace` (in
/// the same order), but the events do not have to be consecutive. Extra
/// events between matched kinds are ignored.
///
/// Delegates to ``EventSubsequenceChecker`` (ManifoldAppEval) — the pure,
/// XCTest-free implementation of the scan. This function is now a thin
/// XCTest adapter over that checker rather than a second implementation
/// (the two were duplicated before the ManifoldAppEval relocation).
///
/// ```swift,no-build
/// XCTAssertEventSubsequence(trace, contains: [
///     .contextAssembled,
///     .compressionTriggered,
///     .historyCompressed,
///     .contextAssembled,   // subsequence allows a second occurrence
/// ])
/// ```
public func XCTAssertEventSubsequence(
    _ trace: [ConversationEvent],
    contains kinds: [ConversationEventKind],
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let result = EventSubsequenceChecker.check(trace.map(\.kind), against: kinds)
    guard !result.passed, let reason = result.failureReason else { return }
    let detail = message.isEmpty ? "" : " — \(message)"
    XCTFail("Event subsequence not satisfied\(detail).\n\(reason)", file: file, line: line)
}

// MARK: - RuntimeScenarioRunner.assert(result:)

extension RuntimeScenarioRunner {
    /// Calls `XCTFail` if `result.subsequencePassed` is `false`.
    ///
    /// Kept here (rather than on ``RuntimeScenarioRunner`` itself, which is
    /// now XCTest-free in `ManifoldAppEval`) so MK's own test suites keep
    /// calling `RuntimeScenarioRunner.assert(result:)` unchanged.
    public static func assert(
        result: Result,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard !result.subsequencePassed, let reason = result.subsequenceFailureReason else { return }
        XCTFail("Scenario '\(result.scenario.id)' failed: \(reason)", file: file, line: line)
    }
}
