import XCTest

/// Lint test that fails CI when production code constructs `URLSession`
/// directly via `URLSession(configuration:)` outside the centralised
/// network seam.
///
/// ## Why
///
/// `URLSessionFactory` (and the trait-gated `URLSessionProvider`
/// accessors that wrap it) is the only place in ManifoldKit that builds a
/// `URLSession`. Every session built there has a `RedirectGuardDelegate`
/// installed, which:
///
/// - Caps the redirect chain (`hopCap`, default 3).
/// - Strips `Authorization` / `Cookie` / `X-API-*` headers on cross-origin
///   redirects so a 30x to a hostile host cannot exfiltrate credentials.
/// - Rejects redirects to private / link-local / IMDS IP ranges, mDNS
///   `.local` names, and `https → http` scheme downgrades.
///
/// A direct `URLSession(configuration:)` call elsewhere skips all of that.
/// The class of bug is severe enough — and the seam thin enough — that we
/// pin the constraint with a CI lint rather than rely on review.
///
/// ## Allowlist
///
/// The seam itself, plus test-support utilities and tests, are allowlisted
/// by relative path (within `Sources/`):
///
/// - `ManifoldInference/Networking/URLSessionFactory.swift` — the seam.
/// - `ManifoldCloudCore/URLSessionProvider.swift` — the trait-gated wrapper.
/// - `ManifoldTestSupport/**` — test fakes (e.g. `DenyAllURLProtocol`).
/// - `ManifoldMCP/MCPURLSessionFactory.swift` — MCP has its own redirect-
///   cap delegate (`MCPRedirectCapDelegate`) that every MCP request
///   installs explicitly via the `delegate:` parameter on `data(for:delegate:)`.
///   Folding it into the BCK-wide redirect guard is tracked separately;
///   for now the lint trusts the per-call delegate.
///
/// To exempt a new file, add its relative path to the `allowlistedRelativePaths`
/// set below with a one-line `#`-style comment explaining why.
final class DirectURLSessionConstructionAuditTest: XCTestCase {

    /// Relative paths (under `Sources/`) that are permitted to call
    /// `URLSession(configuration:` directly. Keep this set small — every
    /// new entry weakens the seam.
    private static let allowlistedRelativePaths: Set<String> = [
        // The seam itself: builds the redirect-guarded session every other
        // caller threads through.
        "ManifoldInference/Networking/URLSessionFactory.swift",
        // Trait-gated wrapper around the seam (pinned + unpinned accessors).
        // Moved from ManifoldBackends to ManifoldCloudCore in initiative I7.
        "ManifoldCloudCore/URLSessionProvider.swift",
        // MCP's pre-existing factory; every caller installs MCPRedirectCapDelegate
        // via the per-call `delegate:` parameter on data(for:delegate:).
        "ManifoldMCP/MCPURLSessionFactory.swift",
    ]

    /// Path prefixes (under `Sources/`) that are permitted to call
    /// `URLSession(configuration:` — used to allowlist whole directories
    /// such as test-support helpers.
    private static let allowlistedPrefixes: [String] = [
        "ManifoldTestSupport/",
    ]

    func test_sourcesContainNoUnauthorisedURLSessionConstruction() throws {
        let sourcesURL = try Self.locateSourcesDirectory()
        let swiftFiles = try Self.enumerateSwiftFiles(under: sourcesURL)
        XCTAssertFalse(swiftFiles.isEmpty, "Sources directory yielded no .swift files — path probably wrong")

        var offenders: [(file: String, line: Int, text: String)] = []
        for fileURL in swiftFiles {
            let relativePath = fileURL.path.replacingOccurrences(of: sourcesURL.path + "/", with: "")
            if Self.isAllowlisted(relativePath) { continue }

            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.components(separatedBy: "\n")
            for (index, rawLine) in lines.enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard Self.lineConstructsURLSession(line) else { continue }
                offenders.append((file: relativePath, line: index + 1, text: line))
            }
        }

        if !offenders.isEmpty {
            let formatted = offenders
                .map { "  \($0.file):\($0.line)  \($0.text)" }
                .joined(separator: "\n")
            XCTFail("""
                Direct URLSession(configuration:) construction found in production sources.
                Route the call through URLSessionProvider (ManifoldBackends) or URLSessionFactory
                (ManifoldInference) so the redirect guard is installed. If the file genuinely
                belongs at the seam, add its relative path to allowlistedRelativePaths in
                Tests/ManifoldBackendsTests/DirectURLSessionConstructionAuditTest.swift with
                a one-line comment explaining why.

                \(formatted)
                """)
        }
    }

    // MARK: - Helpers

    /// Returns `true` if the line contains a `URLSession(configuration:`
    /// call that should be flagged. Excludes comment lines, doc comments,
    /// and any line that mentions the call inside a string literal — for
    /// the latter, the simple-substring heuristic is sufficient because
    /// the seam does not log call-site text.
    static func lineConstructsURLSession(_ line: String) -> Bool {
        if line.hasPrefix("//") || line.hasPrefix("///") || line.hasPrefix("*") || line.hasPrefix("*/") {
            return false
        }
        return line.contains("URLSession(configuration:")
    }

    static func isAllowlisted(_ relativePath: String) -> Bool {
        if allowlistedRelativePaths.contains(relativePath) {
            return true
        }
        for prefix in allowlistedPrefixes where relativePath.hasPrefix(prefix) {
            return true
        }
        return false
    }

    /// Walks upward from the test file to find the repo root, then returns
    /// the `Sources/` subdirectory. Mirrors `SilentCatchAuditTest` so the
    /// audit pattern stays consistent across BCK.
    static func locateSourcesDirectory(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Sources")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "DirectURLSessionConstructionAuditTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Sources/ from #filePath"
        ])
    }

    static func enumerateSwiftFiles(under root: URL) throws -> [URL] {
        var result: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for case let url as URL in enumerator {
            if url.pathExtension == "swift" {
                let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                if isRegular { result.append(url) }
            }
        }
        return result
    }
}
