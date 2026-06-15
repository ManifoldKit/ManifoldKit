import Foundation

/// Static capabilities advertised by an ``EmbeddingBackend``.
///
/// All fields have safe defaults, so a backend that does not advertise anything
/// specific reports ``EmbeddingCapabilities/default``. Consumers should treat a
/// `nil` bound as "unspecified / unbounded" rather than zero.
public struct EmbeddingCapabilities: Sendable, Codable, Equatable, Hashable {
    /// Maximum number of texts accepted in a single ``EmbeddingBackend/embed(_:)``
    /// call. `nil` means unspecified / unbounded.
    public var maxBatchSize: Int?

    /// Maximum number of tokens per input text. `nil` means unspecified.
    public var maxInputLength: Int?

    /// Whether the backend returns L2-normalized (unit-length) vectors. Defaults
    /// to `false`; consumers that require normalized vectors must normalize
    /// themselves when this is `false`.
    public var producesNormalizedVectors: Bool

    public init(
        maxBatchSize: Int? = nil,
        maxInputLength: Int? = nil,
        producesNormalizedVectors: Bool = false
    ) {
        self.maxBatchSize = maxBatchSize
        self.maxInputLength = maxInputLength
        self.producesNormalizedVectors = producesNormalizedVectors
    }

    /// The conservative default: no advertised bounds, vectors not normalized.
    public static let `default` = EmbeddingCapabilities()
}

public protocol EmbeddingBackend: AnyObject, Sendable {
    var isModelLoaded: Bool { get }

    /// The dimensionality of vectors produced by ``embed(_:)``.
    ///
    /// Only meaningful after a successful ``loadModel(from:)`` — i.e. when
    /// ``isModelLoaded`` is `true`. Behavior before a model is loaded is
    /// backend-defined (a backend may return `0`, a placeholder, or its
    /// model-independent default).
    var dimensions: Int { get }

    /// Static capabilities of this backend (batch/input bounds, normalization).
    ///
    /// A default implementation returns ``EmbeddingCapabilities/default``, so
    /// existing conformers need not implement this.
    var capabilities: EmbeddingCapabilities { get }

    func loadModel(from url: URL) async throws

    /// Produces one embedding vector per input text.
    ///
    /// - Postcondition: the returned array has exactly one vector per input
    ///   (`result.count == texts.count`), each of length ``dimensions``. A
    ///   backend that cannot satisfy this signals the violation by throwing
    ///   ``EmbeddingError/dimensionMismatch(expected:actual:)``.
    func embed(_ texts: [String]) async throws -> [[Float]]

    func unloadModel()
}

public extension EmbeddingBackend {
    var capabilities: EmbeddingCapabilities { .default }
}

public enum EmbeddingError: LocalizedError {
    case modelNotLoaded
    case dimensionMismatch(expected: Int, actual: Int)
    case encodingFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Embedding model is not loaded."
        case .dimensionMismatch(let expected, let actual):
            return "Dimension mismatch: expected \(expected), got \(actual)."
        case .encodingFailed(let underlying):
            return "Text encoding failed: \(underlying.localizedDescription)"
        }
    }
}
