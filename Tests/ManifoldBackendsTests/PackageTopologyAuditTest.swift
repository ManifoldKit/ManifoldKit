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
        let fm = FileManager.default
        let stubNames = [
            "ClaudeBackendStub.swift",
            "OpenAIBackendStub.swift",
            "OllamaBackendStub.swift",
        ]

        for stub in stubNames {
            let candidates = recursiveFind(named: stub, under: sourcesRoot, fileManager: fm)
            XCTAssertTrue(
                candidates.isEmpty,
                "Stub file \(stub) was deleted in initiative I7 (split into \(expectedFamilyTargetNames.joined(separator: ", "))). " +
                "Re-introducing it suggests the trait-gated split has regressed. Found at: \(candidates.map(\.path))"
            )
        }
    }

    func test_familyTargetDirectories_exist() {
        let fm = FileManager.default
        for target in expectedFamilyTargetNames {
            let dir = sourcesRoot.appendingPathComponent(target)
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: dir.path, isDirectory: &isDir)
            XCTAssertTrue(exists && isDir.boolValue, "Expected family-target directory missing: Sources/\(target)/")
        }
    }

    /// P7 retired the `ManifoldBackends` umbrella and the `ManifoldCloud` shim.
    /// Their source directories must be gone, and the relocated glue must live
    /// in the family targets:
    ///   - `FoundationBackends` → `Sources/ManifoldFoundation/`
    ///   - `DefaultWebSearchRuntime` → `Sources/ManifoldCloudCore/`
    /// `DefaultBackends` / `CloudBackends` were dropped entirely (replaced by an
    /// explicit registrar fold in `ManifoldKit.defaultBackendRegistrars`).
    func test_retiredShimDirectories_areGone() {
        let fm = FileManager.default
        for retired in ["ManifoldBackendsUmbrella", "ManifoldCloud"] {
            let dir = sourcesRoot.appendingPathComponent(retired)
            XCTAssertFalse(
                fm.fileExists(atPath: dir.path),
                "Sources/\(retired)/ reappeared — the P7 shim retirement regressed"
            )
        }
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
        for dropped in ["DefaultBackends.swift", "CloudBackends.swift"] {
            let hits = recursiveFind(named: dropped, under: sourcesRoot, fileManager: fm)
            XCTAssertTrue(
                hits.isEmpty,
                "\(dropped) reappeared — DefaultBackends/CloudBackends were dropped in P7 in favour of an explicit registrar fold. Found at: \(hits.map(\.path))"
            )
        }
    }

    // MARK: - Helpers

    private let expectedFamilyTargetNames: [String] = [
        "ManifoldCloudCore",
        // ManifoldMLX / ManifoldLlama left for the companion packages
        // (v0.48, PR C2, #1749).
        "ManifoldFoundation",
        "ManifoldOllama",
        "ManifoldCloudSaaS",
    ]

    private func recursiveFind(named filename: String, under root: URL, fileManager fm: FileManager) -> [URL] {
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var hits: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == filename {
            hits.append(url)
        }
        return hits
    }
}
