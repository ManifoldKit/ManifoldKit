import Foundation

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
