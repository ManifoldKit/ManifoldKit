import XCTest
import Foundation

/// Audit: `@_exported import` re-exports anywhere in `Sources/` must not
/// change without a reviewer deliberately updating this file's baseline.
///
/// ## Why
///
/// `swift-api-digester` (the machinery behind `Tests/APIFreezeTests`) dumps
/// only symbols *declared* in a module. A module that re-exports another via
/// `@_exported import` exposes the re-exported module's public surface too,
/// but none of it is *declared* there, so none of it lands in that module's
/// `api-surface-baseline/*.txt`. The motivating case: `ManifoldSkills` was
/// re-exported via `ManifoldKit` for months, yet `grep -ic skill
/// Tests/APIFreezeTests/api-surface-baseline/ManifoldKit.txt` returned 0 the
/// whole time. So deleting an `@_exported import` line — an instant source
/// break for every consumer that reaches the re-exported module's symbols
/// through the re-exporting one — sails past api-digester untouched. Found
/// reviewing PR #2419, which deleted
/// `Sources/ManifoldKit/Exports+Skills.swift` with no gate objecting; the
/// module itself was then retired in #2434.
///
/// This is not only a `ManifoldKit`-umbrella problem. `ManifoldContract`
/// re-exports the tool-calling value types from `ManifoldHardware` (and
/// `ManifoldModelCatalog`) specifically *because* moving them into Contract
/// directly would create a dependency cycle (AGENTS.md § Targets,
/// `ManifoldContractLeafExports.swift`) — that re-export is structurally
/// load-bearing, not incidental, and losing it is exactly as invisible to
/// api-digester as the umbrella case. Same for `ManifoldInference`'s five
/// leaf re-exports and `ManifoldCloudCore`'s re-export of `ManifoldInference`
/// (needed for `DefaultWebSearchRuntime`'s port conformance).
///
/// ## What it checks
///
/// Scans every `.swift` file under `Sources/` (recursively) for
/// `@_exported import <Module>` statements, grouping findings by the
/// re-exporting module (the first path component under `Sources/`) rather
/// than by file — the same module's re-export set can be spread across
/// multiple files (e.g. `ManifoldKit/Exports.swift`'s `#if BUILDING_DOCC`
/// and `#else` branches).
/// The resulting `[reexportingModule: Set<reexportedModule>]` map is
/// compared against ``expectedReexports``, the pinned baseline. A module
/// that stops re-exporting something in the baseline, or starts re-exporting
/// something not yet baselined, fails — naming both the module and target,
/// plus the file for an *added* re-export (a *missing* one has no file to
/// name by definition — the file that carried it is what changed).
///
/// The detection logic lives in ``scanReexports(sourcesRoot:)`` and
/// ``diff(found:expected:)`` so the in-file sabotage tests exercise the
/// exact functions the audit runs.
///
/// ## Detection details
///
/// * **Matching is not anchored at line start.** The scan does
///   `trimmed.range(of: "@_exported import ")`, a substring search, not a
///   `hasPrefix` check — so both `@_exported import Foo` and the doc-build
///   annotated form `@_documentation(visibility: internal) @_exported
///   import Foo` (`Sources/ManifoldKit/Exports.swift`'s `#if BUILDING_DOCC`
///   branch) are matched by the same code path — confirmed directly:
///   `test_reexports_matchBaseline` passes against the real tree today,
///   where `Exports.swift` carries both forms for the same eight modules
///   (the `#if BUILDING_DOCC` / `#else` branches re-export an identical
///   list), and `test_sabotage_detectsRemovedAndAddedReexport` asserts the
///   `@_documentation`-prefixed form is matched in isolation. This audit
///   can't and doesn't distinguish which branch a given import came from —
///   it only asserts the union each module contributes is right.
/// * **Comment lines cannot poison the set.** A line is skipped whenever its
///   *trimmed* text starts with `//` — which covers every real instance in
///   this repo of `@_exported import` appearing only in prose:
///   `Sources/ManifoldKit/Exports.swift:27` (`// Doc-build gate...`),
///   `Sources/ManifoldContract/BackendError.swift`,
///   `Sources/ManifoldInference/Services/InferenceService+StructuredOutput.swift`,
///   `Sources/ManifoldRuntime/Services/ConversationRuntimeTypes.swift`, and
///   `Sources/ManifoldUI/ViewModels/ChatViewModel+Messages.swift` — all `///`
///   or `//` doc/prose comments, all excluded because the trimmed line
///   starts with `//`. Verified by running `grep -n "@_exported import"
///   Sources/**/*.swift` against every hit and confirming each non-statement
///   hit starts with `//` after trimming; `test_sabotage_commentLineDoesNotPoisonSet`
///   plants two of these exact comment strings alongside a real statement
///   and asserts only the real one counts.
/// * Only `.swift` files are scanned (DocC `.md`/`.tutorial` prose that
///   mentions `@_exported import`, e.g. `ManifoldContract.docc`, is never
///   read).
final class UmbrellaReexportAuditTest: XCTestCase {

    /// Pinned baseline: reexporting module -> set of modules it re-exports.
    /// Update this map — with a `feat`/`fix`/migration-note explaining why —
    /// whenever a re-export is deliberately added or removed anywhere in
    /// `Sources/`.
    static let expectedReexports: [String: Set<String>] = [
        "ManifoldKit": [
            "ManifoldInference",
            "ManifoldRuntime",
            "ManifoldPersistenceSwiftData",
            "ManifoldFoundation",
            "ManifoldOllama",
            "ManifoldCloudSaaS",
            "ManifoldCloudCore",
            "ManifoldUI",
            // `ManifoldSkills` was re-exported here until #2434 retired the
            // module outright; its surviving AGENTS.md loader ships as
            // `ManifoldAgentInstructions`, which is deliberately *linked*
            // rather than re-exported (see Sources/ManifoldKit/Exports.swift).
        ],
        // Re-exports ManifoldInference so DefaultWebSearchRuntime's port
        // conformance (an un-gated library->library edge, see Package.swift)
        // compiles without every ManifoldCloudCore file importing it.
        "ManifoldCloudCore": [
            "ManifoldInference",
        ],
        // Load-bearing, not incidental: the tool-calling value types live
        // physically in ManifoldHardware (moving them into Contract would
        // cycle) and are re-exported here so Contract consumers see them as
        // part of the kernel's surface. See ManifoldContractLeafExports.swift.
        "ManifoldContract": [
            "ManifoldHardware",
            "ManifoldModelCatalog",
        ],
        "ManifoldInference": [
            "ManifoldContract",
            "ManifoldHardware",
            "ManifoldModelCatalog",
            "ManifoldNetworking",
            "ManifoldSecrets",
        ],
        // #2476 moves the endpointStore environment key to ManifoldUI, which
        // owns the presentation boundary that forwards it. Re-export UI here
        // so apps that historically imported only ModelManagement continue to
        // resolve `EnvironmentValues.endpointStore` without a source break.
        "ManifoldUIModelManagement": [
            "ManifoldUI",
        ],
    ]

    private var sourcesRoot: URL {
        // Tests/ManifoldCoreTests/<this>.swift -> repo root -> Sources
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    func test_reexports_matchBaseline() throws {
        let found = try Self.scanReexports(sourcesRoot: sourcesRoot)
        let (missing, added) = Self.diff(found: found, expected: Self.expectedReexports)

        XCTAssertTrue(missing.isEmpty && added.isEmpty, """
            An `@_exported import` re-export changed somewhere under Sources/ without a baseline update.

            Missing (re-export removed — a source break for every consumer that reached \
            the target module's symbols through the re-exporting one):
            \(missing.map { "  - \($0.module) no longer re-exports \($0.target) (expected under Sources/\($0.module)/)" }.joined(separator: "\n"))

            Added (new re-export, not yet in the baseline):
            \(added.map { "  - \($0.module) now re-exports \($0.target), found in \($0.file)" }.joined(separator: "\n"))

            If this is deliberate, update `UmbrellaReexportAuditTest.expectedReexports` in \
            the same PR and say why in the PR body — a removal needs a migration note \
            (AGENTS.md § "Removing a public API means updating every doc that names it").
            """)
    }

    func test_atLeastOneReexportFound() throws {
        // Guards against the scan silently finding nothing (wrong path, a
        // regex that stopped matching) and reporting a vacuous "0 missing,
        // 0 added" pass.
        let found = try Self.scanReexports(sourcesRoot: sourcesRoot)
        XCTAssertFalse(found.isEmpty, "Expected to find @_exported import lines under Sources/ — scan path or regex is probably broken")
        XCTAssertTrue(found.contains { $0.module == "ManifoldContract" }, "Expected to find ManifoldContract's leaf re-exports specifically — the non-umbrella coverage this audit exists for")
    }

    // MARK: - Sabotage (exercises the same detection functions the audit runs)

    func test_sabotage_detectsRemovedAndAddedReexport() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbrella-reexport-sabotage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fm = FileManager.default

        // Module A: mirrors ManifoldKit — two files contributing to the same
        // module's re-export set, the doc-build annotated form, and a
        // planted removal (ManifoldPersistenceSwiftData is missing).
        let moduleADir = tmp.appendingPathComponent("ModuleA", isDirectory: true)
        try fm.createDirectory(at: moduleADir, withIntermediateDirectories: true)
        try """
            // some doc comment
            #if BUILDING_DOCC
            @_documentation(visibility: internal) @_exported import ManifoldInference
            @_documentation(visibility: internal) @_exported import ManifoldRuntime
            #else
            @_exported import ManifoldInference
            @_exported import ManifoldRuntime
            // @_exported import ManifoldPersistenceSwiftData
            #endif
            """.write(to: moduleADir.appendingPathComponent("Exports.swift"), atomically: true, encoding: .utf8)
        try """
            @_exported import ManifoldSkills
            """.write(to: moduleADir.appendingPathComponent("Exports+Skills.swift"), atomically: true, encoding: .utf8)

        // Module B: mirrors ManifoldContract — a genuinely new, unbaselined
        // re-export planted to exercise the "added" branch.
        let moduleBDir = tmp.appendingPathComponent("ModuleB", isDirectory: true)
        try fm.createDirectory(at: moduleBDir, withIntermediateDirectories: true)
        try """
            @_exported import ManifoldSurprise
            """.write(to: moduleBDir.appendingPathComponent("LeafExports.swift"), atomically: true, encoding: .utf8)

        let found = try Self.scanReexports(sourcesRoot: tmp)
        let foundMap = Self.groupByModule(found)

        XCTAssertEqual(foundMap["ModuleA"], ["ManifoldInference", "ManifoldRuntime", "ManifoldSkills"], "Findings from two files in the same module must merge into one set, the commented-out line must not count, and the @_documentation-prefixed form must be matched")
        XCTAssertEqual(foundMap["ModuleB"], ["ManifoldSurprise"])

        let baseline: [String: Set<String>] = [
            "ModuleA": ["ManifoldInference", "ManifoldRuntime", "ManifoldPersistenceSwiftData", "ManifoldSkills"],
            "ModuleB": [],
        ]
        let (missing, added) = Self.diff(found: found, expected: baseline)

        XCTAssertEqual(missing.count, 1, "Exactly one baseline re-export (ManifoldPersistenceSwiftData) is absent")
        XCTAssertEqual(missing.first?.module, "ModuleA")
        XCTAssertEqual(missing.first?.target, "ManifoldPersistenceSwiftData")

        XCTAssertEqual(added.count, 1, "Exactly one unbaselined re-export (ManifoldSurprise) was planted")
        XCTAssertEqual(added.first?.module, "ModuleB")
        XCTAssertEqual(added.first?.target, "ManifoldSurprise")
        XCTAssertTrue(added.first?.file.hasSuffix("LeafExports.swift") ?? false, "The added-reexport finding must name the actual file it was found in, not a generic module-directory placeholder")

        // A module entirely absent from `found` (e.g. every file in it
        // deleted) must still be reported as missing for each baselined
        // target, not silently dropped because the key itself vanished.
        let (missingWhenModuleGone, _) = Self.diff(found: [], expected: baseline)
        XCTAssertEqual(Set(missingWhenModuleGone.map(\.target)), ["ManifoldInference", "ManifoldRuntime", "ManifoldPersistenceSwiftData", "ManifoldSkills"])
    }

    func test_sabotage_commentLineDoesNotPoisonSet() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbrella-reexport-comment-sabotage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fm = FileManager.default
        let moduleDir = tmp.appendingPathComponent("ManifoldContract", isDirectory: true)
        try fm.createDirectory(at: moduleDir, withIntermediateDirectories: true)

        // Mirrors the real prose comments found via
        // `grep -n "@_exported import" Sources/**/*.swift` that are NOT
        // themselves re-export statements.
        try """
            // `ManifoldContract` already `@_exported import`s (see
            /// `ManifoldInference`'s `@_exported import` of `ManifoldContract`) gives
            @_exported import ManifoldHardware
            """.write(to: moduleDir.appendingPathComponent("BackendError.swift"), atomically: true, encoding: .utf8)

        let found = try Self.scanReexports(sourcesRoot: tmp)
        XCTAssertEqual(found.count, 1, "Only the real @_exported import statement counts; the two prose comment lines that contain the literal phrase must not")
        XCTAssertEqual(found.first?.target, "ManifoldHardware")
    }

    // MARK: - Detection

    /// One finding: `module` re-exports `target`, found in `file`.
    struct ReexportFinding: Equatable {
        let module: String
        let target: String
        let file: String
    }

    /// Recursively scans every `.swift` file under `sourcesRoot` for
    /// `@_exported import <Module>` statements (optionally prefixed with
    /// `@_documentation(visibility: internal)`), attributing each finding to
    /// the module owning the file (its first path component under
    /// `sourcesRoot`). Commented-out lines (trimmed text starting with `//`)
    /// are ignored.
    static func scanReexports(sourcesRoot: URL) throws -> [ReexportFinding] {
        let fm = FileManager.default
        var findings: [ReexportFinding] = []

        guard let enumerator = fm.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return findings
        }

        let rootComponents = sourcesRoot.standardizedFileURL.pathComponents

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            let fileComponents = fileURL.standardizedFileURL.pathComponents
            guard fileComponents.count > rootComponents.count else { continue }
            let module = fileComponents[rootComponents.count]

            for rawLine in content.components(separatedBy: "\n") {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                guard let range = trimmed.range(of: "@_exported import ") else { continue }
                let rest = trimmed[range.upperBound...]
                let moduleToken = rest.split(separator: " ", maxSplits: 1)[0]
                let targetName = moduleToken.trimmingCharacters(in: .whitespaces)
                if !targetName.isEmpty {
                    findings.append(ReexportFinding(module: module, target: targetName, file: fileURL.path))
                }
            }
        }
        return findings
    }

    /// Folds per-file findings into one set of re-exported modules per
    /// reexporting module.
    static func groupByModule(_ findings: [ReexportFinding]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for finding in findings {
            result[finding.module, default: []].insert(finding.target)
        }
        return result
    }

    /// Compares scanned findings against the pinned baseline map. `missing`
    /// is every (module, target) pair present in `expected` but absent from
    /// `found` — a removal, with no file to name since the file that
    /// carried it is what changed. `added` is every (module, target) pair
    /// present in `found` but absent from `expected`, each annotated with
    /// the actual file it was found in (the first file encountered, if more
    /// than one file in the module carries the same statement).
    static func diff(
        found: [ReexportFinding],
        expected: [String: Set<String>]
    ) -> (missing: [(module: String, target: String)], added: [(module: String, target: String, file: String)]) {
        let foundMap = groupByModule(found)

        var missing: [(module: String, target: String)] = []
        for (module, targets) in expected {
            let foundTargets = foundMap[module] ?? []
            for target in targets.subtracting(foundTargets).sorted() {
                missing.append((module, target))
            }
        }

        var fileForPair: [String: String] = [:]
        for finding in found {
            let key = "\(finding.module)|\(finding.target)"
            if fileForPair[key] == nil {
                fileForPair[key] = finding.file
            }
        }

        var added: [(module: String, target: String, file: String)] = []
        for (module, targets) in foundMap {
            let expectedTargets = expected[module] ?? []
            for target in targets.subtracting(expectedTargets).sorted() {
                let file = fileForPair["\(module)|\(target)"] ?? "Sources/\(module)/"
                added.append((module, target, file))
            }
        }

        missing.sort { $0.module == $1.module ? $0.target < $1.target : $0.module < $1.module }
        added.sort { $0.module == $1.module ? $0.target < $1.target : $0.module < $1.module }
        return (missing, added)
    }
}
