import ArgumentParser
import BaseChatServerCore
import Foundation

package struct ServerCommandOptions: ParsableArguments, Sendable {
    @Option(help: "Host interface to bind.")
    package var host = "127.0.0.1"

    @Option(help: "Port to bind.")
    package var port = 8080

    @Option(help: "API key required by the server for incoming requests.")
    package var apiKey: String?

    @Option(help: "Maximum number of concurrent generation requests.")
    package var parallel = 1

    @Option(help: "Backend to load: mlx, llama, foundation, ollama, or cloud.")
    package var backend: ServerBackendKind = .foundation

    @Option(help: "Model name or identifier for the selected backend.")
    package var model: String?

    @Option(help: "Path to a local model file or directory.")
    package var modelPath: String?

    @Option(help: "Ollama server base URL.")
    package var ollamaBaseURL = "http://localhost:11434"

    @Flag(help: "Allow any CORS origin. Intended only for trusted local development.")
    package var unsafeCORS = false

    @Option(help: "Allowed CORS origin. Repeat server startup with --unsafe-cors only for development.")
    package var corsOrigin: String?

    @Flag(help: "Enable server metrics endpoints when HTTP routing is available.")
    package var metrics = false

    package init() {}

    package static func == (lhs: ServerCommandOptions, rhs: ServerCommandOptions) -> Bool {
        lhs.host == rhs.host
            && lhs.port == rhs.port
            && lhs.apiKey == rhs.apiKey
            && lhs.parallel == rhs.parallel
            && lhs.backend == rhs.backend
            && lhs.model == rhs.model
            && lhs.modelPath == rhs.modelPath
            && lhs.ollamaBaseURL == rhs.ollamaBaseURL
            && lhs.unsafeCORS == rhs.unsafeCORS
            && lhs.corsOrigin == rhs.corsOrigin
            && lhs.metrics == rhs.metrics
    }

    package func validate() throws {
        guard (1...65_535).contains(port) else {
            throw ValidationError("--port must be between 1 and 65535")
        }
        guard parallel > 0 else {
            throw ValidationError("--parallel must be greater than zero")
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

    package func serverConfiguration() -> ServerConfiguration {
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

    package func backendSelection() -> ServerBackendSelection {
        ServerBackendSelection(
            backend: backend,
            model: model,
            modelPath: modelPath,
            ollamaBaseURL: ollamaBaseURL
        )
    }
}
