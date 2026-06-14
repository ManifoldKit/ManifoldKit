import Foundation
import ManifoldInference
import ManifoldRuntime

extension ConversationExporter {
    /// Loads the session's messages via `provider`, then writes the export.
    ///
    /// Uses the SwiftData ``PersistedChatSession`` directly — `provider.fetchMessages`
    /// returns the linear chronological history. Apps modelling branches
    /// should call ``ManifoldRuntime/ConversationExporter/export(session:messages:format:directory:)``
    /// with the active path they have already materialised.
    ///
    /// `@MainActor` because ``MessageStore`` is `@MainActor`-isolated.
    @MainActor
    public static func export(
        session: PersistedChatSession,
        format: ConversationExportFormat,
        provider: any MessageStore,
        directory: URL? = nil
    ) async throws -> ShareableFile {
        let messages = try await provider.fetchMessages(for: session.id)
        return try export(
            session: session.record,
            messages: messages,
            format: format,
            directory: directory
        )
    }
}
