import XCTest
@testable import ManifoldInference

/// Tests for ``TurnContext`` value semantics and construction.
///
/// The conversationText assembly (lowercasing, nil on empty history) lives
/// in ``ConversationTurnExecutor``. An integration test verifying that
/// specific behaviour requires a MockInferenceBackend-backed runtime fixture;
/// see `ConversationRuntimeTests` for the full setup pattern.
// TODO: Add an integration test verifying that conversationText is lowercased
// in the assembled TurnContext once MockInferenceBackend exposes a hook to
// observe the TurnContext passed to PromptContextProvider at assembly time.
final class TurnContextTests: XCTestCase {

    func test_nilConversationText_isValid() {
        let ctx = TurnContext(
            sessionID: UUID(),
            messageCount: 0,
            conversationText: nil,
            tokenizer: nil
        )
        XCTAssertNil(ctx.conversationText)
        XCTAssertNil(ctx.tokenizer)
        XCTAssertEqual(ctx.messageCount, 0)
    }

    func test_nonNilConversationText_roundTrips() {
        let text = "hello world"
        let id = UUID()
        let ctx = TurnContext(
            sessionID: id,
            messageCount: 3,
            conversationText: text
        )
        XCTAssertEqual(ctx.conversationText, text)
        XCTAssertEqual(ctx.sessionID, id)
        XCTAssertEqual(ctx.messageCount, 3)
    }

    func test_defaultArguments_tokenNil() {
        // Verify the memberwise defaults so callers omitting tokenizer get nil.
        let ctx = TurnContext(sessionID: UUID(), messageCount: 5)
        XCTAssertNil(ctx.tokenizer)
        XCTAssertNil(ctx.conversationText)
    }

    func test_providerBudget_unlimited_hasMaxAllocated() {
        // Sentinel sanity — unlimited must not be zero or some small number.
        XCTAssertEqual(ProviderBudget.unlimited.allocated, Int.max)
        XCTAssertEqual(ProviderBudget.unlimited.totalContextSize, 0)
    }

    func test_providerBudget_zeroAllocated_isValid() {
        let b = ProviderBudget(allocated: 0, totalContextSize: 4096)
        XCTAssertEqual(b.allocated, 0)
        XCTAssertEqual(b.totalContextSize, 4096)
    }
}
