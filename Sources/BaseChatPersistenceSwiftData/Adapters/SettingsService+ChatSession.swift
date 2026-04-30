import BaseChatInference

// Source-compatibility shims so callers can pass an @Model `ChatSession` to the
// `SettingsService` resolution helpers, even though those helpers now operate
// on the storage-agnostic `ChatSessionRecord` after the BaseChatInference split.
extension SettingsService {

    /// Returns the effective temperature, using session override if available.
    @MainActor
    public func effectiveTemperature(session: ChatSession?) -> Float {
        effectiveTemperature(session: session?.record)
    }

    @MainActor
    public func effectiveTopP(session: ChatSession?) -> Float {
        effectiveTopP(session: session?.record)
    }

    @MainActor
    public func effectiveRepeatPenalty(session: ChatSession?) -> Float {
        effectiveRepeatPenalty(session: session?.record)
    }
}
