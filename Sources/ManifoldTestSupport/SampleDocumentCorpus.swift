import Foundation

/// The bundled sample Markdown corpus the Glass Box research-session demo
/// ingests into the real RAG stack (#1575).
///
/// The documents are short, real-ish passages about photosynthesis so semantic
/// retrieval has coherent content to match the flagship scenario's questions
/// ("What is photosynthesis?", "How does the light-dependent reaction work?",
/// "What role does chlorophyll play?", ...).
///
/// Files live under `Sources/ManifoldTestSupport/Fixtures/Documents/` and are
/// bundled via `Bundle.module` (see the `resources:` entry in Package.swift).
public enum SampleDocumentCorpus {

    /// File names (without directory) of the bundled corpus, in a stable order.
    public static let fileNames = [
        "photosynthesis.md",
        "light-dependent-reactions.md",
        "chlorophyll.md",
        "calvin-cycle.md",
    ]

    /// Resolves the bundled corpus to on-disk URLs.
    ///
    /// Returns the URLs of every document in ``fileNames`` that resolves inside
    /// `Bundle.module`. The array is empty only if the resources failed to
    /// bundle — callers ingesting for a demo should treat an empty result as a
    /// configuration error.
    public static func documentURLs() -> [URL] {
        documentURLs(in: .module)
    }

    static func documentURLs(in bundle: Bundle) -> [URL] {
        guard let dir = bundle.url(
            forResource: "Documents",
            withExtension: nil,
            subdirectory: "Fixtures"
        ) ?? bundle.url(forResource: "Documents", withExtension: nil) else {
            return []
        }
        return fileNames.compactMap { name in
            let url = dir.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }
}
