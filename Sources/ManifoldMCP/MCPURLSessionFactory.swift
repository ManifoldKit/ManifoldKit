import Foundation
import os

internal enum MCPURLSessionFactory {
    /// Test/runtime kill-switch: when `true`, `throwingShared()` throws
    /// instead of returning a session. Callers may flip this at any point
    /// during the process lifetime, not only at boot — `AuthMCPOAuthAuthorizationTests`
    /// and `MCPStreamableHTTPTransportTests` both toggle it repeatedly across
    /// test methods, so a concurrent reader on another thread can race a
    /// writer. Lock-guarded storage below makes every read/write atomic
    /// without an actor hop; the public name and call sites are unchanged.
    /// Mirrors `ManifoldCloudCore/URLSessionProvider.swift`'s
    /// `networkDisabled` (OSAllocatedUnfairLock, available below the
    /// macOS 15 / iOS 18 floor).
    private static let _networkDisabledLock = OSAllocatedUnfairLock<Bool>(initialState: false)

    internal static var networkDisabled: Bool {
        get { _networkDisabledLock.withLock { $0 } }
        set { _networkDisabledLock.withLock { $0 = newValue } }
    }

    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 600
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: configuration)
    }()

    static func throwingShared() throws -> URLSession {
        guard networkDisabled == false else {
            throw MCPError.networkUnavailable
        }
        return sharedSession
    }
}
