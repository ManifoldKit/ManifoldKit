import Foundation

internal enum MCPURLSessionFactory {
    internal nonisolated(unsafe) static var networkDisabled: Bool = false

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
