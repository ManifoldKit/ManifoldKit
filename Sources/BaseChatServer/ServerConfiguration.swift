#if Server
import Foundation

internal struct ServerConfiguration: Equatable, Sendable {
    internal var host: String
    internal var port: Int
    internal var apiKey: String?
    internal var parallelSlots: Int
    internal var unsafeCORS: Bool
    internal var corsOrigin: String?
    internal var metricsEnabled: Bool

    internal init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        apiKey: String? = nil,
        parallelSlots: Int = 1,
        unsafeCORS: Bool = false,
        corsOrigin: String? = nil,
        metricsEnabled: Bool = false
    ) {
        self.host = host
        self.port = port
        self.apiKey = apiKey
        self.parallelSlots = parallelSlots
        self.unsafeCORS = unsafeCORS
        self.corsOrigin = corsOrigin
        self.metricsEnabled = metricsEnabled
    }
}

#endif
