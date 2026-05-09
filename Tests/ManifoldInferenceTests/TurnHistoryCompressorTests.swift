import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Unit coverage for ``TurnHistoryCompressor`` (issue #444).
///
/// Coverage:
/// - Pure compressor: short transcript stays untouched, oversize transcript
///   folds older records, recent N preserved verbatim, summary is structured.
///
/// Note: orchestrator-driven prompt-rebuild integration tests were removed
/// alongside the dead `ToolCallLoopOrchestrator` (#947). The compressor's
/// folding/preserving behaviour is fully exercised by the pure tests below;
/// prompt-rebuild round-trips will be re-added against `ConversationRuntime`
/// when that surface adopts compression.
@MainActor
final class TurnHistoryCompressorTests: XCTestCase {

    // MARK: - Fixtures

    private func record(
        step: Int,
        toolName: String,
        args: String,
        result: String
    ) -> TurnHistoryRecord {
        TurnHistoryRecord(
            step: step,
            intermediateTokens: [],
            toolCalls: [ToolCall(id: "c-\(step)", toolName: toolName, arguments: args)],
            toolResults: [ToolResult(callId: "c-\(step)", content: result, errorKind: nil)]
        )
    }

    // MARK: - Pure compressor

    func test_emptyRecords_returnsUnchanged() {
        let c = BudgetTurnHistoryCompressor(characterBudget: 100, preserveRecentTurns: 2)
        let out = c.compress(records: [])
        XCTAssertTrue(out.summary.isEmpty)
        XCTAssertEqual(out.foldedRecords.count, 0)
        XCTAssertEqual(out.preservedRecords.count, 0)
    }

    func test_shortTranscript_underBudget_isUnchanged() {
        let c = BudgetTurnHistoryCompressor(characterBudget: 10_000, preserveRecentTurns: 2)
        let records = (1...3).map { record(step: $0, toolName: "t", args: "{}", result: "small") }
        let out = c.compress(records: records)
        XCTAssertTrue(out.summary.isEmpty, "short transcript must not be compressed; got: \(out.summary)")
        XCTAssertEqual(out.foldedRecords.count, 0)
        XCTAssertEqual(out.preservedRecords.count, 3)
    }

    func test_overBudget_foldsOlderAndPreservesRecentN() {
        // Budget ~ 80 chars; build 6 records of ~50 chars each → way over
        // budget. preserveRecentTurns=2 must keep exactly the last 2.
        let c = BudgetTurnHistoryCompressor(characterBudget: 80, preserveRecentTurns: 2)
        let records = (1...6).map {
            record(step: $0, toolName: "weather", args: #"{"city":"Rome"}"#, result: String(repeating: "x", count: 50))
        }
        let out = c.compress(records: records)

        XCTAssertEqual(out.preservedRecords.count, 2, "must preserve preserveRecentTurns=2 verbatim")
        XCTAssertEqual(out.preservedRecords.first?.step, 5)
        XCTAssertEqual(out.preservedRecords.last?.step, 6)
        XCTAssertEqual(out.foldedRecords.count, 4)
        XCTAssertFalse(out.summary.isEmpty)
        XCTAssertTrue(out.summary.contains("4 rounds"), "summary must report rounds folded; got: \(out.summary)")
    }

    func test_summaryIncludesNotableResults_andStepReferences() {
        // Budget 30 + records of ~50 chars each. Folding stops as soon as
        // the *remaining* suffix fits the budget — this is the right
        // contract for the orchestrator (do as little compression as
        // necessary). With 4 records of ~50 chars each, folding the first
        // 3 brings remaining to ~50 — still over 30 — so all foldable
        // records are folded down to the preserve floor (1).
        let c = BudgetTurnHistoryCompressor(characterBudget: 30, preserveRecentTurns: 1, maxResultExcerpts: 3)
        let big = String(repeating: "x", count: 30)
        let records = [
            record(step: 1, toolName: "weather", args: #"{"city":"Rome"}"#, result: "18C-\(big)"),
            record(step: 2, toolName: "search", args: #"{"q":"swift"}"#, result: "21 hits-\(big)"),
            record(step: 3, toolName: "math", args: "{}", result: "42-\(big)"),
            record(step: 4, toolName: "final", args: "{}", result: "ok"),
        ]
        let out = c.compress(records: records)

        // Step 4 must be preserved verbatim (preserveRecentTurns=1).
        XCTAssertEqual(out.preservedRecords.map(\.step), [4])
        // Earlier steps must be cited by step number in the summary so a
        // later round can still reference "step 2: search → 21 hits".
        XCTAssertTrue(out.summary.contains("step 1"), "summary must cite step 1; got: \(out.summary)")
        XCTAssertTrue(out.summary.contains("18C"), "summary must include weather result; got: \(out.summary)")
        XCTAssertTrue(out.summary.contains("21 hits"), "summary must include search result; got: \(out.summary)")
    }

    func test_idempotent_onAlreadyCompressedSuffix() {
        let c = BudgetTurnHistoryCompressor(characterBudget: 100_000, preserveRecentTurns: 2)
        let records = (1...3).map { record(step: $0, toolName: "t", args: "{}", result: "ok") }
        let first = c.compress(records: records)
        let second = c.compress(records: first.preservedRecords)
        XCTAssertEqual(first.preservedRecords, second.preservedRecords)
        XCTAssertTrue(second.summary.isEmpty)
    }

    func test_noOpCompressor_alwaysReturnsUnchanged() {
        let c = NoOpTurnHistoryCompressor()
        let records = (1...3).map { record(step: $0, toolName: "t", args: "{}", result: "ok") }
        let out = c.compress(records: records)
        XCTAssertEqual(out.preservedRecords, records)
        XCTAssertTrue(out.foldedRecords.isEmpty)
        XCTAssertTrue(out.summary.isEmpty)
    }

    /// Folding operates at record granularity — a record with multiple
    /// (call, result) pairs is always either kept verbatim or folded as a
    /// unit. The orchestrator's loop never splits a call from its result,
    /// because `TurnHistoryRecord` carries them in parallel arrays appended
    /// atomically per round. This guards against regressing into a
    /// per-call fold that would corrupt agent-loop tool pairing.
    func test_multiCallRecord_callsAndResultsStayPaired() {
        let multi = TurnHistoryRecord(
            step: 1,
            intermediateTokens: [],
            toolCalls: [
                ToolCall(id: "a", toolName: "weather", arguments: #"{"city":"Rome"}"#),
                ToolCall(id: "b", toolName: "search", arguments: #"{"q":"swift"}"#),
            ],
            toolResults: [
                ToolResult(callId: "a", content: String(repeating: "x", count: 200), errorKind: nil),
                ToolResult(callId: "b", content: String(repeating: "y", count: 200), errorKind: nil),
            ]
        )
        let tail = (2...3).map { record(step: $0, toolName: "t", args: "{}", result: "ok") }
        let c = BudgetTurnHistoryCompressor(characterBudget: 50, preserveRecentTurns: 2)
        let out = c.compress(records: [multi] + tail)

        // The multi-call record was folded; both its calls are accounted for
        // in the summary (totalCalls == 2) and neither leaked into the
        // preserved suffix without its sibling.
        XCTAssertEqual(out.foldedRecords.count, 1)
        XCTAssertEqual(out.foldedRecords.first?.toolCalls.count, 2)
        XCTAssertEqual(out.foldedRecords.first?.toolResults.count, 2)
        XCTAssertTrue(out.summary.contains("2 tool calls"), "summary must report all calls in the folded round; got: \(out.summary)")
        XCTAssertEqual(out.preservedRecords.count, 2)
    }
}
