import Foundation
import ManifoldInference

// MARK: - SessionBranchCoordinator
//
// Issue #1957 Tier 4: session branching (new-session creation, transactional
// message copy, orphaned-session rollback) was mixed into
// `ConversationTurnExecutor`'s ~1580-line "Branch flow" section alongside
// context assembly, dispatch, and event emission. This type owns the
// branch-specific persistence mechanics in isolation; `runBranchFlow` keeps
// owning event emission and the decision to launch generation — the
// turn-loop-shared concerns that belong with the rest of the flow methods.

/// Owns the session-branching persistence mechanics: locating the branch
/// point in the source session, creating the new session, and copying the
/// sliced history into it transactionally (with rollback of the orphaned
/// session on a failed copy).
package struct SessionBranchCoordinator: Sendable {
    private let persistence: ConversationPersistencePort

    init(persistence: ConversationPersistencePort) {
        self.persistence = persistence
    }

    /// The outcome of a successful branch: how many messages were copied and
    /// whether the copied slice's last message came from the user (the
    /// signal `runBranchFlow` uses to decide whether to launch generation).
    package struct Result: Sendable {
        package let copiedCount: Int
        package let lastMessageIsFromUser: Bool
    }

    /// Locates `branchMessageID` in the source session's history, creates
    /// `newSessionID` (titled `newSessionTitle` or derived from the source
    /// session), and copies the slice up to and including the branch point
    /// into the new session with fresh message IDs.
    ///
    /// Throws ``ConversationError/messageNotFound(_:)`` when the branch point
    /// isn't found in the source history, or ``ConversationError/persistence(_:)``
    /// on any store failure. A copy failure after the new session was
    /// inserted rolls the session back (best-effort) before rethrowing, so a
    /// failed branch never strands an orphaned/empty session.
    package func branch(
        sourceSessionID: UUID,
        branchMessageID: UUID,
        newSessionID: UUID,
        newSessionTitle: String?
    ) async throws -> Result {
        // Fetch source history synchronously so callers observe ordering:
        // `.sessionBranched` fires before `processTurn` returns.
        let sourceHistory: [ChatMessage]
        do {
            sourceHistory = try await persistence.fetchMessages(sessionID: sourceSessionID)
        } catch {
            throw ConversationError.persistence(error)
        }

        // Find the branch point and slice history up to and including it.
        guard let branchIndex = sourceHistory.firstIndex(where: { $0.id == branchMessageID }) else {
            throw ConversationError.messageNotFound(branchMessageID)
        }
        let slice = Array(sourceHistory[...branchIndex])

        // Fetch the source session's current title once — used both as the
        // new session's own title when the caller didn't supply one, and
        // (regardless of what the new session ends up titled) as the
        // branch-origin snapshot recorded below. A title-fetch failure must
        // not abort the branch — `sessionTitle` already falls back and logs
        // internally — so this never throws.
        let sourceTitle = await persistence.sessionTitle(sessionID: sourceSessionID, fallback: "New Chat")
        let resolvedTitle = newSessionTitle ?? sourceTitle

        var newSession = ChatSession(id: newSessionID, title: resolvedTitle)
        // Branch-origin provenance (#2307 branch-origin chip): the read path
        // prefers resolving `branchOriginSessionID`'s *current* title live
        // (a rename of the source is reflected); `branchOriginTitleSnapshot`
        // is the fallback rendered only once the source session has been
        // deleted, so "Branched from ‹title›" still has something to show.
        newSession.branchOriginSessionID = sourceSessionID
        newSession.branchOriginTitleSnapshot = sourceTitle
        do {
            try await persistence.insertSession(newSession)
        } catch {
            throw ConversationError.persistence(error)
        }

        // Copy messages into the new session with fresh IDs and updated
        // sessionID. Drive the copy through the transactional batch API (same
        // as the edit flow) so a transactional store commits the whole slice
        // atomically and never exposes a half-copied branch.
        //
        // The session insert above commits separately from the message batch
        // (the adapter's transaction spans messages only), so if the copy
        // throws we must manually unwind the orphaned session — otherwise a
        // failed branch strands a ghost/empty session that surfaces as a
        // phantom in the sidebar. `transaction(block:)` does NOT roll back on
        // throw in this codebase, so the rollback is an explicit delete.
        let copyMutations = branchCopyMutations(from: slice, sessionID: newSessionID)
        do {
            try await persistence.performMessageMutations(copyMutations)
        } catch {
            // Roll back the session we just inserted before surfacing the copy
            // failure. `deleteSession` is best-effort and logs on its own
            // failure so the original copy error stays the caller-visible one.
            await persistence.deleteSession(newSessionID)
            throw ConversationError.persistence(error)
        }

        return Result(
            copiedCount: slice.count,
            lastMessageIsFromUser: slice.last?.role == .user
        )
    }
}

private func branchCopyMutations(
    from source: [ChatMessage],
    sessionID: UUID
) -> [MessageStoreMutation] {
    var mutations: [MessageStoreMutation] = []
    var start = 0
    while start < source.count {
        let timestamp = source[start].timestamp
        var end = start + 1
        while end < source.count, source[end].timestamp == timestamp { end += 1 }
        let freshIDs = (start..<end).map { _ in UUID() }.sorted()
        for (original, id) in zip(source[start..<end], freshIDs) {
            mutations.append(.insert(ChatMessage(
                id: id,
                role: original.role,
                contentParts: original.contentParts,
                timestamp: original.timestamp,
                sessionID: sessionID
            )))
        }
        start = end
    }
    return mutations
}
