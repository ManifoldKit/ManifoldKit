/// Represents the current phase of backend activity, enabling UI to show appropriate indicators.
public enum BackendActivityPhase: Sendable, Equatable {
    case idle
    case modelLoading(progress: Double?)
    case waitingForFirstToken
    case streaming
    /// The backend has stopped producing events for longer than expected.
    case stalled
    /// The backend is retrying a failed connection.
    case retrying(attempt: Int, of: Int)
}
