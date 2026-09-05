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
/// SwiftData `@Model` objects and plain ``ManifoldInference.ChatSession`` /
/// ``ManifoldInference.ChatMessage`` value types at the boundary.
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

    /// Test-only observation point for the bounded candidate scan in
    /// ``searchMessages(query:limit:)``. It is instance-owned so parallel
    /// providers cannot affect one another, and package-scoped so it never
    /// becomes part of the persistence API.
    package var searchCandidatePageObserver: (@MainActor @Sendable (Int) async -> Void)?

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

    public func insertSession(_ record: ManifoldInference.ChatSession) async throws {
        let session = PersistedChatSession(title: record.title)
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
        try reconcileBranchOrigin(sessionID: record.id, with: record)
        try modelContext.save()
        await fireSessionHooks(record)
    }

    public func updateSession(_ record: ManifoldInference.ChatSession) async throws {
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
        try reconcileBranchOrigin(sessionID: record.id, with: record)
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
    private func reconcileAgents(on session: PersistedChatSession, with agents: [ManifoldInference.AgentDefinition]) {
        let desiredByID = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var existingByID: [UUID: PersistedAgent] = [:]

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
            let row = PersistedAgent(
                id: agent.id,
                name: agent.name,
                systemPrompt: agent.systemPrompt,
                descriptionText: agent.description,
                allowedToolNames: agent.allowedToolNames
            )
            session.agents.append(row)
        }
    }

    /// Reconciles the session's `BranchOrigin` side row (SchemaV13, #2307)
    /// against `record.branchOriginSessionID` / `.branchOriginTitleSnapshot`
    /// so a write→read round-trip is lossless. Upserts a row when the record
    /// carries branch-origin data; deletes any existing row when it doesn't
    /// (a session is branched at creation time and this never flips back to
    /// nil in practice, but round-tripping a cleared value is still correct).
    ///
    /// Throws rather than swallowing the lookup fetch: both callers
    /// (`insertSession`/`updateSession`) are themselves `throws`, so a
    /// genuine fetch failure propagates instead of being silently treated as
    /// "no existing row" — which would insert a duplicate and trip the
    /// `@Attribute(.unique) sessionID` constraint at `save()` when a row
    /// already exists, turning a transient fetch error into a confusing
    /// unique-constraint crash on an unrelated line.
    private func reconcileBranchOrigin(sessionID: UUID, with record: ManifoldInference.ChatSession) throws {
        let existing = try modelContext.fetch(FetchDescriptor<ManifoldSchemaV13.BranchOrigin>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )).first

        guard let originSessionID = record.branchOriginSessionID else {
            if let existing {
                modelContext.delete(existing)
            }
            return
        }

        if let existing {
            existing.originSessionID = originSessionID
            existing.originTitleSnapshot = record.branchOriginTitleSnapshot
        } else {
            modelContext.insert(ManifoldSchemaV13.BranchOrigin(
                sessionID: sessionID,
                originSessionID: originSessionID,
                originTitleSnapshot: record.branchOriginTitleSnapshot
            ))
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
        // Stage the message purge and the session delete against the context,
        // then commit both with a single `save()` so they land atomically.
        // The previous shape called the public `deleteMessages(for:)` (which
        // saves on its own) and then saved the session delete separately — two
        // commits, so a failure on the second left the messages already
        // committed-gone while the session row survived. Staging both before
        // one save closes that window: if the save throws, neither delete
        // reaches the store.
        let messages = try modelContext.fetch(
            FetchDescriptor<PersistedChatMessage>(predicate: #Predicate { $0.sessionID == sessionID })
        )
        for message in messages {
            modelContext.delete(message)
        }
        // BranchOrigin (SchemaV13, #2307) is a side table keyed by plain
        // UUID, not a SwiftData relationship, so it is never cascade-deleted
        // — an orphaned row here would leak forever. Only the deleted
        // session's own row (it was a branch) is purged; other sessions'
        // BranchOrigin rows that point *at* this session as their source are
        // deliberately left alone — that's the tombstone case the read path
        // (`SessionListService.branchOriginTitle(for:)`) already falls back
        // to `originTitleSnapshot` for.
        if let ownBranchOrigin = try modelContext.fetch(FetchDescriptor<ManifoldSchemaV13.BranchOrigin>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )).first {
            modelContext.delete(ownBranchOrigin)
        }
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
        let messages = try modelContext.fetch(FetchDescriptor<PersistedChatMessage>())
        for message in messages {
            modelContext.delete(message)
        }
        // BranchOrigin (SchemaV13, #2307) is a side table, not cascaded by
        // any relationship — purge it explicitly so a full erase leaves no
        // orphaned provenance rows behind.
        let branchOrigins = try modelContext.fetch(FetchDescriptor<ManifoldSchemaV13.BranchOrigin>())
        for branchOrigin in branchOrigins {
            modelContext.delete(branchOrigin)
        }
        let sessions = try modelContext.fetch(FetchDescriptor<PersistedChatSession>())
        for session in sessions {
            modelContext.delete(session)
        }
        try modelContext.save()
    }

    public func fetchSessions() async throws -> [ManifoldInference.ChatSession] {
        // Pinned sessions surface above the chronological list (#1301). The
        // primary key is `isPinned` descending so true sorts above false; the
        // pinned bucket is then ordered by `pinnedAt` desc (most recently
        // pinned first), and the unpinned bucket falls back to `updatedAt`
        // desc — the pre-V8 order. SwiftData applies the secondary keys only
        // when the primary one ties, so within each bucket the intended
        // ordering holds.
        let descriptor = FetchDescriptor<PersistedChatSession>(
            sortBy: [
                SortDescriptor(\.pinnedSortKey, order: .reverse),
                SortDescriptor(\.updatedAt, order: .reverse),
            ]
        )
        return try applyBranchOrigins(to: modelContext.fetch(descriptor).map { $0.toRecord() })
    }

    public func fetchSessions(offset: Int, limit: Int) async throws -> [ManifoldInference.ChatSession] {
        var descriptor = FetchDescriptor<PersistedChatSession>(
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
        return try applyBranchOrigins(to: modelContext.fetch(descriptor).map { $0.toRecord() })
    }

    /// Predicate pushdown for the per-turn single-session read. Overrides the
    /// protocol default's full-table scan so only the matched row is fetched
    /// and only its `agents` relationship faults — the turn loop reads agents,
    /// so that one fault is the correct floor; this kills the (N-1) other
    /// faults plus the scan. `ChatSession.id` is a plain `UUID` column (not
    /// `@Attribute(.unique)`); adding a unique index is a future V10 migration,
    /// not required for this read's correctness.
    public func fetchSession(id: UUID) async throws -> ManifoldInference.ChatSession? {
        guard var record = try fetchSwiftDataSession(id: id)?.toRecord() else { return nil }
        if let origin = try modelContext.fetch(FetchDescriptor<ManifoldSchemaV13.BranchOrigin>(
            predicate: #Predicate { $0.sessionID == id }
        )).first {
            record.branchOriginSessionID = origin.originSessionID
            record.branchOriginTitleSnapshot = origin.originTitleSnapshot
        }
        return record
    }

    /// Merges ``ManifoldSchemaV13/BranchOrigin`` side-table rows onto the
    /// storage-agnostic records returned by a session fetch. `PersistedChatSession`
    /// carries no branch-origin columns itself (see `ChatSession.swift`'s doc
    /// comment for why) — this is the read-path counterpart to
    /// ``reconcileBranchOrigin(sessionID:with:)``.
    ///
    /// One extra fetch for the whole batch (not one per session): branch
    /// origin is a niche per-session lookup, so amortising it across the page
    /// keeps ``fetchSessions()``/``fetchSessions(offset:limit:)`` at two store
    /// round-trips total rather than N+1.
    private func applyBranchOrigins(
        to records: [ManifoldInference.ChatSession]
    ) throws -> [ManifoldInference.ChatSession] {
        guard !records.isEmpty else { return records }
        let ids = Set(records.map(\.id))
        let origins = try modelContext.fetch(FetchDescriptor<ManifoldSchemaV13.BranchOrigin>(
            predicate: #Predicate { ids.contains($0.sessionID) }
        ))
        guard !origins.isEmpty else { return records }
        let originsByID = Dictionary(uniqueKeysWithValues: origins.map { ($0.sessionID, $0) })
        return records.map { record in
            guard let origin = originsByID[record.id] else { return record }
            var updated = record
            updated.branchOriginSessionID = origin.originSessionID
            updated.branchOriginTitleSnapshot = origin.originTitleSnapshot
            return updated
        }
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
        var hits: [MessageSearchHit] = []
        hits.reserveCapacity(min(limit, Self.messageSearchCandidatePageSize))
        var beforeTimestamp: Date?
        var beforeID: UUID?
        var fetchedPageCount = 0

        while hits.count < limit {
            try Task.checkCancellation()

            let predicate: Predicate<PersistedChatMessage>
            if let beforeTimestamp, let beforeID {
                predicate = #Predicate {
                    $0.content.localizedStandardContains(needle) &&
                        ($0.timestamp < beforeTimestamp ||
                            ($0.timestamp == beforeTimestamp && $0.id < beforeID))
                }
            } else {
                predicate = #Predicate { $0.content.localizedStandardContains(needle) }
            }
            let descriptor = boundedMessageFetch(
                predicate: predicate,
                sortBy: [
                    SortDescriptor(\.timestamp, order: .reverse),
                    SortDescriptor(\.id, order: .reverse)
                ],
                limit: Self.messageSearchCandidatePageSize
            )
            let candidates = try modelContext.fetch(descriptor)
            fetchedPageCount += 1

            // Capture the next keyset position before any suspension. The
            // fetched SwiftData rows stay confined to this actor turn; after an
            // observer or yield re-enters the actor, only these value scalars
            // are used to construct the following page.
            let nextBeforeTimestamp = candidates.last?.timestamp
            let nextBeforeID = candidates.last?.id

            for message in candidates {
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

            let finished = hits.count == limit || candidates.count < Self.messageSearchCandidatePageSize
            if let observer = searchCandidatePageObserver {
                await observer(fetchedPageCount)
            }
            try Task.checkCancellation()
            guard !finished else { break }

            // A `ModelContext.fetch` is synchronous on this main-actor
            // provider. Yield between bounded pages so cancellation can be
            // delivered, then observe it before issuing another store query.
            await Task.yield()
            try Task.checkCancellation()
            guard let nextBeforeTimestamp, let nextBeforeID else { break }
            beforeTimestamp = nextBeforeTimestamp
            beforeID = nextBeforeID
        }
        return hits
    }

    /// Candidate rows are bounded even when a common first term needs many
    /// pages before enough rows satisfy every query term. The result array is
    /// bounded by the caller's limit; only this many SwiftData rows are held per
    /// page.
    private static let messageSearchCandidatePageSize = 100

    private static func messageSearchTerms(from query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Database work stays bounded while ``fetchMessages(for:)`` assembles its
    /// complete contractual result one keyset page at a time.
    private static let messageHistoryPageSize = 500

    /// Single builder for every `ChatMessage` *read* fetch. The `limit`
    /// parameter is required, so no read path can construct a message fetch that
    /// forgets to bound the store query — the footgun audit's class A
    /// ("cross-cutting invariant wired into one branch only") applied to fetch
    /// limits. Bulk-delete paths deliberately do not route through here: capping
    /// a delete would leave orphaned rows, so they own their unbounded fetch.
    private func boundedMessageFetch(
        predicate: Predicate<PersistedChatMessage>,
        sortBy: [SortDescriptor<PersistedChatMessage>],
        limit: Int
    ) -> FetchDescriptor<PersistedChatMessage> {
        var descriptor = FetchDescriptor<PersistedChatMessage>(predicate: predicate, sortBy: sortBy)
        descriptor.fetchLimit = limit
        return descriptor
    }

    // MARK: - Messages

    public func insertMessage(_ record: ManifoldInference.ChatMessage) async throws {
        let message = makeSwiftDataMessage(from: record)
        modelContext.insert(message)
        try modelContext.save()
        await fireMessageHooks(record)
    }

    public func updateMessage(_ record: ManifoldInference.ChatMessage) async throws {
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

    public func fetchMessages(for sessionID: UUID) async throws -> [ManifoldInference.ChatMessage] {
        var pages: [[ManifoldInference.ChatMessage]] = []
        var cursor: MessageHistoryCursor?
        repeat {
            try Task.checkCancellation()
            let page = try await fetchMessageHistoryPage(
                for: sessionID,
                cursor: cursor,
                limit: Self.messageHistoryPageSize
            )
            pages.append(page.messages)
            cursor = page.nextCursor
        } while cursor != nil
        return pages.reversed().flatMap(\.self)
    }

    public func fetchMessageHistoryPage(
        for sessionID: UUID,
        cursor: MessageHistoryCursor?,
        limit: Int
    ) async throws -> MessageHistoryPage {
        guard limit > 0, limit < Int.max else {
            throw MessageHistoryPagingError.invalidLimit(limit)
        }
        if let cursor, cursor.sessionID != sessionID {
            throw MessageHistoryPagingError.cursorSessionMismatch
        }

        let highWaterTimestamp: Date
        let highWaterID: UUID
        if let cursor {
            highWaterTimestamp = cursor.highWaterTimestamp
            highWaterID = cursor.highWaterID
        } else {
            let highWaterDescriptor = boundedMessageFetch(
                predicate: #Predicate { $0.sessionID == sessionID },
                sortBy: [
                    SortDescriptor(\.timestamp, order: .reverse),
                    SortDescriptor(\.id, order: .reverse)
                ],
                limit: 1
            )
            guard let highWater = try modelContext.fetch(highWaterDescriptor).first else {
                return MessageHistoryPage(messages: [], nextCursor: nil)
            }
            highWaterTimestamp = highWater.timestamp
            highWaterID = highWater.id
        }

        let beforeTimestamp = cursor?.beforeTimestamp
        let beforeID = cursor?.beforeID
        let predicate: Predicate<PersistedChatMessage>
        if let beforeTimestamp, let beforeID {
            predicate = #Predicate {
                $0.sessionID == sessionID &&
                    ($0.timestamp < highWaterTimestamp ||
                        ($0.timestamp == highWaterTimestamp && $0.id <= highWaterID)) &&
                    ($0.timestamp < beforeTimestamp ||
                        ($0.timestamp == beforeTimestamp && $0.id < beforeID))
            }
        } else {
            predicate = #Predicate {
                $0.sessionID == sessionID &&
                    ($0.timestamp < highWaterTimestamp ||
                        ($0.timestamp == highWaterTimestamp && $0.id <= highWaterID))
            }
        }
        let descriptor = boundedMessageFetch(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\.timestamp, order: .reverse),
                SortDescriptor(\.id, order: .reverse)
            ],
            limit: limit + 1
        )
        let results = try modelContext.fetch(descriptor)
        let page = Array(results.prefix(limit))
        let nextCursor = results.count > limit ? page.last.map {
            MessageHistoryCursor(
                sessionID: sessionID,
                highWaterTimestamp: highWaterTimestamp,
                highWaterID: highWaterID,
                beforeTimestamp: $0.timestamp,
                beforeID: $0.id
            )
        } : nil
        return MessageHistoryPage(
            messages: page.reversed().map { $0.toRecord() },
            nextCursor: nextCursor
        )
    }

    public func fetchRecentMessages(for sessionID: UUID, limit: Int) async throws -> [ManifoldInference.ChatMessage] {
        // Fetch newest-first, take `limit`, then reverse to ascending order.
        let descriptor = boundedMessageFetch(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)],
            limit: limit
        )
        let results = try modelContext.fetch(descriptor)
        return results.reversed().map { $0.toRecord() }
    }

    public func fetchMessages(for sessionID: UUID, before: Date, limit: Int) async throws -> [ManifoldInference.ChatMessage] {
        // Fetch messages older than `before`, newest-first, take `limit`, then reverse.
        let descriptor = boundedMessageFetch(
            predicate: #Predicate { $0.sessionID == sessionID && $0.timestamp < before },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)],
            limit: limit
        )
        let results = try modelContext.fetch(descriptor)
        return results.reversed().map { $0.toRecord() }
    }

    public func deleteMessages(for sessionID: UUID) async throws {
        let descriptor = FetchDescriptor<PersistedChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        for message in try modelContext.fetch(descriptor) {
            modelContext.delete(message)
        }
        try modelContext.save()
    }

    public func performMessageMutations(_ mutations: [MessageStoreMutation]) async throws {
        guard !mutations.isEmpty else { return }

        // Stage every mutation against the context, then commit with one
        // `save()`. On any failure we MUST explicitly `rollback()` the staged
        // changes.
        //
        // Do NOT "simplify" this into `modelContext.transaction { ... }`:
        // `transaction(block:)` groups the changes into a single atomic save,
        // but it does NOT discard staged in-memory changes when the block
        // throws — a staged `.update` survives the throw and leaks on the next
        // save (proven by SwiftDataTransactionalMutationTests'
        // rollback cases, which fail under a transaction-based rewrite). The
        // manual rollback is what gives the batch its all-or-nothing semantics.
        // This is a documented WONTFIX (#1682): the transaction-based rewrite
        // has been evaluated and rejected on those grounds — do not re-litigate.
        var writtenRecords: [ManifoldInference.ChatMessage] = []
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
                    let descriptor = FetchDescriptor<PersistedChatMessage>(
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
    private func fireMessageHooks(_ record: ManifoldInference.ChatMessage) async {
        guard !messageHooks.isEmpty else { return }
        for hook in messageHooks {
            await hook.messageDidWrite(record, in: record.sessionID)
        }
    }

    private func fireSessionHooks(_ record: ManifoldInference.ChatSession) async {
        guard !sessionHooks.isEmpty else { return }
        for hook in sessionHooks {
            await hook.sessionDidWrite(record)
        }
    }

    // MARK: - Private

    private func fetchSwiftDataSession(id: UUID) throws -> PersistedChatSession? {
        let descriptor = FetchDescriptor<PersistedChatSession>(
            predicate: #Predicate { $0.id == id }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func fetchSwiftDataMessage(id: UUID) throws -> PersistedChatMessage? {
        let descriptor = FetchDescriptor<PersistedChatMessage>(
            predicate: #Predicate { $0.id == id }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func makeSwiftDataMessage(from record: ManifoldInference.ChatMessage) -> PersistedChatMessage {
        let message = PersistedChatMessage(role: record.role, contentParts: record.contentParts, sessionID: record.sessionID)
        message.id = record.id
        message.timestamp = record.timestamp
        message.promptTokens = record.promptTokens
        message.completionTokens = record.completionTokens
        message.kind = record.kind
        message.citations = record.citations
        message.agentID = record.agentID
        return message
    }

    private func applyMutableMessageFields(from record: ManifoldInference.ChatMessage, to message: PersistedChatMessage) {
        message.contentParts = record.contentParts
        message.promptTokens = record.promptTokens
        message.completionTokens = record.completionTokens
        message.kind = record.kind
        message.citations = record.citations
        message.agentID = record.agentID
    }
}

// MARK: - Model <-> Record conversions

extension PersistedChatSession {
    /// Converts a SwiftData model to a plain record.
    func toRecord() -> ManifoldInference.ChatSession {
        record
    }
}

extension PersistedChatMessage {
    /// Converts a SwiftData model to a plain record.
    func toRecord() -> ManifoldInference.ChatMessage {
        ManifoldInference.ChatMessage(
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
