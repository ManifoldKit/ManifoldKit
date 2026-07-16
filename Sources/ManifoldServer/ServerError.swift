#if Server
import Foundation

internal enum ServerError: Error, Equatable, Sendable, CustomStringConvertible {
    case backendUnavailable(String)
    case invalidConfiguration(String)
    case invalidRequest(message: String, param: String? = nil, code: String? = nil)
    case notImplemented(String)
    case generationFailed(String)
    /// A `ServerConfiguration.generationTimeout` / `.streamingIdleTimeout`
    /// expired. The in-flight backend generation has already been cancelled
    /// via `InferenceBackend.stopGeneration()` by the time this is thrown —
    /// see `ServerGenerationTimeout` (#2265).
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
