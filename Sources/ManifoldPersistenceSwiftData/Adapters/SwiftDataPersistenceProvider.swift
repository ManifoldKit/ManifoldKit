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
public final class SwiftDataPersistenceProvider: SessionStore, MessageStore, TransactionalMessageStore {

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
        session.isPinned = record.isPinned
        session.pinnedAt = record.pinnedAt
        session.pinnedSortKey = record.pinnedAt ?? .distantPast
        session.activeAgentID = record.activeAgentID
        session.activeSkillName = record.activeSkillName
        modelContext.insert(session)
        reconcileAgents(on: session, with: record.agents)
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
        session.isPinned = record.isPinned
        session.pinnedAt = record.pinnedAt
        session.pinnedSortKey = record.pinnedAt ?? .distantPast
        session.activeAgentID = record.activeAgentID
        session.activeSkillName = record.activeSkillName
        reconcileAgents(on: session, with: record.agents)
        try modelContext.save()
        await fireSessionHooks(record)
    }

    /// Reconciles the session's owned `Agent` `@Model` rows against the
    /// storage-agnostic `agents` carried on the record, so a write→read
    /// round-trip is lossless (#1495). Diffs by `Agent.id`:
    ///   - rows whose id is absent from the record are deleted (cascade-owned,
    ///     so removal is safe);
    ///   - rows present in both are updated in place (mutating the live row
    ///     rather than replacing it preserves SwiftData object identity and
    ///     avoids churning the `@Relationship` set);
    ///   - record agents with no matching row are inserted and appended.
    ///
    /// `activeAgentID` is written separately on the parent row (and via
    /// ``setActiveAgent(sessionID:agentID:)``), so handoff state is untouched
    /// here — this only owns the agent registry membership.
    private func reconcileAgents(on session: ChatSession, with agents: [ManifoldInference.Agent]) {
        let desiredByID = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var existingByID: [UUID: Agent] = [:]

        // Remove rows no longer present in the record. Iterate a snapshot so we
        // can mutate `session.agents` while walking it.
        for row in session.agents {
            if let desired = desiredByID[row.id] {
                row.name = desired.name
                row.systemPrompt = desired.systemPrompt
                row.descriptionText = desired.description
                row.allowedToolNames = desired.allowedToolNames
                existingByID[row.id] = row
            } else {
                modelContext.delete(row)
            }
        }

        // Insert rows for agents the session does not yet have.
        for agent in agents where existingByID[agent.id] == nil {
            let row = Agent(
                id: agent.id,
                name: agent.name,
                systemPrompt: agent.systemPrompt,
                descriptionText: agent.description,
                allowedToolNames: agent.allowedToolNames
            )
            session.agents.append(row)
        }
    }

    /// Narrow in-place write of `updatedAt` only — mutates the live `@Model`
    /// row without rewriting the other columns, so a concurrent full-record
    /// write (another turn, or a host-side session edit) is not clobbered by a
    /// stale-snapshot rewrite. Fires session hooks with a fresh record read
    /// back from the mutated row. Silently no-ops when the session is gone (a
    /// touch racing a delete).
    public func touch(sessionID: UUID, date: Date = Date()) async throws {
        guard let session = try fetchSwiftDataSession(id: sessionID) else { return }
        session.updatedAt = date
        try modelContext.save()
        await fireSessionHooks(session.toRecord())
    }

    /// Narrow in-place write of `activeAgentID` only. See ``touch(sessionID:date:)``
    /// for the lost-update rationale. Silently no-ops when the session is gone.
    public func setActiveAgent(sessionID: UUID, agentID: UUID?) async throws {
        guard let session = try fetchSwiftDataSession(id: sessionID) else { return }
        session.activeAgentID = agentID
        try modelContext.save()
        await fireSessionHooks(session.toRecord())
    }

    public func deleteSession(_ sessionID: UUID) async throws {
        guard let session = try fetchSwiftDataSession(id: sessionID) else {
            throw ChatPersistenceError.sessionNotFound(sessionID)
        }
        try await deleteMessages(for: sessionID)
        modelContext.delete(session)
        try modelContext.save()
    }

    public func deleteAll() async throws {
        // Atomic bulk purge: stage every ChatMessage and ChatSession delete
        // against the in-memory context, then issue a single `save()`. If
        // SwiftData throws on save, the unsaved deletes never reach the
        // store — subsequent fetches observe the pre-call state. A loop of
        // per-row `delete + save` would not give that property: a failure
        // mid-loop would leave the prefix already committed.
        //
        // Messages are deleted first so that even if the schema is later
        // extended with a cascade rule, the explicit message purge guarantees
        // no orphaned ChatMessage rows can survive — `sessionID` is a UUID
        // foreign key (no SwiftData relationship), so an implicit cascade is
        // not available today.
        let messages = try modelContext.fetch(FetchDescriptor<ChatMessage>())
        for message in messages {
            modelContext.delete(message)
        }
        let sessions = try modelContext.fetch(FetchDescriptor<ChatSession>())
        for session in sessions {
            modelContext.delete(session)
        }
        try modelContext.save()
    }

    public func fetchSessions() async throws -> [ChatSessionRecord] {
        // Pinned sessions surface above the chronological list (#1301). The
        // primary key is `isPinned` descending so true sorts above false; the
        // pinned bucket is then ordered by `pinnedAt` desc (most recently
        // pinned first), and the unpinned bucket falls back to `updatedAt`
        // desc — the pre-V8 order. SwiftData applies the secondary keys only
        // when the primary one ties, so within each bucket the intended
        // ordering holds.
        let descriptor = FetchDescriptor<ChatSession>(
            sortBy: [
                SortDescriptor(\.pinnedSortKey, order: .reverse),
                SortDescriptor(\.updatedAt, order: .reverse),
            ]
        )
        return try modelContext.fetch(descriptor).map { $0.toRecord() }
    }

    public func fetchSessions(offset: Int, limit: Int) async throws -> [ChatSessionRecord] {
        var descriptor = FetchDescriptor<ChatSession>(
            sortBy: [
                SortDescriptor(\.pinnedSortKey, order: .reverse),
                SortDescriptor(\.updatedAt, order: .reverse),
            ]
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
        // diacritic-insensitive and runs in-store. For multi-term queries we
        // use the first term as the store predicate, then require every term
        // in memory so words can match across non-adjacent parts of a message.
        let terms = Self.messageSearchTerms(from: trimmed)
        let needle = terms[0]
        var descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.content.localizedStandardContains(needle) },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        if terms.count == 1 {
            descriptor.fetchLimit = limit
        }

        let results = try modelContext.fetch(descriptor)
        var hits: [MessageSearchHit] = []
        hits.reserveCapacity(min(results.count, limit))
        for message in results {
            guard terms.allSatisfy({ message.content.localizedStandardContains($0) }),
                  let snippetTerm = terms.first(where: { message.content.localizedStandardContains($0) }),
                  let (snippet, range) = makeMessageSearchSnippet(content: message.content, query: snippetTerm) else {
                continue
            }
            hits.append(MessageSearchHit(
                messageID: message.id,
                sessionID: message.sessionID,
                snippet: snippet,
                matchRange: range,
                timestamp: message.timestamp
            ))
            if hits.count == limit { break }
        }
        return hits
    }

    private static func messageSearchTerms(from query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    // MARK: - Messages

    public func insertMessage(_ record: ChatMessageRecord) async throws {
        let message = makeSwiftDataMessage(from: record)
        modelContext.insert(message)
        try modelContext.save()
        await fireMessageHooks(record)
    }

    public func updateMessage(_ record: ChatMessageRecord) async throws {
        guard let message = try fetchSwiftDataMessage(id: record.id) else {
            throw ChatPersistenceError.messageNotFound(record.id)
        }
        applyMutableMessageFields(from: record, to: message)
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

    public func performMessageMutations(_ mutations: [MessageStoreMutation]) async throws {
        guard !mutations.isEmpty else { return }

        var writtenRecords: [ChatMessageRecord] = []
        do {
            for mutation in mutations {
                switch mutation {
                case let .insert(record):
                    modelContext.insert(makeSwiftDataMessage(from: record))
                    writtenRecords.append(record)
                case let .update(record):
                    guard let message = try fetchSwiftDataMessage(id: record.id) else {
                        throw ChatPersistenceError.messageNotFound(record.id)
                    }
                    applyMutableMessageFields(from: record, to: message)
                    writtenRecords.append(record)
                case let .delete(messageID):
                    guard let message = try fetchSwiftDataMessage(id: messageID) else {
                        throw ChatPersistenceError.messageNotFound(messageID)
                    }
                    modelContext.delete(message)
                case let .deleteMessages(sessionID):
                    let descriptor = FetchDescriptor<ChatMessage>(
                        predicate: #Predicate { $0.sessionID == sessionID }
                    )
                    for message in try modelContext.fetch(descriptor) {
                        modelContext.delete(message)
                    }
                }
            }

            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }

        for record in writtenRecords {
            await fireMessageHooks(record)
        }
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

    private func makeSwiftDataMessage(from record: ChatMessageRecord) -> ChatMessage {
        let message = ChatMessage(role: record.role, contentParts: record.contentParts, sessionID: record.sessionID)
        message.id = record.id
        message.timestamp = record.timestamp
        message.promptTokens = record.promptTokens
        message.completionTokens = record.completionTokens
        message.kind = record.kind
        message.citations = record.citations
        message.agentID = record.agentID
        return message
    }

    private func applyMutableMessageFields(from record: ChatMessageRecord, to message: ChatMessage) {
        message.contentParts = record.contentParts
        message.promptTokens = record.promptTokens
        message.completionTokens = record.completionTokens
        message.kind = record.kind
        message.citations = record.citations
        message.agentID = record.agentID
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
            completionTokens: completionTokens,
            kind: kind,
            citations: citations,
            agentID: agentID
        )
    }
}
