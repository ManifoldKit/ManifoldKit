import XCTest
import Foundation

/// Audit: the set of `@_exported import` modules on the `ManifoldKit`
/// umbrella must not change without a reviewer deliberately updating this
/// file's baseline.
///
/// ## Why
///
/// `swift-api-digester` (the machinery behind `Tests/APIFreezeTests`) dumps
/// only symbols *declared* in a module. Almost everything `import ManifoldKit`
/// exposes is not declared there — it is re-exported via `@_exported import`
/// from `ManifoldInference`, `ManifoldRuntime`, `ManifoldPersistenceSwiftData`,
/// the backend families, and `ManifoldUI` (see `Sources/ManifoldKit/Exports.swift`).
/// Re-exported symbols never land in `api-surface-baseline/ManifoldKit.txt` —
/// `grep -ic skill Tests/APIFreezeTests/api-surface-baseline/ManifoldKit.txt`
/// returns 0 even though `ManifoldSkills` was re-exported for months (retired
/// in ebcafdbe). So deleting an `@_exported import` line — an instant source
/// break for every consumer doing `import ManifoldKit` plus a symbol from
/// that module — sails past api-digester untouched. Found reviewing PR
/// #2419, which deletes `Sources/ManifoldKit/Exports+Skills.swift`.
///
/// ## What it checks
///
/// This audit scans every `.swift` file directly under `Sources/ManifoldKit/`
/// (a re-export could live in any file there, not just `Exports.swift` — see
/// the retired `Exports+Skills.swift` precedent) for `@_exported import <Module>`
/// lines and compares the resulting module set against ``expectedReexports``,
/// a baseline pinned in this file. Removing a module — or adding one without
/// updating the baseline — fails with a diff. The baseline is a plain Swift
/// array literal, matching `PackageTopologyAuditTest.expectedFamilyTargetNames`:
/// a change to the umbrella's re-export surface is meant to be a reviewable
/// one-line diff here, not a silent drift.
///
/// The detection logic lives in ``reexportedModules(sourcesRoot:)`` and
/// ``diff(found:expected:)`` so the in-file sabotage test exercises the exact
/// functions the audit runs.
///
/// ## Scope notes
///
/// * Only the umbrella target (`Sources/ManifoldKit/`) is scanned — this
///   audit is specifically about the umbrella's re-export contract, not
///   every `@_exported import` in the repo.
/// * The `#if BUILDING_DOCC` branch of `Exports.swift` re-exports the same
///   modules with `@_documentation(visibility: internal)` prefixed — the
///   parser strips that prefix, so both branches fold into the same set and
///   must always agree (a divergence there would itself be a bug worth
///   catching, though this audit doesn't separately assert branch parity).
/// * Commented-out `@_exported import` lines (`// @_exported import Foo`) are
///   not counted — the scan skips lines whose trimmed text starts with `//`.
final class UmbrellaReexportAuditTest: XCTestCase {

    /// Pinned baseline of modules `ManifoldKit` re-exports today. Update this
    /// array — with a `feat`/`fix`/migration-note explaining why — whenever a
    /// re-export is deliberately added or removed.
    static let expectedReexports: Set<String> = [
        "ManifoldInference",
        "ManifoldRuntime",
        "ManifoldPersistenceSwiftData",
        "ManifoldFoundation",
        "ManifoldOllama",
        "ManifoldCloudSaaS",
        "ManifoldCloudCore",
        "ManifoldUI",
        "ManifoldSkills",
    ]

    private var sourcesRoot: URL {
        // Tests/ManifoldCoreTests/<this>.swift -> repo root -> Sources/ManifoldKit
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .appendingPathComponent("ManifoldKit")
    }

    func test_umbrellaReexports_matchBaseline() throws {
        let found = try Self.reexportedModules(sourcesRoot: sourcesRoot)
        let (missing, added) = Self.diff(found: found, expected: Self.expectedReexports)

        XCTAssertTrue(missing.isEmpty && added.isEmpty, """
            ManifoldKit's `@_exported import` surface changed without a baseline update.

            Missing (re-export removed — a source break for every consumer doing \
            `import ManifoldKit` plus a symbol from that module): \(missing.sorted())
            Added (new re-export, not yet in the baseline): \(added.sorted())

            If this is deliberate, update `UmbrellaReexportAuditTest.expectedReexports` \
            in the same PR and say why in the PR body — a removal needs a migration note \
            (AGENTS.md § "Removing a public API means updating every doc that names it").
            """)
    }

    func test_atLeastOneReexportFound() throws {
        // Guards against the scan silently finding nothing (wrong path, a
        // regex that stopped matching) and reporting a vacuous "0 missing,
        // 0 added" pass.
        let found = try Self.reexportedModules(sourcesRoot: sourcesRoot)
        XCTAssertFalse(found.isEmpty, "Expected to find @_exported import lines under Sources/ManifoldKit/ — scan path or regex is probably broken")
    }

    // MARK: - Sabotage (exercises the same detection functions the audit runs)

    func test_sabotage_detectsRemovedReexport() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbrella-reexport-sabotage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fm = FileManager.default
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // Plant a stand-in Exports.swift missing one module (mirrors PR
        // #2419 deleting Exports+Skills.swift's `@_exported import
        // ManifoldSkills` line) and carrying the doc-build annotated branch,
        // a commented-out line, and blank lines — the real file's shape.
        let sabotaged = """
            // some doc comment
            #if BUILDING_DOCC
            @_documentation(visibility: internal) @_exported import ManifoldInference
            @_documentation(visibility: internal) @_exported import ManifoldRuntime
            #else
            @_exported import ManifoldInference
            @_exported import ManifoldRuntime
            // @_exported import ManifoldPersistenceSwiftData
            #endif
            """
        try sabotaged.write(
            to: tmp.appendingPathComponent("Exports.swift"),
            atomically: true,
            encoding: .utf8
        )

        let found = try Self.reexportedModules(sourcesRoot: tmp)
        XCTAssertEqual(found, ["ManifoldInference", "ManifoldRuntime"], "The commented-out line must not count, and only the two real imports should be found")

        let (missing, added) = Self.diff(found: found, expected: Self.expectedReexports)
        XCTAssertFalse(missing.isEmpty, "Removing ManifoldPersistenceSwiftData (and every other baseline module) must be reported as missing")
        XCTAssertTrue(missing.contains("ManifoldPersistenceSwiftData"), "The specific removed module must be named")
        XCTAssertTrue(missing.contains("ManifoldFoundation"), "Every baseline module absent from the sabotaged file must be named")
        XCTAssertTrue(added.isEmpty, "No unexpected module was added in this sabotage scenario")

        // A clean scan (found == expected) must report no diff at all.
        let (cleanMissing, cleanAdded) = Self.diff(found: Self.expectedReexports, expected: Self.expectedReexports)
        XCTAssertTrue(cleanMissing.isEmpty && cleanAdded.isEmpty, "An unchanged re-export set must report zero diff")

        // An added, unbaselined module must be reported too.
        let (_, addedOnly) = Self.diff(found: Self.expectedReexports.union(["ManifoldMCP"]), expected: Self.expectedReexports)
        XCTAssertEqual(addedOnly, ["ManifoldMCP"], "A new re-export not yet in the baseline must be flagged as added")
    }

    // MARK: - Detection

    /// Scans every `.swift` file directly under `sourcesRoot` for
    /// `@_exported import <Module>` lines (optionally prefixed with
    /// `@_documentation(visibility: internal)`) and returns the set of
    /// re-exported module names. Commented-out lines are ignored.
    static func reexportedModules(sourcesRoot: URL) throws -> Set<String> {
        let fm = FileManager.default
        var modules: Set<String> = []

        guard let entries = try? fm.contentsOfDirectory(
            at: sourcesRoot,
            includingPropertiesForKeys: nil
        ) else {
            return modules
        }

        for entry in entries where entry.pathExtension == "swift" {
            guard let content = try? String(contentsOf: entry, encoding: .utf8) else { continue }
            for rawLine in content.components(separatedBy: "\n") {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                guard let range = trimmed.range(of: "@_exported import ") else { continue }
                let rest = trimmed[range.upperBound...]
                // Take the first whitespace-delimited token after "import ",
                // then strip a trailing line comment if present.
                let moduleToken = rest
                    .split(separator: " ", maxSplits: 1)[0]
                let moduleName = moduleToken.split(separator: "/")[0]
                    .trimmingCharacters(in: .whitespaces)
                if !moduleName.isEmpty {
                    modules.insert(moduleName)
                }
            }
        }
        return modules
    }

    /// Compares a scanned module set against the pinned baseline. Returns
    /// modules present in `expected` but absent from `found` (a removal) and
    /// modules present in `found` but absent from `expected` (an addition).
    static func diff(found: Set<String>, expected: Set<String>) -> (missing: [String], added: [String]) {
        let missing = expected.subtracting(found).sorted()
        let added = found.subtracting(expected).sorted()
        return (missing, added)
    }
}
