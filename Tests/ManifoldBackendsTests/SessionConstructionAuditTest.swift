import XCTest
import Darwin

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
///
/// The detection logic lives in ``offenders(underRoots:)`` so the in-file
/// sabotage test exercises the exact function the audit runs — not a copy.
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

        let offenders = try Self.offenders(underRoots: cloudRoots)

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

    // MARK: - Sabotage (exercises the same `offenders(underRoots:)` the audit runs)

    /// Plants an unauthorised `URLSession(` constructor in a temp tree shaped
    /// like a cloud source root and asserts the REAL detection function flags
    /// it — and that the allowlisted seam path stays exempt.
    func test_sabotage_detectsUnauthorisedURLSessionConstruction() throws {
        let tmp = try Self.makeSabotageTempDirectory(
            name: "session-construction-sabotage-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = tmp.appendingPathComponent("ManifoldCloudSaaS", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        import Foundation
        // Deliberately constructs URLSession outside the seam.
        let session = URLSession(configuration: .default)
        """.write(to: root.appendingPathComponent("BadBackend.swift"), atomically: true, encoding: .utf8)

        let offenders = try Self.offenders(underRoots: [SourceRoot(name: "ManifoldCloudSaaS", url: root)])
        XCTAssertEqual(offenders.count, 1, "The planted URLSession( constructor must be flagged")
        XCTAssertEqual(offenders.first?.file, "ManifoldCloudSaaS/BadBackend.swift")

        // The allowlisted seam path must stay exempt for the same content.
        let coreRoot = tmp.appendingPathComponent("ManifoldCloudCore", isDirectory: true)
        try FileManager.default.createDirectory(at: coreRoot, withIntermediateDirectories: true)
        try """
        let session = URLSession(configuration: .default)
        """.write(to: coreRoot.appendingPathComponent("URLSessionProvider.swift"), atomically: true, encoding: .utf8)
        let seamOffenders = try Self.offenders(underRoots: [SourceRoot(name: "ManifoldCloudCore", url: coreRoot)])
        XCTAssertTrue(seamOffenders.isEmpty, "The allowlisted seam must not be flagged")
    }

    // MARK: - Detection

    static func offenders(
        underRoots roots: [SourceRoot]
    ) throws -> [(file: String, line: Int, text: String)] {
        var offenders: [(file: String, line: Int, text: String)] = []
        for root in roots {
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
        return offenders
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

    struct SourceRoot {
        let name: String
        let url: URL
    }

    private static func locateCloudSourceRoots() throws -> [SourceRoot] {
        var probe = URL(fileURLWithPath: #file)
        for _ in 0..<8 {
            probe.deleteLastPathComponent()
            let sources = probe.appendingPathComponent("Sources", isDirectory: true)
            // v0.48 product split: the audit covers all four cloud targets.
            let names = ["ManifoldCloudCore", "ManifoldOllama", "ManifoldCloudSaaS"]
            let roots = names.map {
                SourceRoot(name: $0, url: sources.appendingPathComponent($0, isDirectory: true))
            }
            if roots.allSatisfy({ FileManager.default.fileExists(atPath: $0.url.path) }) {
                return roots
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

    /// Builds a fresh, UUID-suffixed temp directory and returns it fully
    /// resolved via POSIX `realpath()`. `/var` (macOS's temp-dir root) is an
    /// APFS firmlink to `/private/var`, not a classic symlink — so
    /// `URL.resolvingSymlinksInPath()` leaves it untouched while
    /// `FileManager`'s directory enumerator returns the fully-resolved
    /// `/private/var/...` form for every child it walks. Without this,
    /// string-prefix stripping of `root.path` against an enumerated child's
    /// `.path` silently fails to match (the prefixes differ), corrupting
    /// every relative-path fingerprint this sabotage test asserts against.
    private static func makeSabotageTempDirectory(name: String) throws -> URL {
        let unresolved = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(unresolved.path, &buffer) != nil else { return unresolved }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

}
