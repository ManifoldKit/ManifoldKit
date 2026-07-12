import XCTest

/// Lint test enforcing the post-I7 backend-target topology.
///
/// ## Why
///
/// Initiative I7 split `Sources/ManifoldBackends/` into five trait-gated
/// source targets (`ManifoldCloudCore`, `ManifoldMLX`, `ManifoldLlama`,
/// `ManifoldFoundation`, `ManifoldCloud`) plus a thin re-export umbrella
/// (`Sources/ManifoldBackendsUmbrella/` backing the legacy `ManifoldBackends`
/// module name). The split eliminated three `*Stub.swift` files
/// (`ClaudeBackendStub`, `OpenAIBackendStub`, `OllamaBackendStub`) that
/// existed only to keep the link alive when traits flipped families off.
///
/// A future refactor that re-introduces a stub or re-merges a family into
/// `Sources/ManifoldBackendsUmbrella/` would silently undo the split. This
/// test pins the file-tree shape so that regression surfaces in CI rather
/// than only in build-time bloat.
///
/// ## What it checks
///
/// 1. The three deleted stub filenames do not exist anywhere under
///    `Sources/`.
/// 2. The expected family-target source directories exist.
/// 3. The umbrella source directory contains the registrar glue but does
///    NOT contain the moved family backend files.
///
/// The detection logic lives in ``stubViolations(sourcesRoot:)``,
/// ``missingFamilyDirs(sourcesRoot:)``, ``resurrectedShimDirs(sourcesRoot:)``,
/// and ``droppedRegistrarViolations(sourcesRoot:)`` so the in-file sabotage
/// test exercises the exact functions the audit runs.
final class PackageTopologyAuditTest: XCTestCase {

    private var sourcesRoot: URL {
        // `#filePath` resolves to this test file. Walk up to the package root.
        let here = URL(fileURLWithPath: #filePath)
        // Tests/ManifoldBackendsTests/<this>.swift -> repo root
        return here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    func test_deletedStubFiles_doNotExist() {
        let violations = Self.stubViolations(sourcesRoot: sourcesRoot)
        XCTAssertTrue(
            violations.isEmpty,
            "Stub file(s) were deleted in initiative I7 (split into \(Self.expectedFamilyTargetNames.joined(separator: ", "))). " +
            "Re-introducing one suggests the trait-gated split has regressed. \(violations.joined(separator: "; "))"
        )
    }

    func test_familyTargetDirectories_exist() {
        let missing = Self.missingFamilyDirs(sourcesRoot: sourcesRoot)
        XCTAssertTrue(missing.isEmpty, "Expected family-target directory missing: \(missing)")
    }

    /// P7 retired the `ManifoldBackends` umbrella and the `ManifoldCloud` shim.
    /// Their source directories must be gone, and the relocated glue must live
    /// in the family targets:
    ///   - `FoundationBackends` → `Sources/ManifoldFoundation/`
    ///   - `DefaultWebSearchRuntime` → `Sources/ManifoldCloudCore/`
    /// `DefaultBackends` / `CloudBackends` were dropped entirely (replaced by an
    /// explicit registrar fold in `ManifoldKit.defaultBackendRegistrars`).
    func test_retiredShimDirectories_areGone() {
        let resurrected = Self.resurrectedShimDirs(sourcesRoot: sourcesRoot)
        XCTAssertTrue(resurrected.isEmpty, "Sources/ reappeared for retired shim(s) — the P7 shim retirement regressed: \(resurrected)")
    }

    func test_relocatedGlue_livesInFamilyTargets() {
        let fm = FileManager.default

        let foundationRegistrar = sourcesRoot
            .appendingPathComponent("ManifoldFoundation")
            .appendingPathComponent("FoundationBackends.swift")
        XCTAssertTrue(
            fm.fileExists(atPath: foundationRegistrar.path),
            "FoundationBackends.swift must live in Sources/ManifoldFoundation/ after the P7 relocation"
        )

        let webSearch = sourcesRoot
            .appendingPathComponent("ManifoldCloudCore")
            .appendingPathComponent("DefaultWebSearchRuntime.swift")
        XCTAssertTrue(
            fm.fileExists(atPath: webSearch.path),
            "DefaultWebSearchRuntime.swift must live in Sources/ManifoldCloudCore/ after the P7 relocation"
        )

        // The dropped umbrella registrars must not reappear anywhere.
        let violations = Self.droppedRegistrarViolations(sourcesRoot: sourcesRoot)
        XCTAssertTrue(
            violations.isEmpty,
            "Dropped registrar(s) reappeared — DefaultBackends/CloudBackends were dropped in P7 in favour of an explicit registrar fold. \(violations.joined(separator: "; "))"
        )
    }

    // MARK: - Sabotage (exercises the same detection functions the audit runs)

    func test_sabotage_detectsTopologyViolations() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("package-topology-sabotage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fm = FileManager.default

        // (a) A resurrected stub file.
        let ollamaDir = tmp.appendingPathComponent("ManifoldOllama", isDirectory: true)
        try fm.createDirectory(at: ollamaDir, withIntermediateDirectories: true)
        try "// stub".write(to: ollamaDir.appendingPathComponent("ClaudeBackendStub.swift"), atomically: true, encoding: .utf8)
        XCTAssertFalse(Self.stubViolations(sourcesRoot: tmp).isEmpty, "The planted stub file must be flagged")

        // (b) A resurrected umbrella shim directory.
        let umbrellaDir = tmp.appendingPathComponent("ManifoldBackendsUmbrella", isDirectory: true)
        try fm.createDirectory(at: umbrellaDir, withIntermediateDirectories: true)
        XCTAssertFalse(Self.resurrectedShimDirs(sourcesRoot: tmp).isEmpty, "The planted umbrella directory must be flagged")

        // (c) A resurrected dropped registrar.
        let cloudSaaSDir = tmp.appendingPathComponent("ManifoldCloudSaaS", isDirectory: true)
        try fm.createDirectory(at: cloudSaaSDir, withIntermediateDirectories: true)
        try "// registrar".write(to: cloudSaaSDir.appendingPathComponent("DefaultBackends.swift"), atomically: true, encoding: .utf8)
        XCTAssertFalse(Self.droppedRegistrarViolations(sourcesRoot: tmp).isEmpty, "The planted registrar file must be flagged")

        // (d) With all four family dirs present, nothing is reported missing.
        let cleanRoot = tmp.appendingPathComponent("clean", isDirectory: true)
        for target in Self.expectedFamilyTargetNames {
            try fm.createDirectory(at: cleanRoot.appendingPathComponent(target), withIntermediateDirectories: true)
        }
        XCTAssertTrue(Self.missingFamilyDirs(sourcesRoot: cleanRoot).isEmpty, "All four family dirs present must report no missing dirs")

        // With one absent, it must be named.
        let incompleteRoot = tmp.appendingPathComponent("incomplete", isDirectory: true)
        for target in Self.expectedFamilyTargetNames.dropLast() {
            try fm.createDirectory(at: incompleteRoot.appendingPathComponent(target), withIntermediateDirectories: true)
        }
        let missing = Self.missingFamilyDirs(sourcesRoot: incompleteRoot)
        XCTAssertEqual(missing, [Self.expectedFamilyTargetNames.last!], "The absent family dir must be named")
    }

    // MARK: - Detection

    static func stubViolations(sourcesRoot: URL) -> [String] {
        let fm = FileManager.default
        let stubNames = [
            "ClaudeBackendStub.swift",
            "OpenAIBackendStub.swift",
            "OllamaBackendStub.swift",
        ]
        var violations: [String] = []
        for stub in stubNames {
            let candidates = recursiveFind(named: stub, under: sourcesRoot, fileManager: fm)
            if !candidates.isEmpty {
                violations.append("\(stub) found at \(candidates.map(\.path))")
            }
        }
        return violations
    }

    static func missingFamilyDirs(sourcesRoot: URL) -> [String] {
        let fm = FileManager.default
        var missing: [String] = []
        for target in expectedFamilyTargetNames {
            let dir = sourcesRoot.appendingPathComponent(target)
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: dir.path, isDirectory: &isDir)
            if !(exists && isDir.boolValue) {
                missing.append(target)
            }
        }
        return missing
    }

    static func resurrectedShimDirs(sourcesRoot: URL) -> [String] {
        let fm = FileManager.default
        var resurrected: [String] = []
        for retired in ["ManifoldBackendsUmbrella", "ManifoldCloud"] {
            let dir = sourcesRoot.appendingPathComponent(retired)
            if fm.fileExists(atPath: dir.path) {
                resurrected.append(retired)
            }
        }
        return resurrected
    }

    static func droppedRegistrarViolations(sourcesRoot: URL) -> [String] {
        let fm = FileManager.default
        var violations: [String] = []
        for dropped in ["DefaultBackends.swift", "CloudBackends.swift"] {
            let hits = recursiveFind(named: dropped, under: sourcesRoot, fileManager: fm)
            if !hits.isEmpty {
                violations.append("\(dropped) found at \(hits.map(\.path))")
            }
        }
        return violations
    }

    // MARK: - Helpers

    private static let expectedFamilyTargetNames: [String] = [
        "ManifoldCloudCore",
        // ManifoldMLX / ManifoldLlama left for the companion packages
        // (v0.48, PR C2, #1749).
        "ManifoldFoundation",
        "ManifoldOllama",
        "ManifoldCloudSaaS",
    ]

    private static func recursiveFind(named filename: String, under root: URL, fileManager fm: FileManager) -> [URL] {
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var hits: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == filename {
            hits.append(url)
        }
        return hits
    }
}
