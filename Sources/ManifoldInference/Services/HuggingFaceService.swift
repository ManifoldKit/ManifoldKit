import Foundation

// MARK: - Protocol

/// Provides HuggingFace Hub API operations (search, model info, URL construction).
///
/// Concrete implementations live in `ManifoldHuggingFace`, letting chat-only
/// builds compile against the protocol surface without pulling the downloader in.
public protocol HuggingFaceServiceProtocol: Sendable {
    /// Searches HuggingFace for text-generation models matching the query.
    ///
    /// Results include one `DownloadableModel` per downloadable file (each GGUF
    /// quant variant is a separate row; MLX repos produce a single row).
    ///
    /// - Parameters:
    ///   - query: The search string sent to the HuggingFace API.
    ///   - limit: Maximum number of repos to fetch from the API before filtering. Defaults to 40.
    func searchModels(query: String, limit: Int) async throws -> [DownloadableModel]

    /// Returns curated models appropriate for the given device size recommendation.
    func curatedModels(for recommendation: ModelSizeRecommendation) -> [DownloadableModel]

    /// Fetches all downloadable files (GGUF + MLX) for a specific HuggingFace repo.
    func getModelFiles(repoID: String) async throws -> [DownloadableModel]

    /// Resolves the concrete file download plan for a model.
    func downloadPlan(for model: DownloadableModel) async throws -> ModelDownloadPlan

    /// Constructs the direct download URL for a model file on HuggingFace.
    func downloadURL(for model: DownloadableModel) -> URL
}

public extension HuggingFaceServiceProtocol {
    /// Searches HuggingFace using the default limit of 40 repos.
    func searchModels(query: String) async throws -> [DownloadableModel] {
        try await searchModels(query: query, limit: 40)
    }

    /// Bounded reachability check against the HuggingFace Hub.
    ///
    /// Issues a `GET https://huggingface.co/api/models?limit=1` (the smallest
    /// JSON HF will return) through the same redirect-guarded
    /// ``URLSessionFactory/ephemeral(hopCap:resourceTimeout:additionalDataDelegate:)``
    /// pipeline that `searchModels` uses. HEAD was rejected by `huggingface.co`
    /// during prototyping (returns 405 on `/api/models`), so a minimal GET is
    /// used instead — the response body is read into memory but discarded.
    ///
    /// The call never throws: any failure is captured as a sanitised
    /// `failureReason` on the returned ``ProbeResult``. Latency is measured
    /// with `ContinuousClock` and includes redirect handling.
    ///
    /// - Parameter timeout: Hard wall-clock cap, in seconds. The underlying
    ///   request also receives this value as `timeoutIntervalForRequest`.
    /// - Returns: A ``ProbeResult`` describing the outcome.
    func probe(timeout: TimeInterval = 8) async -> ProbeResult {
        await HuggingFaceProbe.run(timeout: timeout)
    }
}

// MARK: - ProbeResult

/// Outcome of a ``HuggingFaceServiceProtocol/probe(timeout:)`` call.
public struct ProbeResult: Sendable, Equatable {
    /// `true` when the probe received any 2xx response from the upstream.
    public let succeeded: Bool

    /// HTTP status code if a response was received; `nil` for transport
    /// failures (DNS, TLS, connection refused, timeout, ...).
    public let httpStatus: Int?

    /// Wall-clock latency from request dispatch to response (or failure).
    public let latency: Duration

    /// Wall-clock timestamp at which the probe completed.
    public let timestamp: Date

    /// Sanitised, human-readable reason when ``succeeded`` is `false`.
    /// Never contains raw URLs, tokens, JWTs, HTML, or stack traces — the
    /// transformation mirrors `CloudErrorSanitizer` in `ManifoldCloudCore`.
    public let failureReason: String?

    public init(
        succeeded: Bool,
        httpStatus: Int?,
        latency: Duration,
        timestamp: Date,
        failureReason: String?
    ) {
        self.succeeded = succeeded
        self.httpStatus = httpStatus
        self.latency = latency
        self.timestamp = timestamp
        self.failureReason = failureReason
    }
}
