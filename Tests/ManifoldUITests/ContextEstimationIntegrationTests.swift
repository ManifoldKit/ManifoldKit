@preconcurrency import XCTest
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport
import ManifoldPersistenceTestSupport
// BackendInternals SPI: seam published for the companion split (#1749).
@_spi(BackendInternals) import ManifoldContract

/// Integration tests for context estimation using REAL HeuristicTokenizer and
/// ContextWindowManager with no mocks on the computation path.
///
/// Only the inference backend is mocked (MockInferenceBackend). Token estimation,
/// context window resolution, and caching are all exercised through real code.
@MainActor
final class ContextEstimationIntegrationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
    private var mock: MockInferenceBackend!

    override func setUp() async throws {
        try await super.setUp()

        container = try makeInMemoryContainer()
        context = container.mainContext

        mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["Response"]

        let service = InferenceService(backend: mock, name: "MockContext")
        vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))
    }

    override func tearDown() async throws {
        vm = nil
        mock = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func createSession(title: String = "Context Test") async -> PersistedChatSession {
        let session = PersistedChatSession(title: title)
        context.insert(session)
        try? context.save()
        await vm.switchToSession(session.toRecord())
        return session
    }

    // MARK: - Empty Conversation

    func test_contextEstimation_emptyConversation() async {
        await createSession()

        // With no messages and an empty system prompt, used tokens should be minimal.
        // The heuristic tokenizer returns max(1, text.count / 4) — empty string yields 1.
        XCTAssertEqual(vm.messages.count, 0)
        // Empty system prompt "" still produces 1 token via the heuristic.
        XCTAssertLessThanOrEqual(vm.contextUsedTokens, 1, "Empty conversation should use at most 1 token (system prompt floor)")
    }

    // MARK: - Single User Message

    func test_contextEstimation_singleUserMessage() async {
        await createSession()

        mock.tokensToYield = ["Hi"]
        vm.inputText = "Hello world"
        await vm.sendMessage()

        // "Hello world" = 11 chars → max(1, 11/4) = 2 tokens
        // "Hi" = 2 chars → max(1, 2/4) = 1 token
        // System prompt "" → 1 token
        // Total = 4 tokens
        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertGreaterThan(vm.contextUsedTokens, 0, "Should have non-zero token count after sending a message")
        XCTAssertEqual(vm.contextUsedTokens, 4, "Expected 4 tokens: system(1) + user(2) + assistant(1)")
    }

    // MARK: - Multi-Turn Conversation

    func test_contextEstimation_multiTurnConversation() async {
        await createSession()

        // Turn 1
        mock.tokensToYield = ["First", " reply"]
        vm.inputText = "First question here"
        await vm.sendMessage()
        let tokensAfterTurn1 = vm.contextUsedTokens

        // Turn 2
        mock.tokensToYield = ["Second", " reply"]
        vm.inputText = "Second question here"
        await vm.sendMessage()
        let tokensAfterTurn2 = vm.contextUsedTokens

        // Turn 3
        mock.tokensToYield = ["Third", " reply"]
        vm.inputText = "Third question here"
        await vm.sendMessage()
        let tokensAfterTurn3 = vm.contextUsedTokens

        XCTAssertEqual(vm.messages.count, 6)
        XCTAssertGreaterThan(tokensAfterTurn2, tokensAfterTurn1, "Tokens should increase after turn 2")
        XCTAssertGreaterThan(tokensAfterTurn3, tokensAfterTurn2, "Tokens should increase after turn 3")
    }

    // MARK: - System Prompt Included

    func test_contextEstimation_withSystemPrompt() async {
        let session = await createSession()
        session.systemPrompt = "You are a helpful assistant that provides concise answers."

        await vm.switchToSession(session.toRecord())
        let tokensWithSystemPrompt = vm.contextUsedTokens

        // The system prompt has ~56 characters → max(1, 56/4) = 14 tokens.
        // Even with no messages, context should reflect the system prompt.
        XCTAssertGreaterThan(
            tokensWithSystemPrompt, 1,
            "System prompt should contribute to token count"
        )

        // Now send a message and verify system prompt tokens are still included.
        mock.tokensToYield = ["Reply"]
        vm.inputText = "Test"
        await vm.sendMessage()

        XCTAssertGreaterThan(
            vm.contextUsedTokens, tokensWithSystemPrompt,
            "Tokens after message should exceed system-prompt-only tokens"
        )
    }

    // MARK: - Token Cache Population

    func test_tokenCache_isPopulatedAfterEstimation() async {
        await createSession()

        mock.tokensToYield = ["Reply", " here"]
        vm.inputText = "Cache test message"
        await vm.sendMessage()

        // The tokenCountCache should contain entries for both messages.
        XCTAssertEqual(vm.tokenCountCache.count, 2, "Cache should have entries for user and assistant messages")

        // Verify each message ID has a cache entry.
        for message in vm.messages {
            XCTAssertNotNil(
                vm.tokenCountCache[message.id],
                "Cache should contain entry for message \(message.id)"
            )
        }
    }

    func test_tokenCache_returnsSameResult_onSecondEstimation() async {
        await createSession()

        mock.tokensToYield = ["Cached", " reply"]
        vm.inputText = "Consistency check"
        await vm.sendMessage()

        let firstEstimate = vm.contextUsedTokens
        let firstCache = vm.tokenCountCache

        // Trigger re-estimation (e.g., by calling updateContextEstimate directly).
        vm.updateContextEstimate()

        let secondEstimate = vm.contextUsedTokens
        let secondCache = vm.tokenCountCache

        XCTAssertEqual(firstEstimate, secondEstimate, "Token count should be identical on re-estimation")
        XCTAssertEqual(firstCache.count, secondCache.count, "Cache size should not change")
        for (id, count) in firstCache {
            XCTAssertEqual(secondCache[id], count, "Cached token count should match for message \(id)")
        }
    }

    // MARK: - Context Percentage Calculation

    func test_contextUsageRatio_atVariousFillLevels() async {
        await createSession()

        // With default contextMaxTokens (from backend: 4096) and no messages,
        // usage should be near zero.
        XCTAssertLessThan(vm.contextUsageRatio, 0.01, "Near-empty context should have very low ratio")

        // Manually set context tokens to test the ratio calculation.
        vm.contextUsedTokens = 2048
        vm.contextMaxTokens = 4096
        XCTAssertEqual(vm.contextUsageRatio, 0.5, accuracy: 0.001, "Half-filled context should be 0.5")

        vm.contextUsedTokens = 4096
        XCTAssertEqual(vm.contextUsageRatio, 1.0, accuracy: 0.001, "Full context should be 1.0")

        vm.contextUsedTokens = 5000
        XCTAssertGreaterThan(vm.contextUsageRatio, 1.0, "Overflowed context should exceed 1.0")

        vm.contextUsedTokens = 0
        XCTAssertEqual(vm.contextUsageRatio, 0.0, accuracy: 0.001, "Empty context should be 0.0")
    }

    func test_contextUsageRatio_zeroMaxTokens_returnsZero() async {
        await createSession()

        vm.contextMaxTokens = 0
        vm.contextUsedTokens = 100
        XCTAssertEqual(vm.contextUsageRatio, 0.0, "Zero max tokens should return 0.0 ratio (avoid division by zero)")
    }

    // MARK: - Context Window Resolution

    func test_contextWindowManager_resolveContextSize_priority() {
        // Session override takes priority.
        XCTAssertEqual(
            ContextWindowManager.resolveContextSize(sessionOverride: 8192, modelContextLength: 4096, backendMaxTokens: 2048),
            8192
        )

        // Model metadata is next.
        XCTAssertEqual(
            ContextWindowManager.resolveContextSize(sessionOverride: nil, modelContextLength: 4096, backendMaxTokens: 2048),
            4096
        )

        // Backend capabilities are next.
        XCTAssertEqual(
            ContextWindowManager.resolveContextSize(sessionOverride: nil, modelContextLength: nil, backendMaxTokens: 2048),
            2048
        )

        // Falls back to default.
        XCTAssertEqual(
            ContextWindowManager.resolveContextSize(sessionOverride: nil, modelContextLength: nil, backendMaxTokens: nil),
            2048
        )
    }

    // MARK: - Backend Tokenizer Integration

    func test_contextEstimation_usesBackendTokenizerWhenAvailable() async {
        // Arrange: backend that returns a known fixed token count for every string.
        let tokenizingMock = MockTokenizerVendorBackend()
        tokenizingMock.stubbedTokenCount = 10  // every string → 10 tokens

        let service = InferenceService(backend: tokenizingMock, name: "VendorMock")
        let vendorVM = ChatViewModel(inferenceService: service)
        vendorVM.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))
        let session = PersistedChatSession(title: "Vendor Test")
        context.insert(session)
        try? context.save()
        await vendorVM.switchToSession(session.toRecord())

        tokenizingMock.tokensToYield = ["Reply"]
        vendorVM.inputText = "anything"
        await vendorVM.sendMessage()

        // With stubbed count of 10 per string:
        // system prompt ("") → 10, user message → 10, assistant message → 10 = 30 total.
        // This must NOT equal the heuristic value for "anything" (max(1,8/4)=2) + "Reply"(1) + sys(1)=4.
        XCTAssertEqual(vendorVM.contextUsedTokens, 30,
                       "Context estimation should use the backend tokenizer (10 per string) not the heuristic")
    }

    func test_contextEstimation_fallsBackToHeuristicWhenNoTokenizerVendor() async {
        // Standard MockInferenceBackend does NOT conform to TokenizerVendor.
        // Context estimation should use the heuristic.
        await createSession()
        mock.tokensToYield = ["Hi"]
        vm.inputText = "Hello world"
        await vm.sendMessage()

        // "Hello world"=11 chars → 2 tokens, "Hi"=2 chars → 1 token, sys ""→1 token = 4.
        XCTAssertEqual(vm.contextUsedTokens, 4,
                       "Should use heuristic (4-chars/token) when backend has no TokenizerVendor")
    }

    // MARK: - HeuristicTokenizer Direct Tests

    func test_heuristicTokenizer_variousInputs() {
        let tokenizer = HeuristicTokenizer()

        // Empty string → floor of 1.
        XCTAssertEqual(tokenizer.tokenCount(""), 1)

        // Short string.
        XCTAssertEqual(tokenizer.tokenCount("Hi"), 1)

        // ~4 chars per token.
        XCTAssertEqual(tokenizer.tokenCount("Hello world!"), 3) // 12 chars / 4 = 3

        // Longer string.
        let longString = String(repeating: "abcd", count: 100) // 400 chars
        XCTAssertEqual(tokenizer.tokenCount(longString), 100) // 400 / 4 = 100
    }
}
