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

    func test_umbrellaTargetHostsRegistrarsNotBackends() {
        let fm = FileManager.default
        let umbrella = sourcesRoot.appendingPathComponent("ManifoldBackendsUmbrella")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: umbrella.path, isDirectory: &isDir), isDir.boolValue else {
            XCTFail("Sources/ManifoldBackendsUmbrella/ missing — the umbrella shim was deleted or renamed")
            return
        }

        // Files that MUST live in the umbrella (cross-family glue).
        for name in [
            "Exports.swift",
            "DefaultBackends.swift",
            // MLXBackends.swift / LlamaBackends.swift moved to the
            // manifold-mlx / manifold-llama companion packages (v0.48, PR C2).
            "FoundationBackends.swift",
            "CloudBackends.swift",
        ] {
            let path = umbrella.appendingPathComponent(name)
            XCTAssertTrue(
                fm.fileExists(atPath: path.path),
                "Sources/ManifoldBackendsUmbrella/\(name) missing — umbrella glue regressed"
            )
        }

        // Files that MUST NOT live in the umbrella (they belong in family
        // targets — or, for MLX/Llama since PR C2, in the companion packages).
        for forbidden in [
            "MLXBackend.swift",
            "LlamaBackend.swift",
            "MLXBackends.swift",
            "LlamaBackends.swift",
            "FoundationBackend.swift",
            "ClaudeBackend.swift",
            "OpenAIBackend.swift",
            "OllamaBackend.swift",
            "SSECloudBackend.swift",
            "PinnedSessionDelegate.swift",
        ] {
            let path = umbrella.appendingPathComponent(forbidden)
            XCTAssertFalse(
                fm.fileExists(atPath: path.path),
                "Sources/ManifoldBackendsUmbrella/\(forbidden) reappeared — file should live in its family target, not the umbrella"
            )
        }
    }

    // MARK: - Helpers

    private let expectedFamilyTargetNames: [String] = [
        "ManifoldCloudCore",
        // ManifoldMLX / ManifoldLlama left for the companion packages
        // (v0.48, PR C2, #1749).
        "ManifoldFoundation",
        "ManifoldCloud",
        "ManifoldBackendsUmbrella",
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
