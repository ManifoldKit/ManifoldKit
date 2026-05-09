import Foundation

/// Reads plain-text and Markdown files as UTF-8 strings.
public struct TextDocumentParser: DocumentParser {
    public let supportedExtensions: Set<String> = ["txt", "md", "markdown"]

    public init() {}

    public func parse(url: URL) async throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw DocumentParserError.readFailed(underlying: error)
        }
    }
}
