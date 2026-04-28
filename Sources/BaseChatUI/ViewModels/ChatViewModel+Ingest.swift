import Foundation
import BaseChatCore
import BaseChatInference

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

        guard let persistence = persistenceOrLog("ingest") else { return }

        // Create and activate a fresh session so the ingested prompt starts
        // its own conversation rather than landing in whichever chat was
        // last viewed. Mirrors the SessionManagerViewModel path but stays
        // on ChatViewModel so hosts without a session manager (AppIntent,
        // deep-link) can still handoff cleanly.
        let session = ChatSessionRecord(title: "New Chat")
        do {
            try persistence.insertSession(session)
        } catch {
            Log.persistence.error("ChatViewModel.ingest failed to insert session: \(error.localizedDescription)")
            surfaceError(error, kind: .persistence)
            return
        }
        switchToSession(session)

        // Seed the prompt and run it through the same path as the compose
        // bar so loading checks, auto-title, and token accounting all stay
        // consistent. Attachments ride along as `.text` neighbors — once
        // richer parts (images, files) land via Share Extension support,
        // the first user message already supports the shape.
        inputText = payload.prompt
        await sendMessage()

        // Attachments land as an update to the user message so any extra
        // parts survive alongside the prompt without re-routing through
        // `sendMessage()`, which only accepts a text body today.
        if !payload.attachments.isEmpty,
           let userMessage = messages.last(where: { $0.role == .user }) {
            var updated = userMessage
            updated.contentParts.append(contentsOf: payload.attachments)
            do {
                try updateMessage(updated)
                if let index = messages.firstIndex(where: { $0.id == userMessage.id }) {
                    messages[index] = updated
                }
            } catch {
                Log.persistence.warning(
                    "ChatViewModel.ingest failed to persist attachments: \(error.localizedDescription)"
                )
            }
        }
    }
}
