#if Server
import Foundation
import ManifoldInference

internal struct ServerConfiguration: Equatable, Sendable {
    internal var host: String
    internal var port: Int
    internal var apiKey: String?
    internal var parallelSlots: Int
    internal var unsafeCORS: Bool
    internal var corsOrigin: String?
    internal var metricsEnabled: Bool
    /// Maximum HTTP request body size accepted by the server in bytes.
    /// Requests whose body exceeds this limit are rejected with 413 before any
    /// handler logic runs. Defaults to the value in ``ManifoldConfiguration``.
    internal var maxServerRequestBodyBytes: Int

    internal init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        apiKey: String? = nil,
        parallelSlots: Int = 1,
        unsafeCORS: Bool = false,
        corsOrigin: String? = nil,
        metricsEnabled: Bool = false,
        maxServerRequestBodyBytes: Int = ManifoldConfiguration.shared.maxServerRequestBodyBytes
    ) {
        self.host = host
        self.port = port
        self.apiKey = apiKey
        self.parallelSlots = parallelSlots
        self.unsafeCORS = unsafeCORS
        self.corsOrigin = corsOrigin
        self.metricsEnabled = metricsEnabled
        self.maxServerRequestBodyBytes = maxServerRequestBodyBytes
    }
}

#endif
