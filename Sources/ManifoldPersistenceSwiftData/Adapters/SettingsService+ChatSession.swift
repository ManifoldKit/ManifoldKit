import ManifoldInference

// Source-compatibility shims so callers can pass an @Model `PersistedChatSession`
// to the `SettingsService` resolution helpers, even though those helpers now
// operate on the storage-agnostic `ManifoldInference.ChatSession` after the
// ManifoldInference split.
extension SettingsService {

    /// Returns the effective temperature, using session override if available.
    @MainActor
    public func effectiveTemperature(session: PersistedChatSession?) -> Float {
        effectiveTemperature(session: session?.record)
    }

    @MainActor
    public func effectiveTopP(session: PersistedChatSession?) -> Float {
        effectiveTopP(session: session?.record)
    }

    @MainActor
    public func effectiveRepeatPenalty(session: PersistedChatSession?) -> Float {
        effectiveRepeatPenalty(session: session?.record)
    }
}
