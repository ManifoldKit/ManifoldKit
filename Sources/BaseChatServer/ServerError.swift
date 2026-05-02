#if Server
import Foundation

internal enum ServerError: Error, Equatable, Sendable, CustomStringConvertible {
    case backendUnavailable(String)
    case invalidConfiguration(String)
    case notImplemented(String)

    internal var description: String {
        switch self {
        case .backendUnavailable(let message),
             .invalidConfiguration(let message),
             .notImplemented(let message):
            message
        }
    }
}

#endif
