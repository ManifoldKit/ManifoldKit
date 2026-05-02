#if Server
import Foundation

package enum ServerError: Error, Equatable, Sendable, CustomStringConvertible {
    case backendUnavailable(String)
    case invalidConfiguration(String)
    case notImplemented(String)

    package var description: String {
        switch self {
        case .backendUnavailable(let message),
             .invalidConfiguration(let message),
             .notImplemented(let message):
            message
        }
    }
}

#endif
