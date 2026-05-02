#if Server
import Foundation

package struct ServerConfiguration: Equatable, Sendable {
    package var host: String
    package var port: Int
    package var apiKey: String?
    package var parallelSlots: Int
    package var unsafeCORS: Bool
    package var corsOrigin: String?
    package var metricsEnabled: Bool

    package init(
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
