#if Server
import Foundation
import ManifoldInference

/// Public (v0.71+): the host-configurable knobs for
/// ``ManifoldServer/serve(configuration:backendProvider:)``. A `nil`/empty
/// `apiKey` means anonymous access, mirroring the CLI's `--allow-anonymous`
/// behavior — there is no separate `allowAnonymous` flag because `ServerApp`
/// derives it from `apiKey` alone (see its `authMiddleware` init logic).
public struct ServerConfiguration: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var apiKey: String?
    public var parallelSlots: Int
    public var unsafeCORS: Bool
    public var corsOrigin: String?
    public var metricsEnabled: Bool
    /// Maximum HTTP request body size accepted by the server in bytes.
    /// Requests whose body exceeds this limit are rejected with 413 before any
    /// handler logic runs. Defaults to the value in ``ManifoldConfiguration``.
    public var maxServerRequestBodyBytes: Int

    public init(
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
