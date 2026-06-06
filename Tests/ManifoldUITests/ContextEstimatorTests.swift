import XCTest
@testable import ManifoldUI
@testable import ManifoldInference

/// Unit tests for the pure `ContextEstimator` struct extracted from
/// `ChatViewModel.updateContextEstimate()`. No ChatViewModel, no persistence.
final class ContextEstimatorTests: XCTestCase {

    // MARK: - Fakes

    /// Call-counting tokenizer with the same ~4 chars/token heuristic used by
    /// `HeuristicTokenizer`. Lets the cache tests assert no redundant work.
    ///
    /// `callCount` is guarded by an NSLock to honor the `@unchecked Sendable`
    /// conformance. Even though the current tests drive this synchronously from
    /// the main actor, leaving the counter unsynchronized would be a latent
    /// Sendable violation if a future test ever calls `tokenCount` off-actor.
    private final class CountingTokenizer: TokenizerProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var _callCount = 0
        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _callCount
        }
        func tokenCount(_ text: String) -> Int {
            lock.lock()
            _callCount += 1
            lock.unlock()
            return max(1, text.count / 4)
        }
    }

    private let sessionID = UUID()

    private func makeMessage(_ content: String, id: UUID = UUID()) -> ChatMessage {
        ChatMessage(id: id, role: .user, content: content, sessionID: sessionID)
    }

    // MARK: - Tests

    func testSingleMessageNoSystemPrompt() {
        let tokenizer = CountingTokenizer()
        let estimator = ContextEstimator()
        let msg = makeMessage("12345678") // 8 chars -> 2 tokens
        let inputs = ContextEstimator.Inputs(
            messages: [msg],
            systemPrompt: "",
            modelContextLength: nil,
            contextSizeOverride: nil,
            backendMaxContextTokens: nil,
            tokenizer: tokenizer,
            cache: [:]
        )

        let result = estimator.estimate(inputs)

        XCTAssertEqual(result.usedTokens, 1 + 2, "empty system prompt tokenizes to 1 + message = 3")
        XCTAssertEqual(result.maxTokens, 2048, "default context size fallback")
        XCTAssertEqual(result.updatedCache[msg.id], 2)
    }

    func testSystemPromptPlusMessagesCountsBoth() {
        let tokenizer = CountingTokenizer()
        let estimator = ContextEstimator()
        let m1 = makeMessage("abcdefgh")      // 8 -> 2
        let m2 = makeMessage("abcdefghijkl")  // 12 -> 3
        let inputs = ContextEstimator.Inputs(
            messages: [m1, m2],
            systemPrompt: "abcdefgh",         // 8 -> 2
            modelContextLength: nil,
            contextSizeOverride: nil,
            backendMaxContextTokens: nil,
            tokenizer: tokenizer,
            cache: [:]
        )

        let result = estimator.estimate(inputs)

        XCTAssertEqual(result.usedTokens, 2 + 2 + 3)
        XCTAssertEqual(result.updatedCache.count, 2)
    }

    func testCacheHitSkipsTokenizer() {
        let tokenizer = CountingTokenizer()
        let estimator = ContextEstimator()
        let m1 = makeMessage("any content here, ignored because cache hit")
        let m2 = makeMessage("also cached, ignored")

        let preloaded: [UUID: Int] = [m1.id: 7, m2.id: 11]
        let inputs = ContextEstimator.Inputs(
            messages: [m1, m2],
            systemPrompt: "",
            modelContextLength: nil,
            contextSizeOverride: nil,
            backendMaxContextTokens: nil,
            tokenizer: tokenizer,
            cache: preloaded
        )

        let result = estimator.estimate(inputs)

        // 1 call for the (empty) system prompt; zero for cached messages.
        XCTAssertEqual(tokenizer.callCount, 1)
        XCTAssertEqual(result.usedTokens, 1 + 7 + 11)
        XCTAssertEqual(result.updatedCache[m1.id], 7)
        XCTAssertEqual(result.updatedCache[m2.id], 11)
    }

    func testCacheMissPopulatesUpdatedCache() {
        let tokenizer = CountingTokenizer()
        let estimator = ContextEstimator()
        let m1 = makeMessage("abcdefgh")     // 2
        let m2 = makeMessage("abcdefghijkl") // 3
        let inputs = ContextEstimator.Inputs(
            messages: [m1, m2],
            systemPrompt: "",
            modelContextLength: nil,
            contextSizeOverride: nil,
            backendMaxContextTokens: nil,
            tokenizer: tokenizer,
            cache: [:]
        )

        let result = estimator.estimate(inputs)

        XCTAssertEqual(result.updatedCache[m1.id], 2)
        XCTAssertEqual(result.updatedCache[m2.id], 3)
        // One call for system prompt + one per uncached message.
        XCTAssertEqual(tokenizer.callCount, 3)
    }

    func testStaleCacheEntriesAreDropped() {
        // Messages that disappeared from the conversation must not linger in the cache.
        let tokenizer = CountingTokenizer()
        let estimator = ContextEstimator()
        let kept = makeMessage("abcd")
        let droppedID = UUID()
        let inputs = ContextEstimator.Inputs(
            messages: [kept],
            systemPrompt: "",
            modelContextLength: nil,
            contextSizeOverride: nil,
            backendMaxContextTokens: nil,
            tokenizer: tokenizer,
            cache: [kept.id: 99, droppedID: 42]
        )

        let result = estimator.estimate(inputs)

        XCTAssertNil(result.updatedCache[droppedID])
        XCTAssertEqual(result.updatedCache[kept.id], 99)
    }

    func testOverrideBeatsModelAndBackend() {
        let estimator = ContextEstimator()
        let inputs = ContextEstimator.Inputs(
            messages: [],
            systemPrompt: "",
            modelContextLength: 4096,
            contextSizeOverride: 8192,
            backendMaxContextTokens: 2048,
            tokenizer: nil,
            cache: [:]
        )
        let result = estimator.estimate(inputs)
        XCTAssertEqual(result.maxTokens, 8192)
    }

    func testModelContextLengthBeatsBackendWhenNoOverride() {
        let estimator = ContextEstimator()
        let inputs = ContextEstimator.Inputs(
            messages: [],
            systemPrompt: "",
            modelContextLength: 4096,
            contextSizeOverride: nil,
            backendMaxContextTokens: 2048,
            tokenizer: nil,
            cache: [:]
        )
        let result = estimator.estimate(inputs)
        XCTAssertEqual(result.maxTokens, 4096)
    }

    func testBackendUsedWhenNothingElseSet() {
        let estimator = ContextEstimator()
        let inputs = ContextEstimator.Inputs(
            messages: [],
            systemPrompt: "",
            modelContextLength: nil,
            contextSizeOverride: nil,
            backendMaxContextTokens: 12345,
            tokenizer: nil,
            cache: [:]
        )
        let result = estimator.estimate(inputs)
        XCTAssertEqual(result.maxTokens, 12345)
    }
}
