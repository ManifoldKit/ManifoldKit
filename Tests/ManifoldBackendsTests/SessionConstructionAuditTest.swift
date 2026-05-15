import XCTest

/// Phase 2 audit: forbids `URLSession(` construction anywhere under
/// `Sources/ManifoldCloud/` and `Sources/ManifoldCloudCore/` except in the
/// single centralised seam (`URLSessionProvider.swift`).
///
/// ## Why a second URLSession audit alongside `DirectURLSessionConstructionAuditTest`?
///
/// `DirectURLSessionConstructionAuditTest` is repo-wide and allows
/// non-cloud test-support fakes. This audit is the cloud-side counterpart:
/// it enforces the stricter Phase 2 invariant that per-provider backends
/// (OpenAI, Claude, Ollama, OpenAIResponses) and any future adapter file
/// route URLSession construction through `URLSessionProvider` — the only
/// place pinning, DNS-rebind guarding, redirect capping, and credential
/// header stripping are installed. Modelled on
/// `DirectURLSessionConstructionAuditTest`.
///
/// **Exact-set assertion**: the allowlist is a fixed set, not a "≤N
/// occurrences" cap, so a new file leaking a `URLSession(` constructor
/// fails the test immediately rather than slipping under a numeric
/// threshold.
final class SessionConstructionAuditTest: XCTestCase {

    /// Relative paths (under `Sources/`) permitted to call `URLSession(`
    /// directly. The pinning seam is the only entry today; adding a new
    /// entry must be reviewed against the security envelope.
    private static let allowlistedRelativePaths: Set<String> = [
        // The pinned-session factory: installs `PinnedSessionDelegate`
        // and the redirect guard. Every cloud backend resolves its
        // `URLSession` through here.
        "ManifoldCloudCore/URLSessionProvider.swift",
    ]

    func test_cloudSourcesContainNoUnauthorisedURLSessionConstruction() throws {
        let cloudRoots = try Self.locateCloudSourceRoots()
        XCTAssertFalse(cloudRoots.isEmpty, "Cloud source roots not found")

        var offenders: [(file: String, line: Int, text: String)] = []
        for root in cloudRoots {
            let swiftFiles = try Self.enumerateSwiftFiles(under: root.url)
            for fileURL in swiftFiles {
                let rel = "\(root.name)/" + fileURL.path
                    .replacingOccurrences(of: root.url.path + "/", with: "")
                if Self.allowlistedRelativePaths.contains(rel) { continue }
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                for (idx, raw) in content.components(separatedBy: "\n").enumerated() {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    if Self.lineConstructsURLSession(line) {
                        offenders.append((file: rel, line: idx + 1, text: line))
                    }
                }
            }
        }

        if !offenders.isEmpty {
            let listing = offenders.map { "  \($0.file):\($0.line) — \($0.text)" }.joined(separator: "\n")
            XCTFail("""
                Unauthorized URLSession construction in cloud sources.
                Pinning + DNS-rebind + redirect-guard live on URLSessionProvider;
                routing around that seam bypasses the security envelope.
                Offenders:
                \(listing)
                """)
        }
    }

    // MARK: - Substring check

    private static func lineConstructsURLSession(_ line: String) -> Bool {
        guard line.contains("URLSession(") else { return false }
        // Skip comments.
        if line.hasPrefix("//") || line.hasPrefix("///") { return false }
        // Skip docs and string-interp references.
        if line.contains("`URLSession(`") { return false }
        return true
    }

    // MARK: - Filesystem discovery

    private struct SourceRoot {
        let name: String
        let url: URL
    }

    private static func locateCloudSourceRoots() throws -> [SourceRoot] {
        var probe = URL(fileURLWithPath: #file)
        for _ in 0..<8 {
            probe.deleteLastPathComponent()
            let sources = probe.appendingPathComponent("Sources", isDirectory: true)
            let cloud = sources.appendingPathComponent("ManifoldCloud", isDirectory: true)
            let core = sources.appendingPathComponent("ManifoldCloudCore", isDirectory: true)
            if FileManager.default.fileExists(atPath: cloud.path) &&
               FileManager.default.fileExists(atPath: core.path) {
                return [
                    SourceRoot(name: "ManifoldCloud", url: cloud),
                    SourceRoot(name: "ManifoldCloudCore", url: core),
                ]
            }
        }
        return []
    }

    private static func enumerateSwiftFiles(under root: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var out: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension == "swift" { out.append(url) }
        }
        return out
    }
}
