import Foundation

// MARK: - TurnUsage

/// An immutable snapshot of token counts produced by one generation turn.
///
/// Records cross the ``UsageStore`` boundary as value types. The `@Model`
/// row type lives behind the SwiftData adapter so port consumers are free
/// of the SwiftData import.
///
/// `cachedInputTokens` and `cacheWriteTokens` are Anthropic-specific;
/// they remain `nil` for backends that do not report prompt-cache metrics.
public struct TurnUsage: Sendable, Codable {
    public let id: UUID
    public let sessionID: UUID
    /// The UUID of the cloud API endpoint that served the turn.
    /// `nil` for on-device backends (MLX, Llama, Foundation).
    public let endpointID: UUID?
    /// The model identifier string reported by the backend.
    public let modelIdentifier: String
    /// Wall-clock time when usage was captured (end of the turn).
    public let timestamp: Date
    public let promptTokens: Int
    public let completionTokens: Int
    /// Tokens served from Anthropic's prompt cache on this turn.
    public let cachedInputTokens: Int?
    /// Tokens written to Anthropic's prompt cache on this turn.
    public let cacheWriteTokens: Int?

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        endpointID: UUID?,
        modelIdentifier: String,
        timestamp: Date = Date(),
        promptTokens: Int,
        completionTokens: Int,
        cachedInputTokens: Int? = nil,
        cacheWriteTokens: Int? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.endpointID = endpointID
        self.modelIdentifier = modelIdentifier
        self.timestamp = timestamp
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteTokens = cacheWriteTokens
    }
}

// MARK: - UsageSummary

/// Aggregated token totals across a set of ``TurnUsage`` values.
public struct UsageSummary: Sendable {
    public let totalPromptTokens: Int
    public let totalCompletionTokens: Int
    /// Sum of Anthropic cache-hit tokens; 0 when no backend reports them.
    public let totalCachedInputTokens: Int
    /// Sum of Anthropic cache-write tokens; 0 when no backend reports them.
    public let totalCacheWriteTokens: Int
    public let turnCount: Int

    public init(
        totalPromptTokens: Int,
        totalCompletionTokens: Int,
        totalCachedInputTokens: Int,
        totalCacheWriteTokens: Int,
        turnCount: Int
    ) {
        self.totalPromptTokens = totalPromptTokens
        self.totalCompletionTokens = totalCompletionTokens
        self.totalCachedInputTokens = totalCachedInputTokens
        self.totalCacheWriteTokens = totalCacheWriteTokens
        self.turnCount = turnCount
    }
}

// MARK: - UsageStore

/// Persistence port for per-turn token usage.
///
/// Analogous to ``MessageStore`` and ``SessionStore`` in the port pattern —
/// the protocol surface is storage-neutral; the SwiftData adapter lives in
/// `ManifoldPersistenceSwiftData`.
///
/// `@MainActor` isolation mirrors the existing store ports and the
/// `ModelContext` isolation requirement of the SwiftData adapter.
///
/// Usage recording is best-effort: the runtime records a turn with a
/// `do/catch + Log.*` guard so a persistence failure never aborts the
/// turn loop. See ``ConversationTurnExecutor`` for the recording site.
@MainActor
public protocol UsageStore: AnyObject, Sendable {

    /// Persists a single ``TurnUsage``.
    ///
    /// - Throws: Storage errors from the underlying store.
    func record(_ record: TurnUsage) async throws

    /// Returns aggregated token totals across all stored records whose
    /// `timestamp` falls within the last `sinceDays` calendar days.
    ///
    /// - Parameter sinceDays: Number of full days to look back from now.
    /// - Throws: Storage errors from the underlying store.
    func summary(sinceDays: Int) async throws -> UsageSummary

    /// Returns aggregated token totals for a specific endpoint.
    ///
    /// - Parameters:
    ///   - endpointID: Endpoint UUID to filter by.
    ///   - sinceDays: Number of full days to look back from now.
    /// - Throws: Storage errors from the underlying store.
    func summary(forEndpoint endpointID: UUID, sinceDays: Int) async throws -> UsageSummary

    /// Returns up to `limit` records in reverse-chronological order
    /// (most recent first).
    ///
    /// - Parameter limit: Maximum number of records to return.
    /// - Throws: Storage errors from the underlying store.
    func recentRecords(limit: Int) async throws -> [TurnUsage]
}
