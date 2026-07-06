import ManifoldRuntime

/// A pure, dependency-free subsequence matcher over ``ConversationEventKind``.
///
/// This is the sole implementation of the "does `expected` appear as an
/// in-order (not-necessarily-contiguous) subsequence of `actual`" check.
/// Before this module existed, the same left-to-right greedy scan was
/// duplicated in two places — ``RuntimeScenarioRunner`` (checking a scenario's
/// `expectedSubsequence`) and `XCTAssertEventSubsequence` in
/// `ManifoldContractTestSupport` (asserting an arbitrary trace) — with no
/// shared source. `ManifoldContractTestSupport`'s `XCTAssertEventSubsequence`
/// now delegates here rather than re-implementing the scan.
public enum EventSubsequenceChecker {

    /// The outcome of a subsequence check — pass/fail plus a diagnostic
    /// message built from the matched prefix, the missing suffix, and the
    /// full trace, so a failing scenario or assertion is debuggable without
    /// re-running it.
    public struct Result: Sendable, Equatable {
        public let passed: Bool
        public let failureReason: String?

        public init(passed: Bool, failureReason: String?) {
            self.passed = passed
            self.failureReason = failureReason
        }
    }

    /// Checks that `expected` appears as an in-order subsequence of `actual`.
    ///
    /// A subsequence match means every kind in `expected` appears in `actual`
    /// (in the same relative order), but the events do not have to be
    /// consecutive — extra events between matched kinds are ignored.
    public static func check(
        _ actual: [ConversationEventKind],
        against expected: [ConversationEventKind]
    ) -> Result {
        var idx = expected.startIndex
        for kind in actual {
            guard idx < expected.endIndex else { break }
            if kind == expected[idx] { idx = expected.index(after: idx) }
        }
        if idx < expected.endIndex {
            let matched = expected[..<idx].map(\.rawValue).joined(separator: ", ")
            let missing = expected[idx...].map(\.rawValue).joined(separator: ", ")
            let traceDesc = actual.map(\.rawValue).joined(separator: ", ")
            return Result(
                passed: false,
                failureReason: "Matched: [\(matched)] — Missing: [\(missing)] — Trace: [\(traceDesc)]"
            )
        }
        return Result(passed: true, failureReason: nil)
    }
}
