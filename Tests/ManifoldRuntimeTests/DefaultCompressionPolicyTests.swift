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

    // The strategy tests inject `reservedTokens` directly, so budget is
    // contextSize - reservedTokens. Keep the historical 512 reserve in the
    // unit tests so the ~2.1k-token fixtures still overflow budget = 1_536.
    private let contextSize = 2_048
    private let reservedTokens = 512
    private func budget() -> Int { max(0, contextSize - reservedTokens) }
    private func tokens(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + ContextWindowManager.estimateTokenCount($1, tokenizer: nil) }
    }

    /// A real (non-nil) tokenizer to exercise the tokenizer-injected path.
    /// Counts whitespace-separated words — deterministic and != the chars/4
    /// heuristic, so a test that passes it really takes the tokenizer branch.
    private struct WordTokenizer: TokenizerProvider {
        func tokenCount(_ text: String) -> Int {
            max(1, text.split(whereSeparator: { $0.isWhitespace }).count)
        }
    }

    private static func echoGenerate(_: [ChatMessage]) async throws -> String {
        "TOPIC: testing\nKEY POINTS: a; b; c\nLAST DISCUSSED: the end"
    }

    /// Lock-guarded capture for `onOutcome`, which is a synchronous
    /// `@Sendable` callback — a plain `var` captured by the closure risks a
    /// Swift 6 concurrency diagnostic, and an `actor` forces the test to add
    /// an arbitrary `Task.sleep` to await the detached recording task. A real
    /// lock (not `@unchecked Sendable` alone) is the sanctioned pattern for a
    /// synchronous escaping-callback capture (AGENTS.md Swift 6 gotcha #2).
    private final class OutcomeCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var _outcome: CompressionOutcome?
        var outcome: CompressionOutcome? {
            lock.lock(); defer { lock.unlock() }
            return _outcome
        }
        func set(_ outcome: CompressionOutcome) {
            lock.lock(); defer { lock.unlock() }
            _outcome = outcome
        }
    }

    // MARK: - Truncating

    func testTruncatingLeavesSmallHistoryUntouched() async throws {
        let history = [msg(.user, words: 5), msg(.assistant, words: 5)]
        let out = try await TruncatingCompressionStrategy().compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in false }, generate: { _ in "" }).messages
        XCTAssertEqual(out.map(\.id), history.map(\.id))
    }

    func testTruncatingDropsOldestAndKeepsNewest() async throws {
        let history = overflowingHistory()
        XCTAssertGreaterThan(tokens(history), budget())  // precondition: actually overflows

        let out = try await TruncatingCompressionStrategy().compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in false }, generate: { _ in "" }).messages

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
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in false }, generate: { _ in "" }).messages

        XCTAssertEqual(out.last?.id, history.last?.id, "newest must survive even when load-bearing fills the budget")
        XCTAssertTrue(out.contains { $0.role == .system }, "load-bearing record retained")
    }

    func testTruncatingPreservesLoadBearingRecords() async throws {
        var history = [msg(.system, words: 10, kind: .chat)]            // system role
        history.append(msg(.assistant, words: 10, kind: .memory("summary")))  // memory kind
        history.append(contentsOf: overflowingHistory())

        let out = try await TruncatingCompressionStrategy().compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in false }, generate: { _ in "" }).messages

        XCTAssertTrue(out.contains { $0.role == .system }, "system prompt must survive")
        XCTAssertTrue(out.contains { if case .memory = $0.kind { return true }; return false },
                      "prior summary must survive")
    }

    /// Real-tokenizer path: a deterministic word tokenizer (not chars/4) must
    /// still reduce below the budget it computes.
    func testTruncatingWithRealTokenizerReducesBelowBudget() async throws {
        let tok = WordTokenizer()
        let history = overflowingHistory(turns: 20, words: 200)
        let out = try await TruncatingCompressionStrategy().compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: tok, isPinned: { _ in false }, generate: { _ in "" }).messages
        let usedWords = out.reduce(0) { $0 + ContextWindowManager.estimateTokenCount($1, tokenizer: tok) }
        XCTAssertLessThanOrEqual(usedWords, budget())
        XCTAssertEqual(out.last?.id, history.last?.id)
    }

    // MARK: - Extractive

    func testExtractiveReducesBelowBudgetAndKeepsNewest() async throws {
        let history = overflowingHistory()
        let out = try await ExtractiveCompressionStrategy().compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in false }, generate: { _ in "" }).messages

        XCTAssertLessThanOrEqual(tokens(out), budget())
        XCTAssertEqual(out.last?.id, history.last?.id)
        // Output must be strictly increasing in original history index — guards
        // chronological order against re-ordering (not a self-sort tautology).
        let indices = out.map { m in history.firstIndex { $0.id == m.id }! }
        XCTAssertEqual(indices, indices.sorted(), "output indices must be sorted")
        for i in 1..<indices.count {
            XCTAssertLessThan(indices[i - 1], indices[i], "indices strictly increasing (no dupes/reorder)")
        }
    }

    func testExtractiveSingleMessageNeverEvicted() async throws {
        let history = [msg(.user, words: 5_000)]  // alone but over budget
        let out = try await ExtractiveCompressionStrategy().compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in false }, generate: { _ in "" }).messages
        XCTAssertEqual(out.count, 1)
    }

    func testExtractiveHeadBudgetPreservesOldest() async throws {
        let history = overflowingHistory(turns: 16, words: 120)
        let oldestID = history.first!.id

        let withoutHead = try await ExtractiveCompressionStrategy(headBudgetFraction: 0.0).compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in false }, generate: { _ in "" }).messages
        let withHead = try await ExtractiveCompressionStrategy(headBudgetFraction: 0.30).compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in false }, generate: { _ in "" }).messages

        // The head knob guarantees the oldest establishing message survives.
        XCTAssertTrue(withHead.contains { $0.id == oldestID }, "head budget must retain the oldest message")
        XCTAssertFalse(withoutHead.contains { $0.id == oldestID }, "without head budget the oldest is evictable")
    }

    /// Finding 2: tail (0.40) + head must not let the verbatim core exceed the
    /// budget. Pass head 0.6 so head+tail = 1.0 (clamped to 0.8) and confirm
    /// the result still fits.
    func testExtractiveVerbatimCoreNeverExceedsBudget() async throws {
        let history = overflowingHistory(turns: 24, words: 120)
        let out = try await ExtractiveCompressionStrategy(
            tailBudgetFraction: 0.40, headBudgetFraction: 0.60  // sums to 1.0 → clamped
        ).compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in false }, generate: { _ in "" }).messages
        XCTAssertLessThanOrEqual(tokens(out), budget(), "verbatim core must be clamped under budget")
        XCTAssertEqual(out.last?.id, history.last?.id, "newest always survives")
        XCTAssertFalse(out.isEmpty)
    }

    /// `headBudgetFraction` at the 1.0 boundary: clamp keeps the union ≤ budget.
    func testExtractiveHeadFractionAtOneBoundary() async throws {
        let history = overflowingHistory(turns: 24, words: 120)
        let out = try await ExtractiveCompressionStrategy(
            tailBudgetFraction: 0.40, headBudgetFraction: 1.0
        ).compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in false }, generate: { _ in "" }).messages
        XCTAssertLessThanOrEqual(tokens(out), budget())
        XCTAssertEqual(out.last?.id, history.last?.id)
    }

    /// All-load-bearing history: every message is `.system`, so all are pinned
    /// and the over-budget final pass cannot evict them — result equals input.
    func testExtractiveAllMessagesLoadBearing() async throws {
        let history = (0..<10).map { _ in msg(.system, words: 200) }
        XCTAssertGreaterThan(tokens(history), budget())
        let out = try await ExtractiveCompressionStrategy().compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in false }, generate: { _ in "" }).messages
        XCTAssertEqual(Set(out.map(\.id)), Set(history.map(\.id)),
                       "load-bearing records are never evicted even over budget")
    }

    func testExtractiveWithRealTokenizerReducesBelowBudget() async throws {
        let tok = WordTokenizer()
        let history = overflowingHistory(turns: 20, words: 200)
        let out = try await ExtractiveCompressionStrategy().compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: tok, isPinned: { _ in false }, generate: { _ in "" }).messages
        let usedWords = out.reduce(0) { $0 + ContextWindowManager.estimateTokenCount($1, tokenizer: tok) }
        XCTAssertLessThanOrEqual(usedWords, budget())
    }

    // MARK: - Anchored

    func testAnchoredPrependsMemorySummary() async throws {
        let history = overflowingHistory()
        let out = try await AnchoredCompressionStrategy().compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in false }, generate: Self.echoGenerate).messages

        let first = try XCTUnwrap(out.first)
        XCTAssertEqual(first.role, .system)
        guard case .memory(let label) = first.kind else {
            return XCTFail("first record must be a .memory summary")
        }
        XCTAssertEqual(label, "summary")
        XCTAssertEqual(out.last?.id, history.last?.id, "verbatim tail preserved")
        // Old messages were dropped and the result fits the budget.
        XCTAssertLessThan(out.count, history.count, "old messages must be dropped")
        XCTAssertLessThanOrEqual(tokens(out), budget())
    }

    func testAnchoredFallsBackToExtractiveWhenGenerateFails() async throws {
        struct Boom: Error {}
        let history = overflowingHistory()
        let out = try await AnchoredCompressionStrategy().compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in false }, generate: { _ in throw Boom() }).messages

        // Fallback produces a reduced history with NO injected summary record.
        XCTAssertFalse(out.contains { if case .memory = $0.kind { return true }; return false })
        XCTAssertLessThanOrEqual(tokens(out), budget())
        XCTAssertFalse(out.isEmpty)
    }

    func testAnchoredFallsBackOnEmptySummary() async throws {
        let history = overflowingHistory()
        let out = try await AnchoredCompressionStrategy().compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in false }, generate: { _ in "   " }).messages
        XCTAssertFalse(out.contains { if case .memory = $0.kind { return true }; return false })
    }

    /// Empty `generate` (no usable summariser) must fall back, NOT inject an
    /// empty `.memory` record.
    func testAnchoredWithoutGenerateFallsBack() async throws {
        let history = overflowingHistory()
        let out = try await AnchoredCompressionStrategy().compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in false }, generate: { _ in "" }).messages
        XCTAssertFalse(out.isEmpty)
        XCTAssertFalse(out.contains { if case .memory = $0.kind { return true }; return false },
                       "empty summariser must NOT inject a memory record")
        XCTAssertLessThanOrEqual(tokens(out), budget())
    }

    /// Leaked chain-of-thought must be stripped before parsing — the
    /// `<think>` scratchpad must not appear in the summary record.
    func testAnchoredStripsLeakedThinkingFromSummary() async throws {
        let history = overflowingHistory()
        let leaky: @Sendable ([ChatMessage]) async throws -> String = { _ in
            "<think>I should mention SECRET_LEAK while reasoning</think>\nTOPIC: testing\nKEY POINTS: a; b; c"
        }
        let out = try await AnchoredCompressionStrategy().compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in false }, generate: leaky).messages
        let summary = try XCTUnwrap(out.first)
        XCTAssertFalse(summary.content.contains("SECRET_LEAK"), "thinking must be stripped")
        XCTAssertFalse(summary.content.contains("<think>"))
        XCTAssertTrue(summary.content.contains("TOPIC"), "visible fields survive")
    }

    /// Chunk-and-fold: oldText exceeds the usable summariser input window, so
    /// the strategy chunks. `generate` records every prompt; assert ≥2 calls
    /// and that content from the OLDEST chunk is represented in the brief.
    func testAnchoredChunkAndFold() async throws {
        actor PromptRecorder {
            var prompts: [String] = []
            func record(_ p: String) { prompts.append(p) }
        }
        let recorder = PromptRecorder()
        let history = overflowingHistory(turns: 30, words: 120)
        // First message carries a unique marker we can trace to the oldest chunk.
        var tagged = history
        tagged[0] = ChatMessage(role: .user, content: "OLDEST_MARKER " + history[0].content, sessionID: sessionID)

        let generate: @Sendable ([ChatMessage]) async throws -> String = { msgs in
            let prompt = msgs.first?.content ?? ""
            await recorder.record(prompt)
            // Echo back any marker the chunk contained so it reaches the fold.
            if prompt.contains("OLDEST_MARKER") {
                return "TOPIC: oldest\nKEY POINTS: OLDEST_MARKER seen; b; c"
            }
            return "TOPIC: chunk\nKEY POINTS: a; b; c"
        }

        // summarizerInputWindow small enough that old text exceeds the usable budget.
        let out = try await AnchoredCompressionStrategy(
            summarizerResponseBuffer: 64, summarizerInputWindow: 600
        ).compress(
            history: tagged, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in false }, generate: generate).messages

        let calls = await recorder.prompts
        XCTAssertGreaterThanOrEqual(calls.count, 2, "chunking should produce ≥2 generate calls (chunks + fold)")
        let summary = try XCTUnwrap(out.first)
        guard case .memory = summary.kind else { return XCTFail("expected memory summary") }
        XCTAssertTrue(summary.content.contains("OLDEST_MARKER") || calls.contains { $0.contains("OLDEST_MARKER") },
                      "oldest chunk content must be represented")
    }

    /// Chunk-failure: the FIRST chunk's `generate` throws → that chunk's raw
    /// content is preserved via the truncated-text fallback (not lost), and the
    /// overall compression still produces a `.memory` summary because the fold
    /// (a later call) succeeds.
    func testAnchoredChunkFailurePreservesContent() async throws {
        actor CallCounter { var n = 0; func next() -> Int { n += 1; return n } }
        let counter = CallCounter()
        let history = overflowingHistory(turns: 30, words: 120)
        var tagged = history
        tagged[0] = ChatMessage(role: .user, content: "OLDEST_MARKER " + history[0].content, sessionID: sessionID)

        // Throw on the first generate call (a chunk), succeed on all later calls
        // (remaining chunks + the fold). The first chunk's raw text falls back
        // via truncateToFit so its content is not dropped.
        let generate: @Sendable ([ChatMessage]) async throws -> String = { _ in
            struct ChunkBoom: Error {}
            if await counter.next() == 1 { throw ChunkBoom() }
            return "TOPIC: chunk\nKEY POINTS: a; b; c"
        }
        let out = try await AnchoredCompressionStrategy(
            summarizerResponseBuffer: 64, summarizerInputWindow: 600
        ).compress(
            history: tagged, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in false }, generate: generate).messages
        // The summary record exists (top-level summarise succeeded on the fold).
        let summary = try XCTUnwrap(out.first)
        guard case .memory = summary.kind else { return XCTFail("expected memory summary despite chunk failure") }
        let totalCalls = await counter.n
        XCTAssertGreaterThanOrEqual(totalCalls, 2, "should retry remaining chunks + fold after one chunk failed")
        XCTAssertFalse(out.isEmpty)
    }

    /// Summary-floor: the tail consumes ~the whole budget, leaving no room for
    /// the summary. The strategy must still emit a non-empty `.memory` record
    /// AND keep the result within budget.
    func testAnchoredSummaryFloor() async throws {
        // tailBudgetFraction 0.95 → tail eats almost all budget.
        let history = overflowingHistory(turns: 20, words: 120)
        let out = try await AnchoredCompressionStrategy(tailBudgetFraction: 0.95).compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in false }, generate: Self.echoGenerate).messages
        let summary = try XCTUnwrap(out.first)
        guard case .memory = summary.kind else { return XCTFail("expected floored memory summary") }
        XCTAssertFalse(summary.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "summary floor must produce a non-empty brief")
        XCTAssertLessThanOrEqual(tokens(out), budget())
    }

    /// Cancellation mid-summarise: cancelling the surrounding Task returns the
    /// tail with NO summary record.
    func testAnchoredCancellationMidSummarize() async throws {
        let history = overflowingHistory()
        // Hoist instance properties to locals so the Task closure doesn't
        // capture (non-Sendable) `self`.
        let ctx = contextSize
        let reserve = reservedTokens
        let task = Task { () -> StrategyCompressionResult in
            try await AnchoredCompressionStrategy().compress(
                history: history, contextSize: ctx, reservedTokens: reserve,
                tokenizer: nil, isPinned: { _ in false },
                generate: { _ in
                    // Yield so cancellation lands before/within summarise.
                    try await Task.sleep(nanoseconds: 50_000_000)
                    return "TOPIC: x\nKEY POINTS: a; b"
                })
        }
        task.cancel()
        let result = try await task.value
        let out = result.messages
        XCTAssertFalse(out.contains { if case .memory = $0.kind { return true }; return false },
                       "cancellation must not inject a summary record")
        XCTAssertEqual(out.last?.id, history.last?.id, "tail preserved on cancel")
        XCTAssertEqual(result.outcome, .cancelled, "outcome must classify as cancelled (#2203)")
    }

    /// `parseSummaryResponse` <2-field raw-fallback branch: a summary with only
    /// one recognisable field degrades to the trimmed raw response, not an
    /// empty/placeholder brief.
    func testAnchoredSingleFieldRawFallback() async throws {
        let history = overflowingHistory()
        let oneField: @Sendable ([ChatMessage]) async throws -> String = { _ in
            "TOPIC: only one field here and some prose that should survive verbatim"
        }
        let out = try await AnchoredCompressionStrategy().compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in false }, generate: oneField).messages
        let summary = try XCTUnwrap(out.first)
        guard case .memory = summary.kind else { return XCTFail("expected memory summary") }
        XCTAssertTrue(summary.content.contains("prose that should survive"),
                      "single-field response degrades to trimmed raw text")
    }

    // MARK: - parseSummaryResponse / stripThinking caching correctness

    /// `parseSummaryResponse` must produce the same field extraction regardless
    /// of whether the regex is freshly compiled or read from the static cache.
    /// Calling it multiple times on the same input is the minimal proof that the
    /// cached regex returns byte-identical results to the inline compile.
    func testParseSummaryResponseIsIdempotent() async throws {
        let history = overflowingHistory()
        let fixedResponse = "TOPIC: caching\nKEY POINTS: a; b; c\nLAST DISCUSSED: the test"
        let generate: @Sendable ([ChatMessage]) async throws -> String = { _ in fixedResponse }
        // Run twice: the first call warms the static cache, the second exercises it.
        let out1 = try await AnchoredCompressionStrategy().compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in false }, generate: generate).messages
        let out2 = try await AnchoredCompressionStrategy().compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in false }, generate: generate).messages
        let summary1 = try XCTUnwrap(out1.first)
        let summary2 = try XCTUnwrap(out2.first)
        XCTAssertEqual(summary1.content, summary2.content,
                       "cached regex must produce byte-identical output on repeated calls")
        XCTAssertTrue(summary1.content.contains("TOPIC"), "field extraction survived caching")
    }

    /// `stripThinking` must produce the same visible text whether the
    /// `ThinkingTransform` instances come from the static cache or are freshly
    /// constructed — the struct copy-on-use semantics must reset mutable state.
    func testStripThinkingCachingProducesSameOutput() async throws {
        let history = overflowingHistory()
        // Two consecutive calls with thinking markers: each call must get a fresh
        // copy of the transform struct, so the second call doesn't carry over
        // depth/buffer state from the first.
        let leaky: @Sendable ([ChatMessage]) async throws -> String = { _ in
            "<think>scratchpad A</think>\nTOPIC: reuse\nKEY POINTS: x; y; z"
        }
        let out1 = try await AnchoredCompressionStrategy().compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in false }, generate: leaky).messages
        let out2 = try await AnchoredCompressionStrategy().compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in false }, generate: leaky).messages
        let s1 = try XCTUnwrap(out1.first)
        let s2 = try XCTUnwrap(out2.first)
        XCTAssertEqual(s1.content, s2.content,
                       "cached ThinkingTransform copies must produce byte-identical output")
        XCTAssertFalse(s1.content.contains("scratchpad A"),
                       "thinking content must be stripped on both calls")
        XCTAssertTrue(s1.content.contains("TOPIC"),
                      "visible summary fields must survive stripping")
    }

    // MARK: - Policy thresholds & seam agreement

    func testShouldCompressHonorsThreshold() {
        let policy = DefaultCompressionPolicy.extractive(threshold: 0.75, contextSize: contextSize)
        XCTAssertTrue(policy.shouldCompress(promptTokens: 0, contextSize: contextSize, contextUtilization: 0.80))
        XCTAssertFalse(policy.shouldCompress(promptTokens: 0, contextSize: contextSize, contextUtilization: 0.50))
        XCTAssertFalse(policy.shouldCompress(promptTokens: 0, contextSize: 0, contextUtilization: 0.99),
                       "unknown context size never compresses")
    }

    /// Trigger boundary, hand-computed. Both seams fire at exactly the
    /// threshold and decline just below it; and the rounding asymmetry where a
    /// post-turn caller passing a rounded utilisation fires while the pre-turn
    /// recompute from raw tokens stays below.
    func testTriggerAsymmetryBoundary() {
        let threshold = 0.80
        let policy = DefaultCompressionPolicy.truncating(threshold: threshold, contextSize: contextSize)

        // promptTokens chosen so utilisation == threshold exactly.
        let atTokens = Int(threshold * Double(contextSize))  // 0.80 * 2048 = 1638 (1638/2048 = 0.7998…)
        // At the exact integer-token boundary the recomputed utilisation may be
        // a hair below threshold; assert both seams agree with the hand-computed
        // recompute regardless.
        let atUtil = Double(atTokens) / Double(contextSize)
        let preAt = policy.shouldCompressBeforeTurn(messageCount: 1, lastPromptTokens: atTokens)
        let postAt = policy.shouldCompress(promptTokens: atTokens, contextSize: contextSize, contextUtilization: atUtil)
        XCTAssertEqual(preAt, postAt)
        XCTAssertEqual(preAt, atUtil >= threshold, "pre-turn matches hand-computed bool at boundary")

        // threshold − epsilon: definitively below → both decline.
        let belowTokens = Int((threshold - 0.01) * Double(contextSize))
        let belowUtil = Double(belowTokens) / Double(contextSize)
        XCTAssertFalse(policy.shouldCompressBeforeTurn(messageCount: 1, lastPromptTokens: belowTokens))
        XCTAssertFalse(policy.shouldCompress(promptTokens: belowTokens, contextSize: contextSize, contextUtilization: belowUtil))

        // Rounding asymmetry: a post-turn caller that ROUNDS utilisation up to
        // the threshold fires, while the pre-turn recompute from raw tokens
        // (which is just under) does not. Demonstrates the documented seam gap.
        let justUnderTokens = Int(threshold * Double(contextSize)) - 1  // 1637/2048 = 0.79931 < 0.80
        let recomputed = Double(justUnderTokens) / Double(contextSize)
        XCTAssertLessThan(recomputed, threshold, "raw recompute is below threshold")
        let preJustUnder = policy.shouldCompressBeforeTurn(messageCount: 1, lastPromptTokens: justUnderTokens)
        let postRounded = policy.shouldCompress(promptTokens: justUnderTokens, contextSize: contextSize,
                                                contextUtilization: threshold)  // caller passes rounded value
        XCTAssertFalse(preJustUnder, "pre-turn recompute declines just below threshold")
        XCTAssertTrue(postRounded, "post-turn fires when caller passes a utilisation already at threshold")
    }

    func testPreTurnWithoutPriorTokensDoesNotCompress() {
        let policy = DefaultCompressionPolicy.anchored(threshold: 0.85, contextSize: contextSize)
        XCTAssertFalse(policy.shouldCompressBeforeTurn(messageCount: 500, lastPromptTokens: nil))
    }

    func testPolicyCompressDelegatesToStrategy() async throws {
        // Context comfortably above the default 2048 reserve so the policy's
        // small-window guard doesn't skip; history overflows the resulting budget.
        let largeContext = 8_192
        let history = overflowingHistory(turns: 80, words: 120)
        let policy = DefaultCompressionPolicy.anchored(threshold: 0.85, contextSize: largeContext)
        let out = try await policy.compress(history: history, sessionID: sessionID, generate: Self.echoGenerate)
        XCTAssertTrue(out.contains { if case .memory = $0.kind { return true }; return false })

        // compressBeforeTurn shares the same path.
        let preOut = try await policy.compressBeforeTurn(history: history, sessionID: sessionID, generate: Self.echoGenerate)
        XCTAssertEqual(preOut.first?.kind.rawStorage, out.first?.kind.rawStorage)
    }

    /// Finding 1 guard: a context window at or below the reservation has no
    /// usable history budget; the policy must skip compression (return history
    /// unchanged) rather than churn against a zero/negative budget.
    func testPolicySkipsWhenContextSmallerThanReserve() async throws {
        // 512-token simulator cap with the default 2048 reserve.
        let policy = DefaultCompressionPolicy.truncating(contextSize: 512)
        let history = overflowingHistory()
        let out = try await policy.compress(history: history, sessionID: sessionID, generate: { _ in "" })
        XCTAssertEqual(out.map(\.id), history.map(\.id), "no usable budget → history unchanged")
    }

    /// The default reserve is clearly larger than the legacy 512.
    func testDefaultReserveIsLargerThanLegacy() {
        XCTAssertGreaterThan(DefaultCompressionPolicy.defaultReservedTokens, 512)
    }

    /// Context-scaled reserve grows with the window but stays under half of it.
    func testScaledReserveBounds() {
        let small = DefaultCompressionPolicy.scaledReservedTokens(forContextSize: 4_096)
        XCTAssertGreaterThanOrEqual(small, DefaultCompressionPolicy.defaultReservedTokens)
        let large = DefaultCompressionPolicy.scaledReservedTokens(forContextSize: 131_072)
        XCTAssertEqual(large, 131_072 / 8, "scales to ~12.5% of a big window")
        XCTAssertLessThanOrEqual(large, 131_072 / 2, "never exceeds half the window")
    }

    // MARK: - Outcome metadata (#2203)

    /// Success path: the anchored strategy actually summarised. `onOutcome`
    /// must report `.summarized` with a positive token estimate — not a
    /// generic "it worked" flag.
    func testOutcomeSummarizedOnSuccess() async throws {
        let largeContext = 8_192
        let history = overflowingHistory(turns: 80, words: 120)
        let capture = OutcomeCapture()
        let policy = DefaultCompressionPolicy.anchored(
            threshold: 0.85, contextSize: largeContext,
            onOutcome: { capture.set($0) }
        )
        _ = try await policy.compress(history: history, sessionID: sessionID, generate: Self.echoGenerate)
        guard case .summarized(let tokens) = capture.outcome else {
            return XCTFail("expected .summarized outcome, got \(String(describing: capture.outcome))")
        }
        XCTAssertGreaterThan(tokens, 0, "summarized outcome must report a positive token estimate")
    }

    /// The summariser call throws a non-cancellation error: outcome must be
    /// `.fallbackUsed(.summarizerThrew)`, not misreported as any other case
    /// (the #910 classification bug this issue targets).
    func testOutcomeFallbackUsedWhenGenerateThrows() async throws {
        struct Boom: Error {}
        let capture = OutcomeCapture()
        let policy = DefaultCompressionPolicy.anchored(
            threshold: 0.85, contextSize: contextSize, reservedTokens: reservedTokens,
            onOutcome: { capture.set($0) }
        )
        _ = try await policy.compress(
            history: overflowingHistory(), sessionID: sessionID,
            generate: { _ in throw Boom() }
        )
        XCTAssertEqual(capture.outcome, .fallbackUsed(reason: .summarizerThrew))
    }

    /// An empty/blank summary (including the "no usable summariser" no-op)
    /// must report `.fallbackUsed(.emptySummary)`.
    func testOutcomeFallbackUsedOnEmptySummary() async throws {
        let capture = OutcomeCapture()
        let policy = DefaultCompressionPolicy.anchored(
            threshold: 0.85, contextSize: contextSize, reservedTokens: reservedTokens,
            onOutcome: { capture.set($0) }
        )
        _ = try await policy.compress(
            history: overflowingHistory(), sessionID: sessionID,
            generate: { _ in "   " }
        )
        XCTAssertEqual(capture.outcome, .fallbackUsed(reason: .emptySummary))
    }

    /// Ambient `Task` cancellation before summarisation starts must surface as
    /// `.cancelled` — the #910 bug reported this as a fallback instead.
    func testOutcomeCancelledOnAmbientCancellation() async throws {
        let ctx = contextSize
        let reserve = reservedTokens
        let capture = OutcomeCapture()
        let history = overflowingHistory()
        let sid = sessionID
        let task = Task { () -> [ChatMessage] in
            let policy = DefaultCompressionPolicy.anchored(
                threshold: 0.85, contextSize: ctx, reservedTokens: reserve,
                onOutcome: { capture.set($0) }
            )
            return try await policy.compress(
                history: history, sessionID: sid,
                generate: { _ in
                    try await Task.sleep(nanoseconds: 50_000_000)
                    return "TOPIC: x\nKEY POINTS: a; b"
                }
            )
        }
        task.cancel()
        _ = try await task.value
        XCTAssertEqual(capture.outcome, .cancelled)
    }

    /// The injected `generate` closure directly throwing `CancellationError`
    /// (not ambient `Task` cancellation) must ALSO surface as `.cancelled` —
    /// the second half of the #2203 acceptance criterion.
    func testOutcomeCancelledOnGenerateThrownCancellationError() async throws {
        let capture = OutcomeCapture()
        let policy = DefaultCompressionPolicy.anchored(
            threshold: 0.85, contextSize: contextSize, reservedTokens: reservedTokens,
            onOutcome: { capture.set($0) }
        )
        _ = try await policy.compress(
            history: overflowingHistory(), sessionID: sessionID,
            generate: { _ in throw CancellationError() }
        )
        XCTAssertEqual(capture.outcome, .cancelled)
    }

    /// `contextSize <= reservedTokens`: the policy skips the strategy
    /// entirely. Outcome must be `.skippedInsufficientBudget`, distinct from
    /// every strategy-produced outcome (the #910 bug conflated this with
    /// fallback).
    func testOutcomeSkippedInsufficientBudget() async throws {
        let capture = OutcomeCapture()
        let policy = DefaultCompressionPolicy.truncating(
            contextSize: 512, onOutcome: { capture.set($0) }
        )
        let history = overflowingHistory()
        let out = try await policy.compress(history: history, sessionID: sessionID, generate: { _ in "" })
        XCTAssertEqual(capture.outcome, .skippedInsufficientBudget)
        XCTAssertEqual(out.map(\.id), history.map(\.id), "history unchanged on skip")
    }

    /// Every input message load-bearing (all `.system`): nothing was eligible
    /// to summarize. Outcome must be `.nothingToSummarize`, not a failure —
    /// the third #910 classification bug.
    func testOutcomeNothingToSummarizeAllLoadBearing() async throws {
        let capture = OutcomeCapture()
        let policy = DefaultCompressionPolicy.anchored(
            threshold: 0.85, contextSize: contextSize, reservedTokens: reservedTokens,
            onOutcome: { capture.set($0) }
        )
        let history = (0..<10).map { _ in msg(.system, words: 200) }
        XCTAssertGreaterThan(tokens(history), budget(), "precondition: over budget")
        _ = try await policy.compress(history: history, sessionID: sessionID, generate: Self.echoGenerate)
        XCTAssertEqual(capture.outcome, .nothingToSummarize)
    }

    /// Zero-inference strategies report `.reduced(strategyName:)` when they
    /// actually evict messages — distinct from `.summarized`/`.fallbackUsed`,
    /// which only apply to the anchored strategy.
    func testOutcomeReducedForTruncatingAndExtractive() async throws {
        let truncatingCapture = OutcomeCapture()
        let truncatingPolicy = DefaultCompressionPolicy.truncating(
            contextSize: contextSize, reservedTokens: reservedTokens,
            onOutcome: { truncatingCapture.set($0) }
        )
        _ = try await truncatingPolicy.compress(history: overflowingHistory(), sessionID: sessionID, generate: { _ in "" })
        XCTAssertEqual(truncatingCapture.outcome, .reduced(strategyName: "truncating"))

        let extractiveCapture = OutcomeCapture()
        let extractivePolicy = DefaultCompressionPolicy.extractive(
            contextSize: contextSize, reservedTokens: reservedTokens,
            onOutcome: { extractiveCapture.set($0) }
        )
        _ = try await extractivePolicy.compress(history: overflowingHistory(), sessionID: sessionID, generate: { _ in "" })
        XCTAssertEqual(extractiveCapture.outcome, .reduced(strategyName: "extractive"))
    }

    /// History already fits the budget: the guard in `shouldCompress` would
    /// normally prevent this call, but a direct `compress` call (or a custom
    /// policy with a looser trigger) must still report `.notNeeded` rather
    /// than silently pretending a reduction happened.
    func testOutcomeNotNeededWhenHistoryFits() async throws {
        let capture = OutcomeCapture()
        let policy = DefaultCompressionPolicy.truncating(
            contextSize: contextSize, reservedTokens: reservedTokens,
            onOutcome: { capture.set($0) }
        )
        let smallHistory = [msg(.user, words: 5), msg(.assistant, words: 5)]
        let out = try await policy.compress(history: smallHistory, sessionID: sessionID, generate: { _ in "" })
        XCTAssertEqual(capture.outcome, .notNeeded)
        XCTAssertEqual(out.map(\.id), smallHistory.map(\.id))
    }

    // MARK: - Pinning (#2204)

    /// A pinned message that is neither `.system`-role nor `.memory`-kind
    /// must survive truncating compression — the whole point of a dedicated
    /// pin predicate instead of squatting on `.memory`.
    func testTruncatingHonorsPinPredicate() async throws {
        var history = overflowingHistory(turns: 12, words: 120)
        let pinnedID = history[2].id  // an old, otherwise-evictable message
        var pinned = history[2]
        pinned.kind = .chat  // explicitly NOT .memory — pin must not require kind mutation
        history[2] = pinned

        let out = try await TruncatingCompressionStrategy().compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { $0.id == pinnedID }, generate: { _ in "" }
        ).messages

        XCTAssertTrue(out.contains { $0.id == pinnedID }, "pinned message must survive truncating compression")
        guard let survivor = out.first(where: { $0.id == pinnedID }) else {
            return XCTFail("pinned message missing from output")
        }
        guard case .chat = survivor.kind else {
            return XCTFail("pin must not have mutated kind to .memory")
        }
    }

    /// Same guarantee for the extractive strategy.
    func testExtractiveHonorsPinPredicate() async throws {
        var history = overflowingHistory(turns: 12, words: 120)
        let pinnedID = history[2].id
        var pinned = history[2]
        pinned.kind = .chat
        history[2] = pinned

        let out = try await ExtractiveCompressionStrategy().compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { $0.id == pinnedID }, generate: { _ in "" }
        ).messages

        XCTAssertTrue(out.contains { $0.id == pinnedID }, "pinned message must survive extractive compression")
    }

    /// Pin survival under budget starvation: even when load-bearing +
    /// pinned records alone exceed the tail budget, the pinned message must
    /// not be evicted (mirrors the existing `.memory`/`.system` guarantee).
    func testAnchoredHonorsPinPredicateUnderStarvation() async throws {
        var history = overflowingHistory(turns: 20, words: 120)
        let pinnedID = history[3].id
        var pinned = history[3]
        pinned.kind = .chat
        history[3] = pinned

        let out = try await AnchoredCompressionStrategy(tailBudgetFraction: 0.05).compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { $0.id == pinnedID }, generate: Self.echoGenerate
        ).messages

        XCTAssertTrue(out.contains { $0.id == pinnedID }, "pinned message must survive even under tail-budget starvation")
    }

    /// All-pinned edge case: every message pinned via the predicate (none
    /// `.system`/`.memory`) must all survive, mirroring the existing
    /// all-load-bearing behavior for `.system`/`.memory` records.
    func testExtractiveAllMessagesPinned() async throws {
        let history = (0..<10).map { _ in msg(.user, words: 200) }
        XCTAssertGreaterThan(tokens(history), budget(), "precondition: over budget")
        let out = try await ExtractiveCompressionStrategy().compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { _ in true }, generate: { _ in "" }
        ).messages
        XCTAssertEqual(Set(out.map(\.id)), Set(history.map(\.id)),
                       "all-pinned records are never evicted even over budget")
    }

    /// A pin is distinguishable from an MK-emitted `.memory("summary")`
    /// record: pinning a `.chat`-kind message must not retag it as `.memory`,
    /// and a real summary record must still carry the `.memory("summary")`
    /// kind untouched by the pin predicate.
    func testPinIsDistinguishableFromMemoryKind() async throws {
        var history = overflowingHistory(turns: 20, words: 120)
        let pinnedID = history[3].id
        var pinned = history[3]
        pinned.kind = .chat
        history[3] = pinned

        let out = try await AnchoredCompressionStrategy().compress(
            history: history, contextSize: contextSize, reservedTokens: reservedTokens,
            tokenizer: nil, isPinned: { $0.id == pinnedID }, generate: Self.echoGenerate
        ).messages

        guard let survivor = out.first(where: { $0.id == pinnedID }) else {
            return XCTFail("pinned message missing from output")
        }
        guard case .chat = survivor.kind else {
            return XCTFail("pinned .chat message must not be retagged as .memory")
        }
        // The strategy's own summary record is still tagged .memory("summary").
        guard let summary = out.first(where: { if case .memory = $0.kind { return true }; return false }) else {
            return XCTFail("expected the strategy's own .memory(\"summary\") record to also be present")
        }
        guard case .memory(let label) = summary.kind else {
            return XCTFail("expected .memory kind")
        }
        XCTAssertEqual(label, "summary")
    }
}
