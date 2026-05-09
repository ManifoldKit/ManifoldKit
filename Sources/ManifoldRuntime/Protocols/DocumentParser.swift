import Foundation

/// Extracts plain text from a document at a given URL.
///
/// ``RAGService`` selects the appropriate parser by matching the URL's
/// `pathExtension` against each parser's ``supportedExtensions``. Built-in
/// parsers handle plain text and PDF; custom parsers can be injected into
/// ``RAGService/init(documentStore:vectorStore:embeddingBackend:chunker:parsers:)``.
public protocol DocumentParser: Sendable {
    /// Lowercase file extensions this parser handles (without leading dot).
    var supportedExtensions: Set<String> { get }
    func parse(url: URL) async throws -> String
}

/// Errors thrown by document parsers.
public enum DocumentParserError: LocalizedError {
    case unsupportedFileType(String)
    case readFailed(underlying: Error)
    case parseFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFileType(let ext):
            return "No parser available for file type: .\(ext)"
        case .readFailed(let error):
            return "Failed to read document: \(error.localizedDescription)"
        case .parseFailed(let error):
            return "Failed to parse document: \(error.localizedDescription)"
        }
    }
}
