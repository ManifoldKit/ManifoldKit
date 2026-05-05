#if Server
import Foundation

internal enum ServerError: Error, Equatable, Sendable, CustomStringConvertible {
    case backendUnavailable(String)
    case invalidConfiguration(String)
    case invalidRequest(message: String, param: String? = nil, code: String? = nil)
    case notImplemented(String)

    internal var description: String {
        switch self {
        case .backendUnavailable(let message),
             .invalidConfiguration(let message),
             .notImplemented(let message):
            message
        case .invalidRequest(let message, _, _):
            message
        }
    }
}

#endif
