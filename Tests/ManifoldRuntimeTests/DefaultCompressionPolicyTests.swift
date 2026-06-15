@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference

/// Unit coverage for the batteries-included compression strategies and the
/// ``DefaultCompressionPolicy`` wrapper. Pure value transforms — no SwiftData,
/// no runtime wiring (that lives in `CompressionPolicyTests`).
final class DefaultCompressionPolicyTests: XCTestCase {

    // MARK: - Fixtures

    private let sessionID = UUID()

    /// Builds a message whose token cost scales with `words`.
    private func msg(_ role: MessageRole, words: Int, kind: MessageKind = .chat) -> ChatMessage {
        let content = Array(repeating: "lorem", count: words).joined(separator: " ")
        return ChatMessage(role: role, content: content, sessionID: sessionID, kind: kind)
    }

    /// Long alternating conversation that overflows `contextSize`.
    private func overflowingHistory(turns: Int = 12, words: Int = 120) -> [ChatMessage] {
        (0..<turns).map { msg($0.isMultiple(of: 2) ? .user : .assistant, words: words) }
    }

    // Sized so the ~2.1k-token fixtures overflow the budget (≈1.5 tok/word
    // under the heuristic tokenizer): contextSize - responseBuffer = 1_536.
    private let contextSize = 2_048
    private func budget() -> Int { max(0, contextSize - 512) }
    private func tokens(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + ContextWindowManager.estimateTokenCount($1.content, tokenizer: nil) }
    }

    private static func echoGenerate(_: [ChatMessage]) async throws -> String {
        "TOPIC: testing\nKEY POINTS: a; b; c\nLAST DISCUSSED: the end"
    }

    // MARK: - Truncating

    func testTruncatingLeavesSmallHistoryUntouched() async throws {
        let history = [msg(.user, words: 5), msg(.assistant, words: 5)]
        let out = try await TruncatingCompressionStrategy().compress(
            history: history, contextSize: contextSize, tokenizer: nil, generate: { _ in "" })
        XCTAssertEqual(out.map(\.id), history.map(\.id))
    }

    func testTruncatingDropsOldestAndKeepsNewest() async throws {
        let history = overflowingHistory()
        XCTAssertGreaterThan(tokens(history), budget())  // precondition: actually overflows

        let out = try await TruncatingCompressionStrategy().compress(
            history: history, contextSize: contextSize, tokenizer: nil, generate: { _ in "" })

        XCTAssertLessThan(out.count, history.count, "expected eviction")
        XCTAssertEqual(out.last?.id, history.last?.id, "newest must survive")
        XCTAssertFalse(out.contains { $0.id == history.first?.id }, "oldest should be dropped")
        XCTAssertLessThanOrEqual(tokens(out), budget())
    }

    /// When load-bearing records alone exhaust the budget, the greedy backward
    /// fill cannot admit the newest chat message — only the explicit
    /// never-drop-newest invariant keeps it. Guards that invariant directly
    /// (the over-budget-tail path the other truncating tests don't exercise).
    func testTruncatingKeepsNewestEvenWhenLoadBearingExceedsBudget() async throws {
        let history = [
            msg(.system, words: 4_000, kind: .chat),   // load-bearing, alone over budget
            msg(.user, words: 5),
            msg(.assistant, words: 5)                    // newest, tiny
        ]
        XCTAssertGreaterThan(tokens([history[0]]), budget(), "precondition: load-bearing alone overflows")

        let out = try await TruncatingCompressionStrategy().compress(
            history: history, contextSize: contextSize, tokenizer: nil, generate: { _ in "" })

        XCTAssertEqual(out.last?.id, history.last?.id, "newest must survive even when load-bearing fills the budget")
        XCTAssertTrue(out.contains { $0.role == .system }, "load-bearing record retained")
    }

    func testTruncatingPreservesLoadBearingRecords() async throws {
        var history = [msg(.system, words: 10, kind: .chat)]            // system role
        history.append(msg(.assistant, words: 10, kind: .memory("summary")))  // memory kind
        history.append(contentsOf: overflowingHistory())

        let out = try await TruncatingCompressionStrategy().compress(
            history: history, contextSize: contextSize, tokenizer: nil, generate: { _ in "" })

        XCTAssertTrue(out.contains { $0.role == .system }, "system prompt must survive")
        XCTAssertTrue(out.contains { if case .memory = $0.kind { return true }; return false },
                      "prior summary must survive")
    }

    // MARK: - Extractive

    func testExtractiveReducesBelowBudgetAndKeepsNewest() async throws {
        let history = overflowingHistory()
        let out = try await ExtractiveCompressionStrategy().compress(
            history: history, contextSize: contextSize, tokenizer: nil, generate: { _ in "" })

        XCTAssertLessThanOrEqual(tokens(out), budget())
        XCTAssertEqual(out.last?.id, history.last?.id)
        XCTAssertEqual(out.map(\.id), out.map(\.id).sorted { a, b in
            (history.firstIndex { $0.id == a } ?? 0) < (history.firstIndex { $0.id == b } ?? 0)
        }, "output must stay chronological")
    }

    func testExtractiveSingleMessageNeverEvicted() async throws {
        let history = [msg(.user, words: 5_000)]  // alone but over budget
        let out = try await ExtractiveCompressionStrategy().compress(
            history: history, contextSize: contextSize, tokenizer: nil, generate: { _ in "" })
        XCTAssertEqual(out.count, 1)
    }

    func testExtractiveHeadBudgetPreservesOldest() async throws {
        let history = overflowingHistory(turns: 16, words: 120)
        let oldestID = history.first!.id

        let withoutHead = try await ExtractiveCompressionStrategy(headBudgetFraction: 0.0).compress(
            history: history, contextSize: contextSize, tokenizer: nil, generate: { _ in "" })
        let withHead = try await ExtractiveCompressionStrategy(headBudgetFraction: 0.30).compress(
            history: history, contextSize: contextSize, tokenizer: nil, generate: { _ in "" })

        // The head knob guarantees the oldest establishing message survives.
        XCTAssertTrue(withHead.contains { $0.id == oldestID }, "head budget must retain the oldest message")
        XCTAssertFalse(withoutHead.contains { $0.id == oldestID }, "without head budget the oldest is evictable")
    }

    // MARK: - Anchored

    func testAnchoredPrependsMemorySummary() async throws {
        let history = overflowingHistory()
        let out = try await AnchoredCompressionStrategy().compress(
            history: history, contextSize: contextSize, tokenizer: nil, generate: Self.echoGenerate)

        let first = try XCTUnwrap(out.first)
        XCTAssertEqual(first.role, .system)
        guard case .memory(let label) = first.kind else {
            return XCTFail("first record must be a .memory summary")
        }
        XCTAssertEqual(label, "summary")
        XCTAssertEqual(out.last?.id, history.last?.id, "verbatim tail preserved")
    }

    func testAnchoredFallsBackToExtractiveWhenGenerateFails() async throws {
        struct Boom: Error {}
        let history = overflowingHistory()
        let out = try await AnchoredCompressionStrategy().compress(
            history: history, contextSize: contextSize, tokenizer: nil,
            generate: { _ in throw Boom() })

        // Fallback produces a reduced history with NO injected summary record.
        XCTAssertFalse(out.contains { if case .memory = $0.kind { return true }; return false })
        XCTAssertLessThanOrEqual(tokens(out), budget())
        XCTAssertFalse(out.isEmpty)
    }

    func testAnchoredFallsBackOnEmptySummary() async throws {
        let history = overflowingHistory()
        let out = try await AnchoredCompressionStrategy().compress(
            history: history, contextSize: contextSize, tokenizer: nil,
            generate: { _ in "   " })
        XCTAssertFalse(out.contains { if case .memory = $0.kind { return true }; return false })
    }

    func testAnchoredWithoutGenerateFallsBack() async throws {
        let history = overflowingHistory()
        let out = try await AnchoredCompressionStrategy().compress(
            history: history, contextSize: contextSize, tokenizer: nil, generate: { _ in "" })
        XCTAssertFalse(out.isEmpty)
        XCTAssertLessThanOrEqual(tokens(out), budget())
    }

    // MARK: - Policy thresholds & seam agreement

    func testShouldCompressHonorsThreshold() {
        let policy = DefaultCompressionPolicy.extractive(threshold: 0.75, contextSize: contextSize)
        XCTAssertTrue(policy.shouldCompress(promptTokens: 0, contextSize: contextSize, contextUtilization: 0.80))
        XCTAssertFalse(policy.shouldCompress(promptTokens: 0, contextSize: contextSize, contextUtilization: 0.50))
        XCTAssertFalse(policy.shouldCompress(promptTokens: 0, contextSize: 0, contextUtilization: 0.99),
                       "unknown context size never compresses")
    }

    func testPreTurnAndPostTurnTriggersAgree() {
        let threshold = 0.80
        let policy = DefaultCompressionPolicy.truncating(threshold: threshold, contextSize: contextSize)

        // Equivalent inputs: promptTokens = 0.85 * contextSize → both should fire.
        let promptTokens = Int(0.85 * Double(contextSize))
        let utilization = Double(promptTokens) / Double(contextSize)

        let postTurn = policy.shouldCompress(
            promptTokens: promptTokens, contextSize: contextSize, contextUtilization: utilization)
        let preTurn = policy.shouldCompressBeforeTurn(messageCount: 99, lastPromptTokens: promptTokens)
        XCTAssertEqual(preTurn, postTurn)
        XCTAssertTrue(preTurn)

        // Below threshold: both decline.
        let lowTokens = Int(0.50 * Double(contextSize))
        XCTAssertEqual(
            policy.shouldCompressBeforeTurn(messageCount: 99, lastPromptTokens: lowTokens),
            policy.shouldCompress(promptTokens: lowTokens, contextSize: contextSize,
                                  contextUtilization: Double(lowTokens) / Double(contextSize)))
    }

    func testPreTurnWithoutPriorTokensDoesNotCompress() {
        let policy = DefaultCompressionPolicy.anchored(threshold: 0.85, contextSize: contextSize)
        XCTAssertFalse(policy.shouldCompressBeforeTurn(messageCount: 500, lastPromptTokens: nil))
    }

    func testPolicyCompressDelegatesToStrategy() async throws {
        let history = overflowingHistory()
        let policy = DefaultCompressionPolicy.anchored(threshold: 0.85, contextSize: contextSize)
        let out = try await policy.compress(history: history, sessionID: sessionID, generate: Self.echoGenerate)
        XCTAssertTrue(out.contains { if case .memory = $0.kind { return true }; return false })

        // compressBeforeTurn shares the same path.
        let preOut = try await policy.compressBeforeTurn(history: history, sessionID: sessionID, generate: Self.echoGenerate)
        XCTAssertEqual(preOut.first?.kind.rawStorage, out.first?.kind.rawStorage)
    }
}
