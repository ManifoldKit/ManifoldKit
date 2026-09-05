import Foundation
import ManifoldInference
import ManifoldRuntime

/// Test synchronization for a continuation page that has already been read
/// from the wrapped store. It lets UI tests invalidate state after a real
/// SwiftData snapshot exists and before that stale result is returned.
package actor MessageHistoryPageGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    package init() {}

    package func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    fileprivate func waitAfterSnapshot() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    package func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

/// Test double that wraps any combined ``SessionStore`` + ``MessageStore``
/// adapter and adds two facilities the real adapter cannot offer: per-method
/// error injection and call counting.
///
/// Pair it with ``InMemoryPersistenceHarness`` when a test needs to assert
/// that a view model handles persistence failures correctly, or that it
/// routed through the persistence layer the expected number of times.
/// All other persistence behaviour (CRUD, ordering, pagination) is the
/// real adapter's, so tests written against this wrapper stay honest.
@MainActor
public final class ErrorInjectingPersistenceProvider: SessionStore, MessageStore {

    private let wrapped: any SessionStore & MessageStore

    public var shouldThrowOnInsertSession: Error?
    public var shouldThrowOnUpdateSession: Error?
    public var shouldThrowOnFetchSessions: Error?
    public var shouldThrowOnInsertMessage: Error?
    public var shouldThrowOnFetchMessages: Error?
    public var shouldThrowOnDeleteMessages: Error?
    public var shouldThrowOnDeleteAll: Error?
    /// Test-only gate applied after a continuation page is fetched from the
    /// wrapped store, used to exercise stale UI completions deterministically.
    package var historyPageGate: MessageHistoryPageGate?

    public var insertSessionCallCount = 0
    public var updateSessionCallCount = 0
    public var deleteSessionCallCount = 0
    public var fetchSessionsCallCount = 0
    public var insertMessageCallCount = 0
    public var updateMessageCallCount = 0
    public var deleteMessageCallCount = 0
    public var fetchMessagesCallCount = 0
    public var fetchRecentMessagesCallCount = 0
    public var fetchMessagesBeforeCallCount = 0
    public var fetchMessageHistoryPageCallCount = 0
    public var deleteMessagesCallCount = 0
    public var deleteAllCallCount = 0

    public init(wrapping wrapped: any SessionStore & MessageStore) {
        self.wrapped = wrapped
    }

    public func insertSession(_ session: ChatSession) async throws {
        insertSessionCallCount += 1
        if let error = shouldThrowOnInsertSession { throw error }
        try await wrapped.insertSession(session)
    }

    public func updateSession(_ session: ChatSession) async throws {
        updateSessionCallCount += 1
        if let error = shouldThrowOnUpdateSession { throw error }
        try await wrapped.updateSession(session)
    }

    public func deleteSession(_ sessionID: UUID) async throws {
        deleteSessionCallCount += 1
        try await wrapped.deleteSession(sessionID)
    }

    public func fetchSessions() async throws -> [ChatSession] {
        fetchSessionsCallCount += 1
        if let error = shouldThrowOnFetchSessions { throw error }
        return try await wrapped.fetchSessions()
    }

    public func insertMessage(_ message: ChatMessage) async throws {
        insertMessageCallCount += 1
        if let error = shouldThrowOnInsertMessage { throw error }
        try await wrapped.insertMessage(message)
    }

    public func updateMessage(_ message: ChatMessage) async throws {
        updateMessageCallCount += 1
        try await wrapped.updateMessage(message)
    }

    public func deleteMessage(_ messageID: UUID) async throws {
        deleteMessageCallCount += 1
        try await wrapped.deleteMessage(messageID)
    }

    public func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] {
        fetchMessagesCallCount += 1
        if let error = shouldThrowOnFetchMessages { throw error }
        return try await wrapped.fetchMessages(for: sessionID)
    }

    public func fetchRecentMessages(for sessionID: UUID, limit: Int) async throws -> [ChatMessage] {
        fetchRecentMessagesCallCount += 1
        if let error = shouldThrowOnFetchMessages { throw error }
        return try await wrapped.fetchRecentMessages(for: sessionID, limit: limit)
    }

    public func fetchMessages(for sessionID: UUID, before: Date, limit: Int) async throws -> [ChatMessage] {
        fetchMessagesBeforeCallCount += 1
        if let error = shouldThrowOnFetchMessages { throw error }
        return try await wrapped.fetchMessages(for: sessionID, before: before, limit: limit)
    }

    public func fetchMessageHistoryPage(
        for sessionID: UUID,
        cursor: MessageHistoryCursor?,
        limit: Int
    ) async throws -> MessageHistoryPage {
        fetchMessageHistoryPageCallCount += 1
        if let error = shouldThrowOnFetchMessages { throw error }
        let page = try await wrapped.fetchMessageHistoryPage(
            for: sessionID,
            cursor: cursor,
            limit: limit
        )
        if cursor != nil, let historyPageGate {
            await historyPageGate.waitAfterSnapshot()
        }
        return page
    }

    public func deleteMessages(for sessionID: UUID) async throws {
        deleteMessagesCallCount += 1
        if let error = shouldThrowOnDeleteMessages { throw error }
        try await wrapped.deleteMessages(for: sessionID)
    }

    public func deleteAll() async throws {
        deleteAllCallCount += 1
        if let error = shouldThrowOnDeleteAll { throw error }
        try await wrapped.deleteAll()
    }
}
