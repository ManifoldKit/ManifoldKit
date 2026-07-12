#if Server
import ArgumentParser
import Foundation

// `package` (not `internal`): referenced as the type of `ManifoldServerCommand.options`,
// which is `package` because `ManifoldServerCommand` itself is invoked from the
// `ManifoldServerCLI` executable target (see ManifoldServerCommand.swift).
package struct ServerCommandOptions: ParsableArguments, Sendable {
    @Option(help: "Host interface to bind.")
    internal var host = "127.0.0.1"

    @Option(help: "Port to bind.")
    internal var port = 8080

    @Option(help: "API key required by the server for incoming requests. Required unless --allow-anonymous is set on a loopback bind.")
    internal var apiKey: String?

    @Flag(help: "Permit unauthenticated access. Only valid when --host is loopback (127.0.0.1, localhost, or ::1). Any local process can then invoke inference.")
    internal var allowAnonymous = false

    @Option(help: "Maximum number of concurrent generation requests.")
    internal var parallel = 1

    @Option(help: "Backend to load: mlx, llama, foundation, ollama, or cloud.")
    internal var backend: ServerBackendKind = .foundation

    @Option(help: "Model name or identifier for the selected backend.")
    internal var model: String?

    @Option(help: "Path to a local model file or directory.")
    internal var modelPath: String?

    @Option(help: "Ollama server base URL.")
    internal var ollamaBaseURL = "http://localhost:11434"

    @Flag(help: "Allow any CORS origin. Intended only for trusted local development.")
    internal var unsafeCORS = false

    @Option(help: "Allowed CORS origin. Repeat server startup with --unsafe-cors only for development.")
    internal var corsOrigin: String?

    @Flag(help: "Enable server metrics endpoints when HTTP routing is available.")
    internal var metrics = false

    // package (not internal): ParsableArguments requires this witness be as
    // accessible as the enclosing (package-level) type.
    package init() {}

    internal static func == (lhs: ServerCommandOptions, rhs: ServerCommandOptions) -> Bool {
        lhs.host == rhs.host
            && lhs.port == rhs.port
            && lhs.apiKey == rhs.apiKey
            && lhs.allowAnonymous == rhs.allowAnonymous
            && lhs.parallel == rhs.parallel
            && lhs.backend == rhs.backend
            && lhs.model == rhs.model
            && lhs.modelPath == rhs.modelPath
            && lhs.ollamaBaseURL == rhs.ollamaBaseURL
            && lhs.unsafeCORS == rhs.unsafeCORS
            && lhs.corsOrigin == rhs.corsOrigin
            && lhs.metrics == rhs.metrics
    }

    /// Whether `host` is a loopback bind address (not a LAN/wildcard bind).
    internal static func isLoopbackBindHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1" {
            return true
        }
        // Full IPv4 loopback range 127.0.0.0/8
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4,
           let a = UInt8(parts[0]), a == 127,
           parts.dropFirst().allSatisfy({ UInt8($0) != nil }) {
            return true
        }
        return false
    }

    // package (not internal): ParsableArguments requires this witness be as
    // accessible as the enclosing (package-level) type.
    package func validate() throws {
        guard (1...65_535).contains(port) else {
            throw ValidationError("--port must be between 1 and 65535")
        }
        guard parallel > 0 else {
            throw ValidationError("--parallel must be greater than zero")
        }

        let hasAPIKey = !(apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        let loopback = Self.isLoopbackBindHost(host)

        if allowAnonymous && hasAPIKey {
            throw ValidationError("--allow-anonymous cannot be combined with --api-key")
        }
        if allowAnonymous && !loopback {
            throw ValidationError("--allow-anonymous is only valid for loopback binds (127.0.0.1, localhost, ::1); non-loopback hosts require --api-key")
        }
        if !hasAPIKey {
            if !loopback {
                throw ValidationError("refusing to bind \(host) without --api-key (non-loopback binds require authentication)")
            }
            if !allowAnonymous {
                throw ValidationError("refusing unauthenticated bind without --allow-anonymous (any local process can invoke inference). Pass --api-key or --allow-anonymous.")
            }
            fputs("warning: ManifoldServer started with --allow-anonymous; any process on \(host) can invoke inference without credentials\n", stderr)
        }

        if unsafeCORS, corsOrigin != nil {
            throw ValidationError("--unsafe-cors cannot be combined with --cors-origin")
        }
        if let origin = corsOrigin {
            guard let url = URL(string: origin),
                  let scheme = url.scheme, !scheme.isEmpty,
                  let host = url.host, !host.isEmpty,
                  !origin.contains("\r"), !origin.contains("\n") else {
                throw ValidationError("--cors-origin must be a valid URL with scheme and host (e.g. https://example.com)")
            }
            _ = host // suppress unused warning
        }
    }

    internal func serverConfiguration() -> ServerConfiguration {
        // maxServerRequestBodyBytes is not CLI-configurable; it flows from
        // ManifoldConfiguration.shared so host apps can set it at startup.
        // The ServerConfiguration default already reads it from there.
        ServerConfiguration(
            host: host,
            port: port,
            apiKey: apiKey,
            parallelSlots: parallel,
            unsafeCORS: unsafeCORS,
            corsOrigin: corsOrigin,
            metricsEnabled: metrics
        )
    }

    internal func backendSelection() -> ServerBackendSelection {
        ServerBackendSelection(
            backend: backend,
            model: model,
            modelPath: modelPath,
            ollamaBaseURL: ollamaBaseURL
        )
    }
}

#endif
