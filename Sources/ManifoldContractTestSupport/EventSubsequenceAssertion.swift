#if DEBUG
import XCTest
import ManifoldRuntime

// MARK: - XCTAssertEventSubsequence

/// Asserts that `kinds` appears as a subsequence of `trace`, in order.
///
/// A subsequence match means every kind in `kinds` appears in `trace` (in
/// the same order), but the events do not have to be consecutive. Extra
/// events between matched kinds are ignored.
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
    // Greedy left-to-right scan: advance the `kinds` pointer on each match.
    var kindIdx = kinds.startIndex
    for event in trace {
        guard kindIdx < kinds.endIndex else { break }
        if event.kind == kinds[kindIdx] {
            kindIdx = kinds.index(after: kindIdx)
        }
    }
    if kindIdx < kinds.endIndex {
        let matched = kinds[..<kindIdx].map(\.rawValue).joined(separator: ", ")
        let missing = kinds[kindIdx...].map(\.rawValue).joined(separator: ", ")
        let traceDesc = trace.map(\.kind.rawValue).joined(separator: ", ")
        let detail = message.isEmpty ? "" : " — \(message)"
        XCTFail(
            "Event subsequence not satisfied\(detail).\nMatched: [\(matched)]\nMissing: [\(missing)]\nTrace: [\(traceDesc)]",
            file: file,
            line: line
        )
    }
}
#endif
