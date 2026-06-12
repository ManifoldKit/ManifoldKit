import XCTest

/// Phase 2 audit: every cloud `*Backend.swift` file must either compose a
/// `CloudHTTPProviderAdapter` *or* appear in the TODO-allowlist of files
/// still on the legacy path.
///
/// The Phase 2 migration is staged: the adapter protocol and witness
/// scaffolding ship now, OpenAI moves to the adapter path in Phase 2/B,
/// Claude/Ollama/OpenAIResponses migrate in Phase 3. This audit ratchets:
///
/// 1. **Phase 2/A (this PR)**: all four `*Backend.swift` files are
///    allowlisted with a TODO sentinel. The audit's value here is that a
///    *new* cloud backend file (e.g. `GeminiBackend.swift`, the kind that
///    historically got added by copy-paste from `OllamaBackend.swift`)
///    will fail this test immediately if it doesn't either compose an
///    adapter or get explicitly added to the allowlist with a TODO
///    rationale.
/// 2. **Phase 2/B**: `OpenAIBackend.swift` is removed from the allowlist
///    after it routes through `OpenAIAdapter`.
/// 3. **Phase 3**: the remaining three backends drop off the allowlist.
/// 4. **Phase 4**: the allowlist is `[]`; only the adapter path remains
///    a legal way to define a cloud backend.
///
/// Modelled on `DirectURLSessionConstructionAuditTest` — file-walk plus
/// substring check plus an exact-set allowlist.
final class CloudSeamUsageAuditTest: XCTestCase {

    /// Cloud backend files still on the legacy path. Each entry carries an
    /// inline rationale; removing a file from the set means it now
    /// composes `CloudHTTPProviderAdapter`.
    private static let legacyPathAllowlist: Set<String> = [
    ]

    func test_everyCloudBackend_eitherComposesAdapter_orIsAllowlistedWithTODO() throws {
        let files = try Self.locateCloudSourceDirs().flatMap(Self.enumerateSwiftFiles(under:))

        var offenders: [String] = []
        for fileURL in files {
            let name = fileURL.lastPathComponent
            // Only audit files matching `*Backend.swift` in the top level
            // of `Sources/ManifoldCloud/` (mirrors how new providers get
            // added historically).
            guard name.hasSuffix("Backend.swift") else { continue }
            if Self.legacyPathAllowlist.contains(name) { continue }

            // Not allowlisted — must compose the adapter.
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            if !content.contains("CloudHTTPProviderAdapter") {
                offenders.append(name)
            }
        }

        if !offenders.isEmpty {
            XCTFail("""
                Cloud backend file(s) neither compose `CloudHTTPProviderAdapter`
                nor appear in the legacy-path allowlist. Add an
                `OpenAIAdapter`-style composition, OR add the file name to
                `legacyPathAllowlist` with a TODO citing the migration
                phase that will remove it.
                Offenders:
                \(offenders.map { "  - \($0)" }.joined(separator: "\n"))
                """)
        }
    }

    // MARK: - Filesystem discovery

    /// The v0.48 product split spread the cloud backends across three
    /// targets; the audit walks all of them so a new provider lands inside
    /// the net no matter which family it joins.
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
        // Top-level only — sub-folders like `Internal/` hold helper types
        // (e.g. tool-call accumulators) that aren't backends.
        let contents = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        return contents.filter { $0.pathExtension == "swift" }
    }
}
