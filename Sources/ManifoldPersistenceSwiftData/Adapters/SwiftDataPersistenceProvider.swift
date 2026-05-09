import Foundation
import ManifoldInference
import ManifoldRuntime
import SwiftData

/// Default ``SessionStore`` + ``MessageStore`` adapter backed by SwiftData.
///
/// Phase 1.2 of the runtime ports refactor split the previous combined
/// `ChatPersistenceProvider` into per-port protocols. The SwiftData adapter
/// stays a single type that conforms to both — sessions and messages live in
/// the same `ModelContext`, so splitting into two adapter types would only
/// duplicate the context plumbing without buying a real boundary. Hosts that
/// want a true per-port impl can wire two custom types of their own.
///
/// Operates on the ``ModelContext`` injected at init time, converting between
/// SwiftData `@Model` objects and plain ``ChatSessionRecord`` /
/// ``ChatMessageRecord`` value types at the boundary.
@MainActor
public final class SwiftDataPersistenceProvider: SessionStore, MessageStore {

    private let modelContext: ModelContext

    // Hook lists are stored as plain arrays. Registration is `@MainActor`
    // (the protocol is `@MainActor`-isolated), so no lock is required to
    // mutate; firing happens on the same actor immediately after the write
    // commits. Phase 1.2 sub-step 5 may revisit this when use cases lift off
    // main actor.
    private var messageHooks: [any MessageStorePostWriteHook] = []
    private var sessionHooks: [any SessionStorePostWriteHook] = []

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext

        // Reap orphaned Keychain items once per provider instance. Runs
        // synchronously because ModelContext is not Sendable and deferring
        // into a Task would race against provider teardown (notably in tests
        // that rebuild the container per-method). SecItemCopyMatching on the
        // apikeys namespace completes in milliseconds — a boot-time cost we
        // accept to guarantee no orphan can outlive its owning endpoint row.
        // Gated by ManifoldConfiguration.keychainReaperEnabled.
        ManifoldBootstrap.reapOrphanedKeychainItems(in: modelContext)
    }

    // MARK: - Sessions

    public func insertSession(_ record: ChatSessionRecord) async throws {
        let session = ChatSession(title: record.title)
        session.id = record.id
        session.createdAt = record.createdAt
        session.updatedAt = record.updatedAt
        session.systemPrompt = record.systemPrompt
        session.selectedModelID = record.selectedModelID
        session.selectedEndpointID = record.selectedEndpointID
        session.temperature = record.temperature
        session.topP = record.topP
        session.repeatPenalty = record.repeatPenalty
        session.promptTemplateRawValue = record.promptTemplate?.rawValue
        session.contextSizeOverride = record.contextSizeOverride
        session.pinnedMessageIDsRaw = record.pinnedMessageIDs.isEmpty ? nil : record.pinnedMessageIDs.map(\.uuidString).sorted().joined(separator: ",")
        modelContext.insert(session)
        try modelContext.save()
        await fireSessionHooks(record)
    }

    public func updateSession(_ record: ChatSessionRecord) async throws {
        guard let session = try fetchSwiftDataSession(id: record.id) else {
            throw ChatPersistenceError.sessionNotFound(record.id)
        }
        session.title = record.title
        session.updatedAt = record.updatedAt
        session.systemPrompt = record.systemPrompt
        session.selectedModelID = record.selectedModelID
        session.selectedEndpointID = record.selectedEndpointID
        session.temperature = record.temperature
        session.topP = record.topP
        session.repeatPenalty = record.repeatPenalty
        session.promptTemplateRawValue = record.promptTemplate?.rawValue
        session.contextSizeOverride = record.contextSizeOverride
        session.pinnedMessageIDsRaw = record.pinnedMessageIDs.isEmpty ? nil : record.pinnedMessageIDs.map(\.uuidString).sorted().joined(separator: ",")
        try modelContext.save()
        await fireSessionHooks(record)
    }

    public func deleteSession(_ sessionID: UUID) async throws {
        guard let session = try fetchSwiftDataSession(id: sessionID) else {
            throw ChatPersistenceError.sessionNotFound(sessionID)
        }
        try await deleteMessages(for: sessionID)
        modelContext.delete(session)
        try modelContext.save()
    }

    public func fetchSessions() async throws -> [ChatSessionRecord] {
        let descriptor = FetchDescriptor<ChatSession>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map { $0.toRecord() }
    }

    public func fetchSessions(offset: Int, limit: Int) async throws -> [ChatSessionRecord] {
        var descriptor = FetchDescriptor<ChatSession>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        // SwiftData's fetchOffset/fetchLimit push pagination into the store
        // engine; falling back to fetch-all-then-slice would defeat the
        // point on a 1000-session sidebar.
        descriptor.fetchOffset = max(0, offset)
        descriptor.fetchLimit = max(0, limit)
        return try modelContext.fetch(descriptor).map { $0.toRecord() }
    }

    // MARK: - Search

    public func searchMessages(query: String, limit: Int) async throws -> [MessageSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }

        // SwiftData #Predicate localizedStandardContains is case- and
        // diacritic-insensitive and runs in-store, so we don't pull every
        // message into memory just to filter. A small over-fetch (limit*2)
        // covers the case where the plain-text `content` cache is stale and
        // a snippet pass rejects the match.
        let needle = trimmed
        var descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.content.localizedStandardContains(needle) },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        let results = try modelContext.fetch(descriptor)
        var hits: [MessageSearchHit] = []
        hits.reserveCapacity(results.count)
        for message in results {
            guard let (snippet, range) = makeMessageSearchSnippet(content: message.content, query: trimmed) else {
                continue
            }
            hits.append(MessageSearchHit(
                messageID: message.id,
                sessionID: message.sessionID,
                snippet: snippet,
                matchRange: range,
                timestamp: message.timestamp
            ))
        }
        return hits
    }

    // MARK: - Messages

    public func insertMessage(_ record: ChatMessageRecord) async throws {
        let message = ChatMessage(role: record.role, contentParts: record.contentParts, sessionID: record.sessionID)
        message.id = record.id
        message.timestamp = record.timestamp
        message.promptTokens = record.promptTokens
        message.completionTokens = record.completionTokens
        modelContext.insert(message)
        try modelContext.save()
        await fireMessageHooks(record)
    }

    public func updateMessage(_ record: ChatMessageRecord) async throws {
        guard let message = try fetchSwiftDataMessage(id: record.id) else {
            throw ChatPersistenceError.messageNotFound(record.id)
        }
        message.contentParts = record.contentParts
        message.promptTokens = record.promptTokens
        message.completionTokens = record.completionTokens
        try modelContext.save()
        await fireMessageHooks(record)
    }

    public func deleteMessage(_ messageID: UUID) async throws {
        guard let message = try fetchSwiftDataMessage(id: messageID) else {
            throw ChatPersistenceError.messageNotFound(messageID)
        }
        modelContext.delete(message)
        try modelContext.save()
    }

    public func fetchMessages(for sessionID: UUID) async throws -> [ChatMessageRecord] {
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return try modelContext.fetch(descriptor).map { $0.toRecord() }
    }

    public func fetchRecentMessages(for sessionID: UUID, limit: Int) async throws -> [ChatMessageRecord] {
        // Fetch newest-first, take `limit`, then reverse to ascending order.
        var descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let results = try modelContext.fetch(descriptor)
        return results.reversed().map { $0.toRecord() }
    }

    public func fetchMessages(for sessionID: UUID, before: Date, limit: Int) async throws -> [ChatMessageRecord] {
        // Fetch messages older than `before`, newest-first, take `limit`, then reverse.
        var descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID && $0.timestamp < before },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let results = try modelContext.fetch(descriptor)
        return results.reversed().map { $0.toRecord() }
    }

    public func deleteMessages(for sessionID: UUID) async throws {
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        for message in try modelContext.fetch(descriptor) {
            modelContext.delete(message)
        }
        try modelContext.save()
    }

    // MARK: - Hooks

    public func addPostWriteHook(_ hook: any MessageStorePostWriteHook) {
        messageHooks.append(hook)
    }

    public func addPostWriteHook(_ hook: any SessionStorePostWriteHook) {
        sessionHooks.append(hook)
    }

    /// Fires registered message-write hooks in registration order.
    /// Hook errors are not surfaceable: hooks must not throw, and a failing
    /// hook cannot roll back the committed write.
    private func fireMessageHooks(_ record: ChatMessageRecord) async {
        guard !messageHooks.isEmpty else { return }
        for hook in messageHooks {
            await hook.messageDidWrite(record, in: record.sessionID)
        }
    }

    private func fireSessionHooks(_ record: ChatSessionRecord) async {
        guard !sessionHooks.isEmpty else { return }
        for hook in sessionHooks {
            await hook.sessionDidWrite(record)
        }
    }

    // MARK: - Private

    private func fetchSwiftDataSession(id: UUID) throws -> ChatSession? {
        let descriptor = FetchDescriptor<ChatSession>(
            predicate: #Predicate { $0.id == id }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func fetchSwiftDataMessage(id: UUID) throws -> ChatMessage? {
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.id == id }
        )
        return try modelContext.fetch(descriptor).first
    }
}

// MARK: - Model <-> Record conversions

extension ChatSession {
    /// Converts a SwiftData model to a plain record.
    func toRecord() -> ChatSessionRecord {
        record
    }
}

extension ChatMessage {
    /// Converts a SwiftData model to a plain record.
    func toRecord() -> ChatMessageRecord {
        ChatMessageRecord(
            id: id,
            role: role,
            contentParts: contentParts,
            timestamp: timestamp,
            sessionID: sessionID,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        )
    }
}
