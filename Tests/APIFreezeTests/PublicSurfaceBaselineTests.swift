import XCTest

/// Structural tripwire for the member-aware public-surface baseline
/// (originated as the 0.2b prototype in `docs/plans/api-review-2026-07.md`;
/// made load-bearing and expanded to full module coverage by
/// `docs/plans/api-review-wave2-2026-07.md` item 0.A).
///
/// `scripts/api-surface-baseline.sh` generates the real, member-granular
/// diff (swift-api-digester's ABIRoot dump, normalized to one line per
/// public member) and is the actual tripwire — but running it needs a full
/// package build twice (a scratch git-treeish checkout plus the live tree;
/// measured multiple minutes cold, well under a minute warm — see the
/// script's own header for the full cost writeup). That's too heavy to run
/// on every `swift test` invocation as a unit test.
///
/// So this test validates the CHEAP, ALWAYS-TRUE invariants instead: the
/// checked-in baselines exist, are non-empty, and are well-formed (every
/// line matches `<Owner>[.<member>] <declKind>`, sorted, de-duplicated —
/// exactly what the normalizer promises to produce). That catches the
/// baseline files rotting (deleted, truncated, hand-edited into garbage)
/// without paying the full-build cost per test run.
///
/// The real check — regenerate + diff against a live digester dump — runs
/// nightly (`.github/workflows/nightly-slow-tests.yml`, the
/// `api-surface-baseline` job, `scripts/api-surface-baseline.sh --check`).
/// To run the real check by hand:
///
///     scripts/api-surface-baseline.sh --check
///
/// or opt this same test file into it locally via:
///
///     RUN_API_SURFACE_BASELINE_CHECK=1 swift test --filter PublicSurfaceBaselineTests
@MainActor
final class PublicSurfaceBaselineTests: XCTestCase {

    /// `.library(...)` products deliberately outside the baseline's scope,
    /// each with the reason it cannot simply be added.
    ///
    /// - `ManifoldServerKit`: a real public seam (`ServerBackendProvider`,
    ///   `ManifoldServer.serve(configuration:backendProvider:)`, #2242), but
    ///   `swift package diagnose-api-breaking-changes` builds the dumped target
    ///   in an internal scratch checkout and cannot resolve it — a confirmed
    ///   SwiftPM tool limitation, not a scoping choice. See #2245 item 4 and
    ///   the "Module scope" header in `scripts/api-surface-baseline.sh`.
    ///
    /// An entry here is a claim that the module CANNOT be covered. Removing a
    /// module from coverage for any other reason means deleting its
    /// `.library(...)` product, which the derivation below picks up on its own.
    private static let baselineScopeExclusions: Set<String> = ["ManifoldServerKit"]

    /// The module list `scripts/api-surface-baseline.sh` scopes to by default:
    /// every `.library(...)` product in Package.swift, minus
    /// ``baselineScopeExclusions``.
    ///
    /// **Derived from the manifest, not hand-maintained.** This used to be a
    /// literal array kept in sync by hand across three places (here, the
    /// script's `DEFAULT_MODULES`, and Package.swift's `products:`), with
    /// nothing checking them against each other. Adding a `.library(...)` and
    /// forgetting the other two silently left the new module unscoped: no
    /// baseline generated, no baseline checked, and a real public-surface
    /// removal in it shipping undetected. Deriving here removes one sync point
    /// outright; ``testScriptDefaultModulesMatchManifest()`` covers the other.
    private static func expectedModules() throws -> [String] {
        try libraryProductNames(inManifestAt: repoRoot().appendingPathComponent("Package.swift"))
            .filter { !baselineScopeExclusions.contains($0) }
            .sorted()
    }

    /// Extracts every `.library(name: "X"` product name from a Package.swift.
    ///
    /// Syntactic line-scan rather than an AST parse — the same approach
    /// `PackageTraitGateAuditTest` takes over this manifest, and for the same
    /// reason: the manifest is not importable from a test target, and its
    /// product declarations are uniform enough that a regex is honest here.
    ///
    /// `//` line comments are stripped first. This manifest's prose really does
    /// discuss products — there is a `.library()` mention inside a comment today
    /// — so without stripping, a future comment that happened to include
    /// `name: "Foo"` would invent a product and demand a baseline for it. That
    /// failure is loud rather than silent, but it is still a wrong answer from
    /// a gate whose whole purpose is not to give wrong answers.
    static func libraryProductNames(inManifestAt url: URL) throws -> Set<String> {
        let manifest = try String(contentsOf: url, encoding: .utf8)
        let code = manifest
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let commentStart = line.range(of: "//") else { return line }
                return line[line.startIndex..<commentStart.lowerBound]
            }
            .joined(separator: "\n")
        return Set(
            code
                .matches(of: try Regex(#"\.library\(\s*name:\s*"([A-Za-z0-9_]+)""#))
                .map { String($0[1].substring ?? "") }
                .filter { !$0.isEmpty }
        )
    }

    /// Extracts the space-separated `DEFAULT_MODULES="..."` assignment from
    /// `scripts/api-surface-baseline.sh`.
    static func scriptDefaultModules(atScriptPath url: URL) throws -> Set<String> {
        let script = try String(contentsOf: url, encoding: .utf8)
        guard let match = script.firstMatch(of: try Regex(#"(?m)^DEFAULT_MODULES="([^"]*)""#)),
              let value = match[1].substring
        else { return [] }
        return Set(value.split(separator: " ").map(String.init))
    }

    /// Every `declKind` the normalizer (`scripts/_lib/api-surface-extract.py`)
    /// is known to emit, observed across the current baselines. A new kind
    /// showing up would mean either a legitimate digester/Swift-version
    /// change (update this list) or the extractor emitting garbage.
    private static let knownKinds: Set<String> = [
        "Struct", "Class", "Enum", "Protocol",
        "Var", "Function", "Func", "Constructor", "TypeAlias",
        "EnumElement", "Subscript", "AssociatedType",
    ]

    private static func repoRoot() -> URL {
        // Tests/APIFreezeTests/PublicSurfaceBaselineTests.swift → repo root is 3 up.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/APIFreezeTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // <repo>
    }

    private static func baselineDir() -> URL {
        repoRoot().appendingPathComponent("Tests/APIFreezeTests/api-surface-baseline")
    }

    // MARK: - Presence

    func testGeneratorScriptExistsAndIsExecutable() throws {
        let scriptURL = Self.repoRoot().appendingPathComponent("scripts/api-surface-baseline.sh")
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            XCTFail("scripts/api-surface-baseline.sh is missing at \(scriptURL.path).")
            return
        }
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: scriptURL.path),
            "scripts/api-surface-baseline.sh exists but is not executable (chmod +x)."
        )
    }

    func testNormalizerExists() throws {
        let normalizerURL = Self.repoRoot().appendingPathComponent("scripts/_lib/api-surface-extract.py")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: normalizerURL.path),
            "scripts/_lib/api-surface-extract.py is missing — the baseline script depends on it."
        )
    }

    func testBaselineDirectoryExists() throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: Self.baselineDir().path, isDirectory: &isDirectory)
        XCTAssertTrue(exists && isDirectory.boolValue, "Tests/APIFreezeTests/api-surface-baseline/ is missing.")
    }

    // MARK: - Well-formedness

    /// Marker text for the two isolation/Sendable-signal line kinds added
    /// alongside the classic `<name> <declKind>` shape (see the "Isolation /
    /// Sendable signal" section of `api-surface-extract.py`'s module
    /// docstring). Neither ends in a `declKind` token, so they're validated
    /// separately below rather than against `knownKinds`.
    private static let conformancesMarker = " conformances: "
    private static let attrsMarker = " attrs: "

    /// A denylisted attribute (`api-surface-extract.py`'s `ATTR_DENYLIST`)
    /// should never survive into a checked-in `attrs:` line — if one does,
    /// either the filter regressed or the file was hand-edited.
    private static let attrDenylist: Set<String> = [
        "OriginallyDefinedIn", "TypeEraser", "EagerMove", "Frozen", "Preconcurrency",
    ]

    /// Validates a comma-joined value list (conformance or attribute names):
    /// non-empty, each entry a plausible bare identifier, sorted, and
    /// de-duplicated — exactly what the normalizer's `sorted(set(...))`
    /// promises to produce.
    private static func validateCommaList(_ value: Substring, moduleFile: String, lineIndex: Int, line: String) {
        let entries = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        XCTAssertFalse(entries.contains(""), "\(moduleFile) line \(lineIndex + 1) has an empty entry in its comma list: \(line)")
        var seen = Set<String>()
        var previousEntry: String?
        for entry in entries {
            XCTAssertFalse(
                seen.contains(entry),
                "\(moduleFile) line \(lineIndex + 1) has a duplicate entry `\(entry)`: \(line)"
            )
            seen.insert(entry)
            if let previousEntry {
                XCTAssertLessThanOrEqual(
                    previousEntry, entry,
                    "\(moduleFile) line \(lineIndex + 1) is not sorted within its comma list (`\(previousEntry)` should sort before `\(entry)`): \(line)"
                )
            }
            previousEntry = entry
        }
    }

    /// Modules whose entire pre-existing public surface was mechanically
    /// demoted `public` → `package` and which have shipped no other public
    /// declaration since. `ManifoldNetworking`'s only public surface was
    /// `NetworkActivityCenter` (+ `NetworkActivity`/`NetworkActivityKind`/
    /// `NetworkActivityToken`), demoted whole in the 2026-07-21
    /// inert-surface sweep (#2128; see
    /// `docs/MIGRATION-api-demotions-0.71.md`'s "2026-07-21 inert-surface
    /// sweep" section) — the target still exists and is still linked (its
    /// producer wiring, `NetworkActivityTrackingDelegate`, is real and
    /// package-internal), it simply has zero `public` declarations left. A
    /// future re-promotion (issue #1292) or a new public type added to this
    /// module removes it from this list; until then an empty baseline here
    /// is the correct, intentional state, not baseline rot.
    private static let expectedEmptyModules: Set<String> = ["ManifoldNetworking"]

    /// For each scoped module: the baseline file exists, is non-empty
    /// (unless listed in ``expectedEmptyModules``), every line matches
    /// `<name> <knownKind>` (or one of the two isolation/Sendable-signal
    /// shapes below), and the file is already sorted + de-duplicated (the
    /// normalizer's contract — a diff-stable baseline depends on this).
    // MARK: - Manifest ↔ script module-scope agreement

    /// The generator script's `DEFAULT_MODULES` must equal the set derived from
    /// Package.swift's `.library(...)` products, minus the documented
    /// ``baselineScopeExclusions``.
    ///
    /// This is the second of the two former hand-sync points (the first —
    /// `expectedModules` — is now derived outright). Nothing previously checked
    /// them against each other: the script's own header says "Keep
    /// DEFAULT_MODULES in sync with Package.swift's `products:` array (and with
    /// PublicSurfaceBaselineTests.swift's `expectedModules`)", which is a
    /// hand-maintained invariant with no tripwire. A product added to the
    /// manifest but not to the script is never dumped, never diffed, and its
    /// public surface can be removed without the gate noticing.
    func testScriptDefaultModulesMatchManifest() throws {
        let manifestModules = try Self.libraryProductNames(
            inManifestAt: Self.repoRoot().appendingPathComponent("Package.swift")
        ).subtracting(Self.baselineScopeExclusions)

        let scriptModules = try Self.scriptDefaultModules(
            atScriptPath: Self.repoRoot().appendingPathComponent("scripts/api-surface-baseline.sh")
        )

        XCTAssertFalse(
            scriptModules.isEmpty,
            "Parsed no DEFAULT_MODULES from scripts/api-surface-baseline.sh — the assignment moved or changed shape, so this check is inert."
        )

        let missingFromScript = manifestModules.subtracting(scriptModules)
        let extraInScript = scriptModules.subtracting(manifestModules)

        XCTAssertTrue(
            missingFromScript.isEmpty,
            """
            Package.swift declares .library product(s) that scripts/api-surface-baseline.sh does not scope, \
            so they get no API-surface baseline and no drift check:
              \(missingFromScript.sorted().joined(separator: "\n  "))
            Add them to DEFAULT_MODULES, or add them to baselineScopeExclusions with the reason they cannot be covered.
            """
        )
        XCTAssertTrue(
            extraInScript.isEmpty,
            """
            scripts/api-surface-baseline.sh scopes module(s) that are not .library products in Package.swift \
            (renamed or removed?):
              \(extraInScript.sorted().joined(separator: "\n  "))
            """
        )
    }

    /// Every exclusion must name a product that actually exists — otherwise a
    /// rename silently widens coverage back open while the entry looks
    /// deliberate.
    func testExclusionsReferenceRealProducts() throws {
        let manifestModules = try Self.libraryProductNames(
            inManifestAt: Self.repoRoot().appendingPathComponent("Package.swift")
        )
        let stale = Self.baselineScopeExclusions.subtracting(manifestModules)
        XCTAssertTrue(
            stale.isEmpty,
            "baselineScopeExclusions names product(s) absent from Package.swift: \(stale.sorted()). Remove the stale entries."
        )
    }

    // MARK: - Sabotage (exercises the real derivation functions)

    /// Plants a manifest and a script with a known disagreement and asserts the
    /// REAL parsers used above detect it. Without this, the derivation could
    /// silently return an empty set — an inert check that passes forever.
    func test_sabotage_derivationDetectsManifestScriptDrift() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("expected-modules-sabotage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let manifestURL = tmp.appendingPathComponent("Package.swift")
        try #"""
        let package = Package(
            products: [
                .library(name: "ManifoldAlpha", targets: ["ManifoldAlpha"]),
                .library(name: "ManifoldBeta", targets: ["ManifoldBeta"]),
                .library(
                    name: "ManifoldGamma",
                    targets: ["ManifoldGamma"]
                ),
                .executable(name: "some-tool", targets: ["some-tool"]),
                // Prose really does discuss products in this manifest, e.g.
                // .library(name: "ManifoldCommented", targets: ["x"]) — which
                // must NOT be picked up as a real product.
            ]
        )
        """#.write(to: manifestURL, atomically: true, encoding: .utf8)

        let parsed = try Self.libraryProductNames(inManifestAt: manifestURL)
        XCTAssertEqual(
            parsed, ["ManifoldAlpha", "ManifoldBeta", "ManifoldGamma"],
            """
            The derivation must find every .library product (including the multi-line form), \
            and must exclude both .executable products and any .library mentioned inside a comment.
            """
        )
        XCTAssertFalse(
            parsed.contains("ManifoldCommented"),
            "A .library(name:) inside a `//` comment must not be treated as a declared product."
        )

        // A script that has drifted: missing Gamma, and scoping a module the
        // manifest no longer declares.
        let scriptURL = tmp.appendingPathComponent("api-surface-baseline.sh")
        try #"""
        #!/usr/bin/env bash
        DEFAULT_MODULES="ManifoldAlpha ManifoldBeta ManifoldDeleted"
        """#.write(to: scriptURL, atomically: true, encoding: .utf8)

        let scriptModules = try Self.scriptDefaultModules(atScriptPath: scriptURL)
        XCTAssertEqual(scriptModules, ["ManifoldAlpha", "ManifoldBeta", "ManifoldDeleted"])

        XCTAssertEqual(
            parsed.subtracting(scriptModules), ["ManifoldGamma"],
            "A manifest product absent from DEFAULT_MODULES must surface as missing-from-script"
        )
        XCTAssertEqual(
            scriptModules.subtracting(parsed), ["ManifoldDeleted"],
            "A DEFAULT_MODULES entry with no matching product must surface as extra-in-script"
        )

        // The derivation must return EMPTY for a manifest it cannot parse,
        // rather than something plausible-looking. This is what makes the
        // count floor in `testEachModuleBaselineIsWellFormed` meaningful: an
        // unparseable manifest has to collapse to 0 so the floor trips, not
        // degrade quietly to a partial list.
        let unparseableURL = tmp.appendingPathComponent("Unparseable.swift")
        try "let package = Package(products: [])".write(to: unparseableURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(
            try Self.libraryProductNames(inManifestAt: unparseableURL).isEmpty,
            "A manifest with no .library products must derive an empty set, so the count floor trips."
        )
    }

    func testEachModuleBaselineIsWellFormed() throws {
        let modules = try Self.expectedModules()

        // Floor. Deriving the list from the manifest removed a drift risk but
        // introduced an inertness one the hardcoded array never had: if the
        // parse breaks (manifest reformatted, file moved, regex outgrown),
        // `expectedModules()` returns [], this loop body never runs, and the
        // test passes having checked nothing — green and inert, which is
        // exactly what a baseline gate must never be. The package has ~30
        // library products; dropping below 20 means the parse broke, not that
        // ten products were deliberately deleted.
        XCTAssertGreaterThan(
            modules.count, 20,
            """
            Derived only \(modules.count) module(s) from Package.swift — the manifest parse has broken, \
            and every per-module check below would silently pass by not running. \
            Fix the derivation rather than lowering this floor.
            """
        )

        for module in modules {
            let fileURL = Self.baselineDir().appendingPathComponent("\(module).txt")
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                XCTFail("Missing baseline for \(module): \(fileURL.path)")
                continue
            }
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

            if Self.expectedEmptyModules.contains(module) {
                XCTAssertTrue(lines.isEmpty, "\(module).txt is expected to be empty (see expectedEmptyModules) but has content — did a new public declaration get added? If so, remove it from expectedEmptyModules.")
                continue
            }
            XCTAssertFalse(lines.isEmpty, "\(module).txt is empty — expected a non-trivial public surface.")

            var previous: String?
            var seen = Set<String>()
            for (index, line) in lines.enumerated() {
                if let range = line.range(of: Self.conformancesMarker) {
                    Self.validateCommaList(line[range.upperBound...], moduleFile: "\(module).txt", lineIndex: index, line: line)
                } else if let range = line.range(of: Self.attrsMarker) {
                    let value = line[range.upperBound...]
                    Self.validateCommaList(value, moduleFile: "\(module).txt", lineIndex: index, line: line)
                    for attr in value.split(separator: ",") {
                        XCTAssertFalse(
                            Self.attrDenylist.contains(String(attr)),
                            "\(module).txt line \(index + 1) has a denylisted attribute `\(attr)` that should have been filtered: \(line)"
                        )
                    }
                } else {
                    // Shape: "<owner-or-owner.member> <declKind>" — split on
                    // the LAST space since owner/member text can itself
                    // contain spaces (e.g. printed generic constraints).
                    guard let lastSpaceIndex = line.range(of: " ", options: .backwards) else {
                        XCTFail("\(module).txt line \(index + 1) has no ` <kind>` suffix: \(line)")
                        continue
                    }
                    let kind = String(line[lastSpaceIndex.upperBound...])
                    XCTAssertTrue(
                        Self.knownKinds.contains(kind),
                        "\(module).txt line \(index + 1) has an unrecognized declKind `\(kind)`: \(line). "
                            + "Either the digester/extractor emitted something new (update knownKinds) or the file was hand-edited."
                    )
                }

                XCTAssertFalse(
                    seen.contains(line),
                    "\(module).txt line \(index + 1) is a duplicate: \(line). The normalizer de-duplicates via a set; a duplicate means the file was hand-edited or the generator regressed."
                )
                seen.insert(line)

                if let previous {
                    XCTAssertLessThanOrEqual(
                        previous, line,
                        "\(module).txt is not sorted at line \(index + 1) (`\(previous)` should sort before `\(line)`). "
                            + "Regenerate via scripts/api-surface-baseline.sh rather than hand-editing."
                    )
                }
                previous = line
            }
        }
    }

    // MARK: - Isolation/Sendable signal (Appendix A fixtures)

    /// Runs the normalizer directly against a minimal ABIRoot JSON fixture
    /// and returns its stdout lines, sorted (the normalizer's own contract).
    /// Unlike `testLiveCheckAgainstCurrentTree_optIn`, this needs no package
    /// build — just `python3` + the fixture file — so it's cheap enough to
    /// run in the default gate.
    private func runNormalizer(fixtureNamed name: String) throws -> [String] {
        let normalizerURL = Self.repoRoot().appendingPathComponent("scripts/_lib/api-surface-extract.py")
        let fixtureURL = Self.repoRoot().appendingPathComponent("Tests/APIFreezeTests/Fixtures/\(name).json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            XCTFail("Missing fixture: \(fixtureURL.path)")
            return []
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", normalizerURL.path, fixtureURL.path]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            process.terminationStatus, 0,
            "api-surface-extract.py failed on \(name).json: \(String(data: errData, encoding: .utf8) ?? "")"
        )

        let out = String(data: outData, encoding: .utf8) ?? ""
        return out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Appendix A's confirmed verdict (docs/RELEASE-1.0.md) was that a
    /// `ScratchIsolationProbe` public struct produced the BYTE-IDENTICAL
    /// normalized line (`ScratchIsolationProbe Struct`) whether it was
    /// unisolated, `@MainActor`, or explicitly `: Sendable`. These three
    /// fixtures reproduce that experiment's three probe states as minimal
    /// ABIRoot JSON (rather than re-running the real digester, which needs a
    /// full package build) and assert the FIXED normalizer now tells all
    /// three apart.
    func testIsolationSignal_threeProbeStatesProduceDistinctOutput() throws {
        let plain = try runNormalizer(fixtureNamed: "isolation-probe-plain")
        let mainActor = try runNormalizer(fixtureNamed: "isolation-probe-mainactor")
        let sendableOnly = try runNormalizer(fixtureNamed: "isolation-probe-sendable")

        // Pre-fix, these three sets were byte-identical (Appendix A's
        // confirmed blind spot). Post-fix, all three must differ.
        XCTAssertNotEqual(plain, mainActor, "plain and @MainActor fixtures produced identical output — the isolation blind spot has regressed.")
        XCTAssertNotEqual(plain, sendableOnly, "plain and explicit-Sendable fixtures produced identical output — the isolation blind spot has regressed.")
        XCTAssertNotEqual(mainActor, sendableOnly, "@MainActor and explicit-Sendable fixtures produced identical output — they should differ by the `attrs: Custom` line.")

        XCTAssertEqual(plain, ["ScratchIsolationProbe Struct", "ScratchIsolationProbe.value Var"])
        XCTAssertEqual(
            mainActor,
            [
                "ScratchIsolationProbe Struct",
                "ScratchIsolationProbe attrs: Custom",
                "ScratchIsolationProbe conformances: Sendable,SendableMetatype",
                "ScratchIsolationProbe.value Var",
            ]
        )
        XCTAssertEqual(
            sendableOnly,
            [
                "ScratchIsolationProbe Struct",
                "ScratchIsolationProbe conformances: Sendable,SendableMetatype",
                "ScratchIsolationProbe.value Var",
            ]
        )
    }

    // MARK: - Optional heavy check (opt-in only; not part of the default gate)

    /// Runs the REAL check — `scripts/api-surface-baseline.sh --check` —
    /// against the live tree. Gated behind an env var (mirrors
    /// `RUN_MCP_E2E=1`) because it needs a full package build and takes
    /// minutes; never runs as part of `scripts/test.sh --profile local`.
    func testLiveCheckAgainstCurrentTree_optIn() throws {
        guard ProcessInfo.processInfo.environment["RUN_API_SURFACE_BASELINE_CHECK"] == "1" else {
            throw XCTSkip("Set RUN_API_SURFACE_BASELINE_CHECK=1 to run the real (multi-minute) digester-backed check.")
        }
        #if !os(macOS)
        throw XCTSkip("Process-launch checks run on macOS only.")
        #else
        let scriptURL = Self.repoRoot().appendingPathComponent("scripts/api-surface-baseline.sh")
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            throw XCTSkip("scripts/api-surface-baseline.sh missing or not executable at \(scriptURL.path)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, "--check"]
        process.currentDirectoryURL = Self.repoRoot()

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let combined = (String(data: outData, encoding: .utf8) ?? "")
            + "\n--- stderr ---\n"
            + (String(data: errData, encoding: .utf8) ?? "")

        XCTAssertEqual(
            process.terminationStatus,
            0,
            "scripts/api-surface-baseline.sh --check reported public-surface drift or failed:\n\(combined)"
        )
        #endif
    }
}
