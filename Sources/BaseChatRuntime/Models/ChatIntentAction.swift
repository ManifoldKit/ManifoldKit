import Foundation

/// Vocabulary of high-level chat actions a host app may expose through Siri,
/// Spotlight, or any other App Intents surface.
///
/// `BaseChatCore` deliberately does **not** import the `AppIntents` framework.
/// Host apps own the bridge: they declare `AppIntent` structs and translate
/// between the framework's representation and these cases. Keeping the
/// vocabulary string- and enum-based lets the core stay free of OS framework
/// dependencies while still defining a stable set of intents that downstream
/// integrations can target.
public enum ChatIntentAction: Sendable, Codable, Equatable {
    /// Resume work in the most recent (or currently active) session.
    case continueSession
    /// Begin a brand-new chat session.
    case startNewSession
    /// Read the most recent assistant message back to the user.
    case readLastMessage
    /// Produce a short summary of the active session.
    case summariseSession
}

/// Receives ``ChatIntentAction`` values dispatched from a host app's
/// `AppIntent` bridge.
///
/// Hosts conform a coordinator (typically the same object that owns the
/// `ChatViewModel`) and inject it via `ChatViewModel.intentHandler`. The
/// view model forwards `dispatch(_:)` calls to ``handle(_:sessionID:)``
/// with the currently active session, so a single intent payload can route
/// to the correct chat without the bridge needing to know about session
/// identifiers.
public protocol ChatSessionIntentHandler: AnyObject, Sendable {
    /// Performs the side effects associated with `action` for `sessionID`.
    ///
    /// - Parameters:
    ///   - action: The high-level intent the user requested.
    ///   - sessionID: The active session at dispatch time, or `nil` when
    ///     no session is currently selected.
    /// - Throws: Implementation-defined errors. The view model surfaces
    ///   them to the caller of `dispatch(_:)` unchanged.
    func handle(_ action: ChatIntentAction, sessionID: UUID?) async throws
}
