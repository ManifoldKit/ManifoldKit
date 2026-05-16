import Foundation
import ManifoldRuntime
import ManifoldInference

// MARK: - ChatViewModel + Ingest

extension ChatViewModel {

    /// Ingests an inbound prompt from a deep link, App Intent, or Share
    /// Extension handoff.
    ///
    /// Creates a new chat session, activates it, seeds it with the prompt
    /// plus any attachments as a single user message, and starts generation
    /// via the same `sendMessage()` path used by the compose bar. The
    /// ``InboundPayload/source`` is logged for attribution so production
    /// traces can separate intent-driven turns from user-typed ones.
    ///
    /// ## Requirements
    ///
    /// - ``configure(runtime:)`` or ``configure(persistence:)`` must have been
    ///   called. Otherwise this method no-ops after logging a warning —
    ///   callers should buffer the payload until persistence is ready.
    /// - A model or endpoint must be loaded; if not, the usual
    ///   "no model loaded" error surfaces via ``activeError`` and generation
    ///   is not started, matching the compose-bar contract.
    ///
    /// ## Concurrency
    ///
    /// Back-to-back ingests serialize on the main actor: each call creates
    /// its own session before kicking off generation, so concurrent calls
    /// produce distinct sessions rather than interleaving messages.
    ///
    /// - Parameter payload: The inbound payload to ingest.
    @MainActor
    public func ingest(_ payload: InboundPayload) async {
        Log.inference.info(
            "ChatViewModel.ingest source=\(String(describing: payload.source), privacy: .public) prompt chars=\(payload.prompt.count, privacy: .public)"
        )

        // Create and activate a fresh session so the ingested prompt starts
        // its own conversation rather than landing in whichever chat was
        // last viewed. Mirrors the SessionManagerViewModel path but stays
        // on ChatViewModel so hosts without a session manager (AppIntent,
        // deep-link) can still handoff cleanly.
        let session = ChatSessionRecord(title: "New Chat")
        do {
            try await persistenceAdapter.insertSession(session)
        } catch {
            Log.persistence.error("ChatViewModel.ingest failed to insert session: \(error.localizedDescription)")
            surfaceError(error, kind: .persistence)
            return
        }
        await switchToSession(session)

        // Seed the prompt and any attachments through the same draft path as
        // the compose bar so loading checks, auto-title, and token accounting
        // all stay consistent.
        inputText = payload.prompt
        draftAttachments = payload.attachments
        await sendMessage()
    }
}
