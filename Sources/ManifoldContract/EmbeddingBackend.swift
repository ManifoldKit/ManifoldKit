import Foundation

public protocol EmbeddingBackend: AnyObject, Sendable {
    var isModelLoaded: Bool { get }
    var dimensions: Int { get }
    func loadModel(from url: URL) async throws
    func embed(_ texts: [String]) async throws -> [[Float]]
    func unloadModel()
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
