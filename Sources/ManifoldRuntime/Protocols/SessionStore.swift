import Foundation
import ManifoldInference

/// Errors produced by ``SessionStore`` and ``MessageStore`` implementations.
///
/// Storage-neutral: the same error surface covers SwiftData, in-memory test
/// fakes, and any custom backing store a host wires up.
public enum ChatPersistenceError: Error, LocalizedError, Sendable, Equatable {
    case providerNotConfigured
    case sessionNotFound(UUID)
    case messageNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .providerNotConfigured:
            return "Persistence provider is not configured."
        case let .sessionNotFound(sessionID):
            return "Session not found: \(sessionID.uuidString)"
        case let .messageNotFound(messageID):
            return "Message not found: \(messageID.uuidString)"
        }
    }
}

/// Storage port for chat sessions.
///
/// Phase 1.2 of the runtime ports refactor split the previous combined
/// `ChatPersistenceProvider` into per-port protocols (this type plus
/// ``MessageStore``) so hosts can implement one slice without dragging in the
/// other. Records cross the boundary in both directions; concrete `@Model` /
/// row types stay behind the adapter.
///
/// `async throws` at the surface, sync at the implementation: SwiftData's
/// `ModelContext` is `@MainActor`-bound, so the adapter conforms by hopping
/// onto the main actor. In-memory and remote impls can implement methods on
/// whatever isolation suits them.
@MainActor
public protocol SessionStore: AnyObject, Sendable {

    /// Inserts a new chat session.
    ///
    /// - Throws: Storage errors from the underlying store.
    func insertSession(_ session: ChatSessionRecord) async throws

    /// Updates an existing chat session.
    ///
    /// - Throws:
    ///   - ``ChatPersistenceError/sessionNotFound(_:)`` when the session does not exist.
    ///   - Storage errors from the underlying store.
    func updateSession(_ session: ChatSessionRecord) async throws

    /// Updates **only** `updatedAt` on the session, in place.
    ///
    /// The turn loop bumps `updatedAt` twice per send so the sidebar reflects
    /// recency, but ``updateSession(_:)`` rewrites every column from a snapshot
    /// taken earlier in the turn. Two concurrent turns (or a host-side session
    /// edit racing a turn) interleave as a lost update: B reads, A writes its
    /// fields, B writes its stale snapshot back, clobbering A's columns. This
    /// narrow write mutates the live row's `updatedAt` without round-tripping
    /// the other fields, so a concurrent edit to e.g. `title` survives.
    ///
    /// No-ops silently when the session does not exist — a touch racing a
    /// delete is benign and must not surface an error to the turn loop.
    ///
    /// - Parameters:
    ///   - sessionID: The session whose `updatedAt` to bump.
    ///   - date: The timestamp to set (defaults to now).
    /// - Throws: Storage errors from the underlying store.
    func touch(sessionID: UUID, date: Date) async throws

    /// Updates **only** `activeAgentID` on the session, in place.
    ///
    /// Mid-stream agent handoffs swap the active agent. ``updateSession(_:)``
    /// would rewrite the whole row from the turn-start snapshot, clobbering any
    /// concurrent field change. This narrow write mutates only the
    /// active-agent column on the live row.
    ///
    /// No-ops silently when the session does not exist.
    ///
    /// - Parameters:
    ///   - sessionID: The session to mutate.
    ///   - agentID: The new active agent, or `nil` to clear it.
    /// - Throws: Storage errors from the underlying store.
    func setActiveAgent(sessionID: UUID, agentID: UUID?) async throws

    /// Deletes a chat session and all associated messages.
    ///
    /// Implementations that also conform to ``MessageStore`` typically delete
    /// the session's messages as part of this call to keep the two stores
    /// transactionally consistent against the same backing context.
    ///
    /// - Throws:
    ///   - ``ChatPersistenceError/sessionNotFound(_:)`` when the session does not exist.
    ///   - Storage errors from the underlying store.
    func deleteSession(_ sessionID: UUID) async throws

    /// Deletes every persisted session and its messages in a single
    /// transaction.
    ///
    /// Consumer apps with a "Erase All Chats" / GDPR purge / account-reset
    /// flow need an atomic, batch-efficient primitive: iterating
    /// ``fetchSessions()`` and calling ``deleteSession(_:)`` per id is
    /// O(N) round-trips, fans out N post-write/event notifications, and
    /// races mid-iteration mutations from other scene-phase paths. Only the
    /// persistence layer can give the atomicity guarantee — the surface
    /// here exists so the lowering happens once, in the adapter.
    ///
    /// Implementations that also conform to ``MessageStore`` must purge the
    /// associated messages in the same transaction so no orphaned messages
    /// remain post-call. If the underlying write fails, no partial deletion
    /// should be visible to subsequent fetches.
    ///
    /// - Throws: Storage errors from the underlying store.
    func deleteAll() async throws

    /// Fetches all chat sessions sorted by most-recently-updated.
    ///
    /// - Throws: Storage errors from the underlying store.
    func fetchSessions() async throws -> [ChatSessionRecord]

    /// Fetches a page of chat sessions sorted by most-recently-updated.
    ///
    /// Use to paginate large session lists so the sidebar stays responsive at
    /// 1000+ sessions. Pages are returned in the same order as
    /// ``fetchSessions()``.
    ///
    /// - Parameters:
    ///   - offset: Index of the first session to return (0-based).
    ///   - limit: Maximum number of sessions to return.
    /// - Throws: Storage errors from the underlying store.
    func fetchSessions(offset: Int, limit: Int) async throws -> [ChatSessionRecord]

    /// Registers a hook fired after every successful session write.
    ///
    /// Symmetric counterpart to ``MessageStore/addPostWriteHook(_:)``.
    /// Provisional — no internal consumer uses it yet, so its semantics may
    /// firm up once a host actually exercises it.
    func addPostWriteHook(_ hook: any SessionStorePostWriteHook)
}

// MARK: - Default pagination

extension SessionStore {

    /// Default: pages over the full list returned by ``fetchSessions()``.
    /// Storage backends that can push pagination into the engine should
    /// override.
    public func fetchSessions(offset: Int, limit: Int) async throws -> [ChatSessionRecord] {
        let all = try await fetchSessions()
        guard offset < all.count else { return [] }
        let end = min(offset + limit, all.count)
        return Array(all[offset..<end])
    }

    /// Default: no-op. Implementations that don't surface session post-write
    /// hooks inherit this and silently drop the registration. Provisional —
    /// see ``addPostWriteHook(_:)`` doc.
    public func addPostWriteHook(_ hook: any SessionStorePostWriteHook) {}

    /// Default: read-modify-write fallback for stores that don't push the
    /// narrow update into the engine. **Not** atomic against a concurrent
    /// full-record write — storage-backed adapters that own a live row MUST
    /// override and mutate only `updatedAt` so the lost-update window closes.
    /// Provided so in-memory test doubles keep compiling. Silently no-ops when
    /// the session is gone.
    public func touch(sessionID: UUID, date: Date = Date()) async throws {
        let sessions = try await fetchSessions()
        guard var session = sessions.first(where: { $0.id == sessionID }) else { return }
        session.updatedAt = date
        try await updateSession(session)
    }

    /// Default: read-modify-write fallback. See ``touch(sessionID:date:)`` for
    /// why storage-backed adapters must override. Silently no-ops when the
    /// session is gone.
    public func setActiveAgent(sessionID: UUID, agentID: UUID?) async throws {
        let sessions = try await fetchSessions()
        guard var session = sessions.first(where: { $0.id == sessionID }) else { return }
        session.activeAgentID = agentID
        try await updateSession(session)
    }

    /// Default: iterates ``fetchSessions()`` and calls ``deleteSession(_:)``
    /// per id. **Not** atomic — provided so existing custom in-memory
    /// conformers (notably small test doubles) keep compiling without
    /// changing every call site. Storage-backed adapters that own a real
    /// transaction MUST override and commit one save call so the
    /// atomicity guarantee documented on the protocol surface holds.
    public func deleteAll() async throws {
        for record in try await fetchSessions() {
            try await deleteSession(record.id)
        }
    }
}

// MARK: - Post-write hooks

/// Low-level primitive: fires after a session write commits.
///
/// **Not** the canonical attachment point for any specific consumer's
/// cross-cutting concerns. Hooks fire after the underlying write commits, in
/// registration order, on whatever isolation the store runs on.
///
/// Hooks must not throw — a failing hook cannot roll back a committed write.
/// Errors should be logged via `Log.persistence.error` and otherwise
/// swallowed; surfaces that need transactional guarantees compose at the
/// use-case layer instead.
///
/// Symmetric counterpart to ``MessageStorePostWriteHook``. Provisional shape:
/// no internal consumer uses it yet, so the signature may firm up once a
/// host actually exercises it.
public protocol SessionStorePostWriteHook: Sendable {
    func sessionDidWrite(_ record: ChatSessionRecord) async
}
