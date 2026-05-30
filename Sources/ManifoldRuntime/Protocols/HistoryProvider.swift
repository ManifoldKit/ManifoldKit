import Foundation
import ManifoldInference

/// A contribution returned by a ``HistoryProvider``.
public struct HistoryContribution: Sendable {
    public let record: ChatMessageRecord
    public let position: HistoryInsertionPosition

    public init(record: ChatMessageRecord, position: HistoryInsertionPosition) {
        self.record = record
        self.position = position
    }
}

/// Where to insert a ``HistoryContribution`` relative to the existing history.
public enum HistoryInsertionPosition: Sendable {
    /// Insert `n` messages from the most-recent end. `atDepth(0)` = tail.
    /// Mirrors ``PromptSlotPosition/atDepth(_:)``.
    case atDepth(Int)
    /// Insert immediately before the record with the given ID.
    /// Silently dropped if no record with that ID exists.
    case beforeRecord(UUID)
    /// Insert immediately after the record with the given ID.
    /// Silently dropped if no record with that ID exists.
    case afterRecord(UUID)
    /// Insert at the start of the array (oldest position).
    case head
    /// Insert at the end of the array (newest position).
    case tail
}

/// Contributes additional ``ChatMessageRecord``s to be injected into the
/// prompt-visible history array before generation.
///
/// Providers are applied in registration order after any registered
/// ``HistoryShaper`` has produced the base prompt-visible history. Each
/// provider receives the history as augmented by all preceding providers. A
/// throwing provider aborts the current turn with a
/// ``ConversationError/persistence(_:)`` error — treat store-fetch failures as
/// throwing.
///
/// Providers must not re-order existing `.chat`-kind records; they may only
/// inject new records at the declared position. The runtime enforces a
/// chronological-order invariant in debug builds.
///
/// Register via
/// ``ConversationRuntime/init(messageStore:sessionStore:inferenceService:pipeline:budgetPlanner:ragService:auxiliaryInferenceService:usageStore:generationHooks:compressionPolicy:historyShaper:historyProviders:hostTurnContextProvider:turnContextProvider:sessionToolSources:hookRegistry:)``.
public protocol HistoryProvider: Sendable {
    func contribute(
        history: [ChatMessageRecord],
        context: TurnContext
    ) async throws -> [HistoryContribution]
}

/// A no-op ``HistoryProvider`` that returns an empty contribution list.
/// Used as a test fixture and as the default when no providers are registered.
public struct IdentityHistoryProvider: HistoryProvider {
    public init() {}
    public func contribute(
        history: [ChatMessageRecord],
        context: TurnContext
    ) async throws -> [HistoryContribution] { [] }
}
