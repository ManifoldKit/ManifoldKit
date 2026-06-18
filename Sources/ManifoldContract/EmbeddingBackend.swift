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

/// Common interface for text-embedding backends.
///
/// Each backend wraps a different sentence-embedding engine (Apple
/// `NaturalLanguage`, an on-device MLX/llama embedder, a remote Ollama
/// embedder, …) and exposes the same async API. RAG retrieval delegates all
/// embedding work here through the injected conformer; when none is supplied,
/// `ManifoldBootstrap` resolves the bundled `NLEmbeddingBackend`.
///
/// ## Thread Safety
///
/// Conformers are `Sendable` and their methods may be called from **any**
/// thread. There is no service-level serialization analogous to
/// `InferenceBackend`'s generation queue: a host may invoke ``embed(_:)``
/// concurrently with itself (RAG indexing batches in parallel) and with
/// ``loadModel(from:)`` / ``unloadModel()`` arriving from a different actor.
/// Conformers with mutable state **must** provide their own synchronization
/// (an `actor`, an `NSLock`, or genuinely immutable state).
///
/// Existing conformers either hold immutable/thread-safe state and declare
/// `@unchecked Sendable` (`NLEmbeddingBackend`, `OllamaEmbeddingBackend`) or
/// rely on actor isolation. Custom conformers should follow the same pattern.
public protocol EmbeddingBackend: AnyObject, Sendable {
    var isModelLoaded: Bool { get }

    /// The dimensionality of vectors produced by ``embed(_:)``.
    ///
    /// **Precondition: only defined after a successful ``loadModel(from:)``** —
    /// i.e. when ``isModelLoaded`` is `true`. Reading `dimensions` before a
    /// model is loaded is backend-defined and carries no contract: a backend
    /// may return `0`, a placeholder, or its model-independent default, and
    /// consumers must not depend on the value until ``isModelLoaded`` is `true`.
    var dimensions: Int { get }

    /// Static capabilities of this backend (batch/input bounds, normalization).
    ///
    /// A default implementation returns ``EmbeddingCapabilities/default``, so
    /// existing conformers need not implement this.
    var capabilities: EmbeddingCapabilities { get }

    func loadModel(from url: URL) async throws

    /// Produces one embedding vector per input text.
    ///
    /// - Postcondition (guaranteed): on normal return the result has exactly
    ///   one vector per input (`result.count == texts.count`), in input order,
    ///   each of length ``dimensions``. Callers may zip the result against the
    ///   input array without a length check.
    /// - The guarantee holds **only** on non-throwing return. A backend that
    ///   cannot satisfy the per-input count or vector length does **not**
    ///   silently return a short/ragged array — it throws
    ///   ``EmbeddingError/dimensionMismatch(expected:actual:)`` (partial
    ///   mitigation: the error surfaces the violation rather than letting a
    ///   mismatched array propagate into RAG index math). Other failures throw
    ///   ``EmbeddingError/modelNotLoaded`` or
    ///   ``EmbeddingError/encodingFailed(underlying:)``.
    func embed(_ texts: [String]) async throws -> [[Float]]

    func unloadModel()
}

public extension EmbeddingBackend {
    var capabilities: EmbeddingCapabilities { .default }
}

/// Errors thrown by ``EmbeddingBackend`` operations.
public enum EmbeddingError: LocalizedError {
    /// ``EmbeddingBackend/embed(_:)`` was called before a successful
    /// ``EmbeddingBackend/loadModel(from:)``.
    case modelNotLoaded
    /// A produced vector did not have the expected length, or the result had a
    /// different count than the input. Signals a violated ``EmbeddingBackend``
    /// postcondition instead of returning a mismatched array.
    case dimensionMismatch(expected: Int, actual: Int)
    /// The underlying engine failed to encode one of the input texts; the
    /// original error is preserved for diagnostics.
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
