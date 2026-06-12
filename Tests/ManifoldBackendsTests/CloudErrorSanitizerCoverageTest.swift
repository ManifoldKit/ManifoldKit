#if CloudSaaS || Ollama
import XCTest
@testable import ManifoldCloudCore

/// Phase 2/B envelope guard: every cloud backend's error-emit path must
/// route through `CloudErrorSanitizer` so upstream provider error bodies
/// (which sometimes echo prompt content, auth headers, or stack traces)
/// never leak to UI / logs unredacted.
///
/// Modelled as a source-level audit — every `*Backend.swift` file in
/// `Sources/ManifoldCloud` that surfaces error text on a non-2xx path
/// must reference `CloudErrorSanitizer` (or call into a helper that does,
/// expressed by the helper's name in the audit's symbol allowlist below).
/// Phase 3 upgrades this to a runtime contract by adding a sentinel-mode
/// `CloudErrorSanitizer` hook the test can install and assert observed,
/// but the source-level guard catches the failure mode a runtime test
/// would: a new backend file copy-pasted without the sanitizer call.
final class CloudErrorSanitizerCoverageTest: XCTestCase {

    /// Symbols whose presence in a backend file counts as routing errors
    /// through the sanitizer. The sanitizer's direct symbol counts;
    /// so do envelope-level call sites that the backend defers to.
    private static let sanitizerSymbols: [String] = [
        "CloudErrorSanitizer",
        // SSECloudBackend's `checkStatusCode` / error helpers always
        // pipe through CloudErrorSanitizer; a backend that overrides those
        // and routes via `super.` is still covered.
        "super.checkStatusCode",
        "super.sanitize",
        // Subclasses of `SSECloudBackend` inherit the envelope-level error
        // surface. The class header is the contract: the envelope owns
        // `checkStatusCode` and pipes through `CloudErrorSanitizer`, so a
        // subclass that doesn't override it is automatically covered.
        ": SSECloudBackend",
        // The Anthropic-style error decoder used in `ClaudeBackend` routes
        // through `parseCloudErrorMessage` which is itself sanitized.
        "parseCloudErrorMessage",
    ]

    /// Files exempt from the audit. Adapter / encoder / payload-handler
    /// files do not own the error surface — `SSECloudBackend` does.
    /// (ClaudePayloadParser.swift and OllamaPayloadHandler.swift were
    ///  deleted in Phase 5 — their contents moved into the respective
    ///  stream-extractor files.)
    private static let exemptFiles: Set<String> = [
        "OllamaModelListService.swift",
        "OllamaModelProbe.swift",
        "OllamaStreamEventExtractor.swift",
        "OllamaAdapter.swift",
        "CloudHTTPProviderAdapter.swift",
        "CloudMessageEncoder.swift",
        "CloudPayloadHandler.swift",
        "OpenAIAdapter.swift",
        "OpenAIStreamEventExtractor.swift",
        "OpenAIToolEncoding.swift",
    ]

    func test_everyBackend_routesErrorsThroughSanitizer() throws {
        let files = try Self.locateCloudSourceDirs().flatMap(Self.enumerateSwiftFiles(under:))

        var offenders: [String] = []
        for fileURL in files {
            let name = fileURL.lastPathComponent
            if Self.exemptFiles.contains(name) { continue }
            guard name.hasSuffix("Backend.swift") else { continue }

            let content = try String(contentsOf: fileURL, encoding: .utf8)
            // Strip comments to avoid false positives on docstring mentions.
            let lines = content.components(separatedBy: "\n").filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.hasPrefix("//") && !t.hasPrefix("///") && !t.hasPrefix("*")
            }
            let body = lines.joined(separator: "\n")
            let routesThroughSanitizer = Self.sanitizerSymbols.contains { body.contains($0) }
            if !routesThroughSanitizer {
                offenders.append(name)
            }
        }

        if !offenders.isEmpty {
            XCTFail("""
                Backend file(s) do not route errors through
                `CloudErrorSanitizer`. Upstream error bodies can echo
                prompt content, auth headers, or stack traces; the
                sanitizer redacts them before they reach UI or logs.
                Either call `CloudErrorSanitizer.sanitize(...)` directly,
                defer to `super.checkStatusCode(...)` in `SSECloudBackend`,
                or migrate the backend to the adapter path where the
                envelope owns the error surface.
                Offenders:
                \(offenders.map { "  - \($0)" }.joined(separator: "\n"))
                """)
        }
    }

    // MARK: - Filesystem discovery

    /// The v0.48 product split spread the cloud backends across three
    /// targets; the audit walks all of them.
    private static let cloudSourceDirNames = [
        "Sources/ManifoldCloud",
        "Sources/ManifoldOllama",
        "Sources/ManifoldCloudSaaS",
    ]

    private static func locateCloudSourceDirs() throws -> [URL] {
        var probe = URL(fileURLWithPath: #file)
        for _ in 0..<8 {
            probe.deleteLastPathComponent()
            let dirs = cloudSourceDirNames.map { probe.appendingPathComponent($0, isDirectory: true) }
            if dirs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) { return dirs }
        }
        XCTFail("Could not locate the cloud source directories")
        return []
    }

    private static func enumerateSwiftFiles(under root: URL) throws -> [URL] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        return contents.filter { $0.pathExtension == "swift" }
    }
}
#endif
