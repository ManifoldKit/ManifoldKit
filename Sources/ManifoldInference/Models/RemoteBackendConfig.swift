import Foundation

/// Configuration for a remote inference backend.
///
/// Passed to ``OpenAIBackend``, ``OllamaBackend``, or ``ClaudeBackend``
/// when connecting to a self-hosted or third-party server.
///
/// The API key is optional — local servers such as Ollama and LM Studio
/// typically require no authentication.
public struct RemoteBackendConfig: Sendable, Hashable {
    /// The base URL of the server (e.g. `http://192.168.1.10:11434`).
    public let baseURL: URL

    /// Optional API key sent as a `Bearer` token in the `Authorization` header.
    public let apiKey: String?

    /// Maximum time (seconds) to wait for bytes between SSE chunks.
    /// Defaults to 300 s — long enough for slow LLM generation.
    public let timeout: TimeInterval

    /// Optional model name override. When `nil` the backend uses its own
    /// default (e.g. whatever model the server has loaded).
    public let modelName: String?

    public init(
        baseURL: URL,
        apiKey: String? = nil,
        timeout: TimeInterval = 300,
        modelName: String? = nil
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeout = timeout
        self.modelName = modelName
    }
}
