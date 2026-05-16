import Foundation

/// Contextual information passed to ``PromptContextProvider`` implementations
/// at slot-contribution time.
///
/// Providers that do keyword matching, semantic retrieval, or budget-aware
/// selection use `conversationText` and `tokenizer`. Providers that only
/// need slot ordering use `messageCount` (same as the legacy
/// ``PromptContextProvider/contributeSlots(messageCount:)`` path).
public struct TurnContext: Sendable {
    /// The session driving this turn.
    public let sessionID: UUID
    /// Number of messages in the conversation at assembly time.
    /// Passed through to ``PromptSlotPosition/sortIndex(messageCount:)``.
    public let messageCount: Int
    /// Lowercased, whitespace-joined text from the conversation history.
    /// Nil when the caller has no history to provide (e.g. first turn or
    /// test doubles that don't need content-based matching).
    public let conversationText: String?
    /// Tokenizer for cost estimation. Nil falls back to ``HeuristicTokenizer``
    /// inside ``ContextBudgetPlanner``.
    public let tokenizer: (any TokenizerProvider)?
    /// Opaque host-app payload attached by ``ConversationRuntime/turnContextProvider``.
    /// Nil when no provider is registered or when the provider returns nil for
    /// this session. The value is passed through to ``CompletedTurn/appData``
    /// so ``GenerationHook`` implementations can read it without a side-channel
    /// registry.
    public var appData: (any Sendable)?

    public init(
        sessionID: UUID,
        messageCount: Int,
        conversationText: String? = nil,
        tokenizer: (any TokenizerProvider)? = nil,
        appData: (any Sendable)? = nil
    ) {
        self.sessionID = sessionID
        self.messageCount = messageCount
        self.conversationText = conversationText
        self.tokenizer = tokenizer
        self.appData = appData
    }
}
