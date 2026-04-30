import Foundation
import BaseChatRuntime

// MARK: - ChatViewModel + App Intents

extension ChatViewModel {

    /// Forwards an App Intents action to the configured ``intentHandler``.
    ///
    /// Hosts call this from their `AppIntent.perform()` implementations after
    /// translating the framework-specific payload to a ``ChatIntentAction``.
    /// The view model attaches the active session ID (if any) so the handler
    /// can route the action to the correct chat without the bridge needing
    /// session-aware logic.
    ///
    /// When no handler is installed the call is a no-op — apps that do not
    /// ship App Intents simply leave ``intentHandler`` `nil`. Errors raised
    /// by the handler propagate to the caller unchanged.
    public func dispatch(_ action: ChatIntentAction) async throws {
        guard let intentHandler else { return }
        try await intentHandler.handle(action, sessionID: activeSessionID)
    }
}
