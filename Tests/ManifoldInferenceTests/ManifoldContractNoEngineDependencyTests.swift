import XCTest

/// Tripwire for the P2a downward extraction (#1719): the `ManifoldContract`
/// leaf target must never depend on `ManifoldInference` (the engine) or any
/// module that sits at or above the engine in the dependency DAG.
///
/// ## Why this matters
///
/// `ManifoldContract` exists so the family backends compile against a thin
/// surface (`InferenceBackend`, `GenerationConfig`, `GenerationEvent`,
/// `Message`, the streaming transforms, …) that carries *no engine state* —
/// `InferenceService`, `GenerationQueue`, `ToolRegistry`, and `BackendRegistrar`
/// stay in `ManifoldInference`. The downward direction (Contract below the
/// engine) is what keeps the move at ~30 files with zero consumer import edits
/// instead of relocating 246 lockstep files. If a future Package.swift edit
/// reintroduces a `ManifoldInference` (or higher) dependency on
/// `ManifoldContract`, the layering inverts: Contract would transitively pull
/// the engine back in and the thin-kernel property is lost.
///
/// `ManifoldContract` legitimately depends on the P1 leaf modules
/// (`ManifoldHardware`, `ManifoldModelCatalog`) — its surface is expressed in
/// terms of their value types (tool/JSON-schema types, `BackendCapabilities`,
/// `ModelManifest`, `CloudBackendError`, …). Those are *below* Contract, so they
/// are explicitly allowed. The forbidden set is the engine and everything above
/// it.
///
/// ## What this enforces
///
/// Reads `Package.swift` text at runtime, isolates the `ManifoldContract`
/// `.target(...)` block, and asserts its `dependencies:` list names none of the
/// forbidden modules. Substring-based, like `PackageTraitGateAuditTest`, to
/// avoid pulling SwiftSyntax into the default-trait test build.
///
/// ## Fixing a violation
///
/// If `ManifoldContract` started needing an engine type, the type is in the
/// wrong layer — move the type *down* into Contract (or a leaf), do not point
/// Contract *up* at the engine. Adding `ManifoldInference` to Contract's deps to
/// silence this test reintroduces exactly the cycle the extraction removed.
final class ManifoldContractNoEngineDependencyTests: XCTestCase {

    /// Modules at or above the engine layer. `ManifoldContract` must depend on
    /// none of them. (The P1 leaf modules it *is* allowed to use —
    /// ManifoldHardware, ManifoldModelCatalog, ManifoldNetworking,
    /// ManifoldSecrets — are deliberately absent.)
    private static let forbiddenModules = [
        "ManifoldInference",
        "ManifoldRuntime",
        "ManifoldPersistenceSwiftData",
        "ManifoldCloudCore",
        "ManifoldCloud",
        "ManifoldMLX",
        "ManifoldLlama",
        "ManifoldFoundation",
        "ManifoldBackends",
        "ManifoldMCP",
        "ManifoldMCPHost",
        "ManifoldUI",
        "ManifoldUIModelManagement",
        "ManifoldKit",
        "ManifoldSkills",
    ]

    func testManifoldContractTargetDependsOnNoEngineModule() throws {
        let manifestURL = try Self.locatePackageManifest()
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)

        let block = try Self.contractTargetBlock(in: manifest)

        let offenders = Self.forbiddenModules.filter { block.contains("\"\($0)\"") }

        XCTAssertTrue(
            offenders.isEmpty,
            """
            ManifoldContract's dependency list names engine-or-above modules: \
            \(offenders.joined(separator: ", ")). ManifoldContract is the thin \
            Contract leaf — it must depend only on the P1 leaf modules \
            (ManifoldHardware, ManifoldModelCatalog). A type that forces an \
            upward edge belongs in a lower layer; move it down rather than \
            pointing Contract at the engine. See #1719.
            """
        )
    }

    /// Confirms the target actually exists — guards against a rename silently
    /// neutering the tripwire (an empty block would pass the offender check).
    func testManifoldContractTargetExists() throws {
        let manifestURL = try Self.locatePackageManifest()
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        XCTAssertTrue(
            manifest.contains("name: \"ManifoldContract\""),
            "Package.swift no longer declares a ManifoldContract target — the #1719 tripwire is moot."
        )
    }

    // MARK: - Helpers

    /// Extracts the `.target(...)` block whose `name:` is `"ManifoldContract"`.
    ///
    /// `name: "ManifoldContract"` appears more than once in the manifest — once
    /// in the `.library(name: "ManifoldContract", …)` product (inline) and once
    /// opening the `.target(` declaration. We want the latter, so we anchor on
    /// the `.target(` opener that is immediately (whitespace-only) followed by
    /// the target's `name:` line, then forward-scan to its matching paren.
    private static func contractTargetBlock(in manifest: String) throws -> String {
        // The `.target(` that opens the ManifoldContract target. Iterate every
        // `.target(` and pick the one whose body's first `name:` is ours — this
        // skips the `.library(` product (different opener) and any earlier
        // `.target` blocks (their first `name:` is a different module).
        var searchStart = manifest.startIndex
        var targetStart: Range<String.Index>?
        while let opener = manifest.range(
            of: ".target(",
            range: searchStart..<manifest.endIndex
        ) {
            // The first `name: "..."` after this opener identifies the target.
            if let firstName = manifest.range(
                of: "name: \"",
                range: opener.upperBound..<manifest.endIndex
            ) {
                let after = firstName.upperBound
                if manifest[after...].hasPrefix("ManifoldContract\"") {
                    targetStart = opener
                    break
                }
            }
            searchStart = opener.upperBound
        }

        guard let targetStart else {
            throw NSError(domain: "ManifoldContractNoEngineDependencyTests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not find the .target( opening for ManifoldContract.",
            ])
        }

        // Forward brace-balanced scan from the opening paren to its match.
        var idx = targetStart.upperBound  // just after ".target("
        var depth = 1
        while idx < manifest.endIndex {
            let ch = manifest[idx]
            if ch == "(" { depth += 1 }
            else if ch == ")" {
                depth -= 1
                if depth == 0 {
                    return String(manifest[targetStart.lowerBound...idx])
                }
            }
            idx = manifest.index(after: idx)
        }
        throw NSError(domain: "ManifoldContractNoEngineDependencyTests", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Unbalanced parens scanning the ManifoldContract target block.",
        ])
    }

    /// Walks up from this test file's `#filePath` to the package root holding
    /// `Package.swift`. Mirrors `PackageTraitGateAuditTest.locatePackageManifest`.
    private static func locatePackageManifest(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "ManifoldContractNoEngineDependencyTests", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Package.swift from #filePath",
        ])
    }
}
