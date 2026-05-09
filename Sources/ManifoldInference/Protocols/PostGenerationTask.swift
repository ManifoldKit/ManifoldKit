import Foundation

/// A task that runs in the background after a generation completes.
///
/// Implement this protocol to attach secondary work (extraction, indexing,
/// archiving) to the generation lifecycle without blocking the main generation
/// stream or re-entering the chat loop.
///
/// Tasks registered on ``ChatViewModel/postGenerationTasks`` are called
/// sequentially off `@MainActor` after the stream closes and the assistant
/// message is persisted. A task that throws surfaces its error via
/// ``ChatViewModel/backgroundTaskError`` but does not cancel subsequent tasks.
/// All pending tasks are cancelled when the session is reset.
public protocol PostGenerationTask: Sendable {

    /// Called off `@MainActor` after generation completes.
    ///
    /// - Parameters:
    ///   - message: The completed assistant message.
    ///   - session: The active chat session at the time of completion.
    func run(message: ChatMessageRecord, session: ChatSessionRecord) async throws
}
