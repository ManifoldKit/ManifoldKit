#if Ollama
import Foundation
import os
import ManifoldInference
import ManifoldCloudCore

/// A model available on a remote inference server.
public struct RemoteModelInfo: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let sizeBytes: Int64?
    public let quantization: String?
    public let familyTag: String?

    public init(
        id: String? = nil,
        name: String,
        sizeBytes: Int64? = nil,
        quantization: String? = nil,
        familyTag: String? = nil
    ) {
        self.id = id ?? name
        self.name = name
        self.sizeBytes = sizeBytes
        self.quantization = quantization
        self.familyTag = familyTag
    }
}

/// Fetches the list of locally available models from an Ollama server.
///
/// Calls `GET /api/tags` and returns an array of ``RemoteModelInfo`` values
/// that can be presented in a picker or passed to ``OllamaBackend/configure(baseURL:modelName:)``.
///
/// Usage:
/// ```swift
/// let service = OllamaModelListService()
/// let models = try await service.fetchModels(from: URL(string: "http://localhost:11434")!)
/// ```
public final class OllamaModelListService: Sendable {

    private static let logger = Logger(
        subsystem: ManifoldConfiguration.shared.logSubsystem,
        category: "network"
    )

    private let urlSession: URLSession

    public init(urlSession: URLSession? = nil) {
        if let urlSession {
            self.urlSession = urlSession
        } else {
            // Route through the centralised provider so the redirect guard is
            // installed. The provider's `unpinned` accessor uses 300s/600s
            // timeouts; the previous bespoke 10s request timeout was tighter
            // than the ambient cloud-call default and caused spurious
            // "request timed out" errors against slow LAN Ollama hosts. The
            // provider's larger window matches the rest of the cloud stack.
            self.urlSession = URLSessionProvider.unpinned
        }
    }

    /// Fetches models available on the given Ollama server.
    ///
    /// - Parameter baseURL: The server base URL (e.g. `http://localhost:11434`).
    /// - Returns: An array of available models, sorted alphabetically by name.
    /// - Throws: ``CloudBackendError`` on HTTP or network failure.
    public func fetchModels(from baseURL: URL) async throws -> [RemoteModelInfo] {
        try await DNSRebindingGuard.validate(url: baseURL)

        let tagsURL = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: tagsURL)
        request.httpMethod = "GET"

        // Connect-time IP pinning closes the DNS-rebinding TOCTOU the pre-flight
        // `DNSRebindingGuard.validate(url:)` above cannot — it checks the address
        // URLSession actually connected to (see ConnectAddressPinningDelegate).
        let (data, response) = try await ConnectAddressPinningDelegate.pinnedData(for: request, on: urlSession)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudBackendError.networkError(
                underlying: ManifoldKitError.serverError(
                    statusCode: 0,
                    message: "Malformed server response"
                )
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw CloudBackendError.serverError(
                statusCode: httpResponse.statusCode,
                message: "Failed to fetch Ollama model list (status \(httpResponse.statusCode))"
            )
        }

        return try parseModels(from: data)
    }

    // MARK: - Parsing

    private struct OllamaTagsResponse: Decodable {
        struct Model: Decodable {
            let name: String
            let size: Int64?
            // digest, modified_at etc. ignored
        }
        let models: [Model]?
    }

    private func parseModels(from data: Data) throws -> [RemoteModelInfo] {
        let response = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        let models = response.models ?? []

        return models
            .map { model in
                let parts = model.name.split(separator: ":", maxSplits: 1)
                let quantization = parts.count > 1 ? String(parts[1]) : nil
                return RemoteModelInfo(
                    name: model.name,
                    sizeBytes: model.size,
                    quantization: quantization
                )
            }
            .sorted { $0.name < $1.name }
    }
}

#endif
