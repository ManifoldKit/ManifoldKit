import Foundation
import PDFKit

/// Extracts plain text from PDF documents using PDFKit.
///
/// Text is extracted page by page and joined with newlines. Scanned PDFs
/// without embedded text return an empty string — OCR is out of scope for v1.
public struct PDFDocumentParser: DocumentParser {
    public let supportedExtensions: Set<String> = ["pdf"]

    public init() {}

    public func parse(url: URL) async throws -> String {
        guard let pdf = PDFDocument(url: url) else {
            throw DocumentParserError.parseFailed(
                underlying: CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
            )
        }

        var pages: [String] = []
        for i in 0..<pdf.pageCount {
            if let page = pdf.page(at: i), let text = page.string {
                pages.append(text)
            }
        }

        return pages.joined(separator: "\n")
    }
}
