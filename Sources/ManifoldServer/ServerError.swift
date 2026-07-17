#if Server
import Foundation

internal enum ServerError: Error, Equatable, Sendable, CustomStringConvertible {
    case backendUnavailable(String)
    case invalidConfiguration(String)
    case invalidRequest(message: String, param: String? = nil, code: String? = nil)
    case notImplemented(String)
    case generationFailed(String)
    /// A `ServerConfiguration.generationTimeout` / `.streamingIdleTimeout`
    /// expired. The in-flight backend generation has been cancelled for real
    /// via `InferenceBackend.stopGeneration()` by the time this is thrown —
    /// but ONLY when `ServerConfiguration.parallelSlots == 1`. Under
    /// `parallelSlots > 1` the backend is shared across concurrent requests
    /// (`stopGeneration()`'s contract is backend-wide, not per-request), so
    /// calling it would cancel an unrelated sibling request's healthy
    /// generation; in that case the operation is only abandoned at the
    /// `Task` level, not cancelled at the backend. See
    /// `ServerConfiguration.generationTimeout`'s doc comment and
    /// `ServerGenerationTimeout` (#2265).
    case generationTimedOut(String)

    internal var description: String {
        switch self {
        case .backendUnavailable(let message),
             .invalidConfiguration(let message),
             .notImplemented(let message),
             .generationFailed(let message),
             .generationTimedOut(let message):
            message
        case .invalidRequest(let message, _, _):
            message
        }
    }
}

#endif
