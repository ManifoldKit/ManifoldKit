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

    /// The module list `scripts/api-surface-baseline.sh` scopes to by
    /// default: every `.library(...)` product in Package.swift (see the
    /// script's "Module scope" header section). Kept in sync by hand —
    /// update here, in the script's `DEFAULT_MODULES`, and in
    /// Package.swift's `products:` array together.
    private static let expectedModules = [
        "ManifoldKit",
        "ManifoldInference",
        "ManifoldContract",
        "ManifoldNetworking",
        "ManifoldSecrets",
        "ManifoldHardware",
        "ManifoldModelCatalog",
        "ManifoldMCP",
        "ManifoldMCPHost",
        "ManifoldRuntime",
        "ManifoldPersistenceSwiftData",
        "ManifoldCloudCore",
        "ManifoldFoundation",
        "ManifoldOllama",
        "ManifoldCloudSaaS",
        "ManifoldAnyLanguageModel",
        "ManifoldUI",
        "ManifoldUIModelManagement",
        "ManifoldHuggingFace",
        "ManifoldVoice",
        "ManifoldFuzz",
        "ManifoldTestSupport",
        "ManifoldPersistenceTestSupport",
        "ManifoldBackendTestKit",
        "ManifoldTools",
        "ManifoldAppIntents",
        "ManifoldSkills",
        "ManifoldTelemetryOTLP",
        "ManifoldAppEval",
    ]

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

    /// For each scoped module: the baseline file exists, is non-empty,
    /// every line matches `<name> <knownKind>`, and the file is already
    /// sorted + de-duplicated (the normalizer's contract — a diff-stable
    /// baseline depends on this).
    func testEachModuleBaselineIsWellFormed() throws {
        for module in Self.expectedModules {
            let fileURL = Self.baselineDir().appendingPathComponent("\(module).txt")
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                XCTFail("Missing baseline for \(module): \(fileURL.path)")
                continue
            }
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

            XCTAssertFalse(lines.isEmpty, "\(module).txt is empty — expected a non-trivial public surface.")

            var previous: String?
            var seen = Set<String>()
            for (index, line) in lines.enumerated() {
                // Shape: "<owner-or-owner.member> <declKind>" — split on the
                // LAST space since owner/member text can itself contain
                // spaces (e.g. printed generic constraints).
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
