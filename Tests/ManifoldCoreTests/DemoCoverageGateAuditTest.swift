import XCTest

/// Gate test for the M0 demo-coverage instrument (issue #2453):
/// `scripts/demo-coverage.sh --check` enforces that every capability in
/// `scripts/demo-coverage-manifest.tsv` still meets R1 (a runnable vehicle),
/// R2 (a doc that exists on disk), and R3 (actually EXECUTED, not merely
/// compiled — `lane` in the executed-lane set AND `exec_kind` in
/// `{live, scripted}`; `exec_kind=compile` and `lane=manual` both score
/// R3=0, see the script header), and that none of the three has regressed
/// against `scripts/demo-coverage-baseline.tsv`. The aggregate public-type-
/// coverage percentage is reported in the scoreboard but deliberately NOT
/// part of this ratchet — it moves in both directions for reasons unrelated
/// to a demo-coverage regression (see the script header), and `--check`
/// never even invokes the Python helper that computes it (only the
/// scoreboard renderers do) — a defect in that helper cannot affect `--check`
/// or any sabotage test below that exercises `--check`.
///
/// This target (`ManifoldCoreTests`) is the same one `ScriptFailOpenAuditTest`
/// lives in, and is force-included by `scripts/affected-suites.sh` whenever
/// any `scripts/*.sh` file changes (the file the audit itself scans) — see
/// its own header comment. `scripts/affected-suites.sh` also carries an
/// explicit case mapping for the two `.tsv` data files this gate reads, so an
/// edit to either the manifest or the baseline selects this target too (see
/// AGENTS.md "The rule: a suite that reads or executes a file must be
/// selected when that file changes").
///
/// Sabotage coverage (per docs/QA-PRACTICES.md § 3 / `AuditSabotageCoverageAuditTest`)
/// runs the **real script** (and, for one case, the real Python helper) —
/// copied into a temp fixture, not reimplemented — against independently
/// planted violations. Every case asserts the offending row id (or the
/// specific error text) appears in the script's own output and that the
/// exit code is non-zero — an assertion a no-op cannot satisfy.
final class DemoCoverageGateAuditTest: XCTestCase {

    // MARK: - Real gate

    func test_demoCoverageCheckPasses() throws {
        let repoRoot = try Self.locateRepoRoot()
        let (status, output) = try Self.runScript(
            scriptPath: repoRoot.appendingPathComponent("scripts/demo-coverage.sh").path,
            arguments: ["--check"]
        )
        XCTAssertEqual(
            status, 0,
            "scripts/demo-coverage.sh --check must pass at the repo root — either the manifest " +
            "regressed against scripts/demo-coverage-baseline.tsv, or the baseline needs " +
            "regenerating with `scripts/demo-coverage.sh --update-baseline`. Output:\n\(output)"
        )
    }

    // MARK: - Sabotage (exercises the real script against planted fixtures)

    /// A manifest row whose `vehicle_path` does not exist on disk must fail
    /// manifest integrity (part a of `--check`) and name the offending row.
    func test_sabotage_flagsAMissingVehiclePath() throws {
        let fixture = try Self.plantFixture(
            manifestRows: [
                Self.row(id: "demo-cap", vehicleKind: "example-app",
                         vehiclePath: "App/DoesNotExist.swift", doc: "README.md",
                         lane: "per-pr", laneRef: "some-test", execKind: "scripted"),
            ],
            baselineRows: ["demo-cap\t1\t1\t1"]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let (status, output) = try Self.runScript(
            scriptPath: fixture.scriptPath, arguments: ["--check"]
        )
        XCTAssertNotEqual(status, 0, "A missing vehicle_path must fail the gate. Output:\n\(output)")
        XCTAssertTrue(
            output.contains("demo-cap") && output.contains("vehicle_path does not exist"),
            "The error must name the offending row id and the specific defect. Output:\n\(output)"
        )
    }

    /// A row whose `vehicle_path` equals its `doc` (a doc masquerading as its
    /// own demo vehicle — the real `app-eval` row's original defect) must
    /// fail manifest integrity and name the offending row.
    func test_sabotage_flagsAVehiclePathEqualToDoc() throws {
        let fixture = try Self.plantFixture(
            manifestRows: [
                Self.row(id: "demo-cap", vehicleKind: "example-app",
                         vehiclePath: "docs/SOME-DOC.md", doc: "docs/SOME-DOC.md",
                         lane: "per-pr", laneRef: "some-test", execKind: "scripted"),
            ],
            baselineRows: ["demo-cap\t1\t1\t1"],
            extraFiles: ["docs/SOME-DOC.md": "# doc\n"]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let (status, output) = try Self.runScript(
            scriptPath: fixture.scriptPath, arguments: ["--check"]
        )
        XCTAssertNotEqual(status, 0, "vehicle_path equal to doc must fail the gate. Output:\n\(output)")
        XCTAssertTrue(
            output.contains("demo-cap") && output.contains("vehicle_path equals doc"),
            "The error must name the offending row id and the specific defect. Output:\n\(output)"
        )
    }

    /// A row with an empty `title` must fail manifest integrity and name the
    /// offending row — `title` is the one column with no other constraint
    /// that would otherwise catch an empty value. Constructed by hand
    /// (bypassing `row()`, which always fills in a title) since this is
    /// exactly the defect `row()` cannot produce.
    func test_sabotage_flagsAnEmptyTitle() throws {
        let malformedRow = ["demo-cap", "", "SomeModule", "example-app",
                             "App/Vehicle.swift", "README.md", "per-pr", "some-test", "scripted", "—"]
            .joined(separator: "\t")  // empty title (2nd column)
        let fixture = try Self.plantFixture(
            manifestRows: [malformedRow],
            baselineRows: ["demo-cap\t1\t1\t1"],
            extraFiles: ["App/Vehicle.swift": "// vehicle\n"]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let (status, output) = try Self.runScript(
            scriptPath: fixture.scriptPath, arguments: ["--check"]
        )
        XCTAssertNotEqual(status, 0, "An empty title must fail the gate. Output:\n\(output)")
        XCTAssertTrue(
            output.contains("demo-cap") && output.contains("title is empty"),
            "The error must name the offending row id and the specific defect. Output:\n\(output)"
        )
    }

    /// A path-shaped `lane_ref` element (contains `/` or ends in
    /// `.yml`/`.swift`/`.sh`) that does not exist on disk must fail manifest
    /// integrity and name the offending row — the lane is `per-pr` (not
    /// `manual`/`external`), so the path promise is enforced.
    func test_sabotage_flagsADanglingPathShapedLaneRef() throws {
        let fixture = try Self.plantFixture(
            manifestRows: [
                Self.row(id: "demo-cap", vehicleKind: "example-app",
                         vehiclePath: "App/Vehicle.swift", doc: "README.md",
                         lane: "per-pr", laneRef: "Tests/DoesNotExistUITests.swift", execKind: "scripted"),
            ],
            baselineRows: ["demo-cap\t1\t1\t1"],
            extraFiles: ["App/Vehicle.swift": "// vehicle\n"]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let (status, output) = try Self.runScript(
            scriptPath: fixture.scriptPath, arguments: ["--check"]
        )
        XCTAssertNotEqual(status, 0, "A dangling path-shaped lane_ref must fail the gate. Output:\n\(output)")
        XCTAssertTrue(
            output.contains("demo-cap") && output.contains("lane_ref element does not exist"),
            "The error must name the offending row id and the specific defect. Output:\n\(output)"
        )
    }

    /// A row with the wrong number of tab-separated columns (9 instead of
    /// 10 — missing `notes`) must fail manifest integrity and name the
    /// offending row. Constructed by hand (bypassing the `row()` helper,
    /// which always emits a well-formed row) since this is exactly the
    /// defect `row()` cannot produce.
    func test_sabotage_flagsAWrongColumnCountRow() throws {
        let malformedRow = ["demo-cap", "demo-cap title", "SomeModule", "example-app",
                             "App/Vehicle.swift", "README.md", "per-pr", "some-test", "scripted"]
            .joined(separator: "\t")  // 9 columns: missing `notes`
        let fixture = try Self.plantFixture(
            manifestRows: [malformedRow],
            baselineRows: ["demo-cap\t1\t1\t1"],
            extraFiles: ["App/Vehicle.swift": "// vehicle\n"]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let (status, output) = try Self.runScript(
            scriptPath: fixture.scriptPath, arguments: ["--check"]
        )
        XCTAssertNotEqual(status, 0, "A wrong-column-count row must fail the gate. Output:\n\(output)")
        XCTAssertTrue(
            output.contains("demo-cap") && output.contains("expected 10 tab-separated columns"),
            "The error must name the offending row id and the column-count defect. Output:\n\(output)"
        )
    }

    /// A row whose `exec_kind` is `compile` (build-only, nothing executes)
    /// but whose baseline still claims R3=1 (executed) must fail the ratchet
    /// and name the offending row — this is exactly the defect fix 7 exists
    /// to catch: a lane that only compiles must never read as executed.
    func test_sabotage_flagsACompileExecKindRegressedFromBaselineR3() throws {
        let fixture = try Self.plantFixture(
            manifestRows: [
                Self.row(id: "demo-cap", vehicleKind: "example-app",
                         vehiclePath: "App/Vehicle.swift", doc: "README.md",
                         lane: "per-pr", laneRef: "some-test", execKind: "compile",
                         notes: "compile-only; real execution would require adding a test action"),
            ],
            baselineRows: ["demo-cap\t1\t1\t1"],
            extraFiles: ["App/Vehicle.swift": "// vehicle\n"]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let (status, output) = try Self.runScript(
            scriptPath: fixture.scriptPath, arguments: ["--check"]
        )
        XCTAssertNotEqual(status, 0, "exec_kind=compile regressed from a baseline R3=1 must fail the gate. Output:\n\(output)")
        XCTAssertTrue(
            output.contains("demo-cap") && output.contains("R3 regressed"),
            "The error must name the offending row id and say R3 regressed. Output:\n\(output)"
        )
    }

    /// A missing `Example/` directory must fail the type-coverage helper
    /// closed (fix 8) — and `scripts/demo-coverage.sh`'s default (scoreboard)
    /// mode must propagate that failure rather than silently reporting 0/0.
    /// The api-surface-baseline directory IS present (with one dummy file)
    /// so this fixture isolates the assertion to the missing-Example defect
    /// specifically, not the baseline-dir check that runs first.
    func test_sabotage_flagsAMissingExampleDirectory() throws {
        let fixture = try Self.plantFixture(
            manifestRows: [
                Self.row(id: "demo-cap", vehicleKind: "example-app",
                         vehiclePath: "App/Vehicle.swift", doc: "README.md",
                         lane: "per-pr", laneRef: "some-test", execKind: "scripted"),
            ],
            baselineRows: ["demo-cap\t1\t1\t1"],
            extraFiles: [
                "App/Vehicle.swift": "// vehicle\n",
                "Tests/APIFreezeTests/api-surface-baseline/SomeModule.txt": "SomeType Struct\n",
            ]
            // Example/ deliberately NOT created.
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let (status, output) = try Self.runScript(
            scriptPath: fixture.scriptPath, arguments: []  // default scoreboard mode — the only mode that calls the helper
        )
        XCTAssertNotEqual(status, 0, "A missing Example/ directory must fail closed, not report 0/0. Output:\n\(output)")
        XCTAssertTrue(
            output.contains("Example root directory does not exist"),
            "The error must name the specific defect the Python helper detected. Output:\n\(output)"
        )
    }

    /// A clean fixture (manifest + baseline agree, everything referenced
    /// exists) must pass — proves the sabotage tests above are actually
    /// detecting their planted defect, not failing on fixture scaffolding.
    func test_sabotage_cleanFixturePasses() throws {
        let fixture = try Self.plantFixture(
            manifestRows: [
                Self.row(id: "demo-cap", vehicleKind: "example-app",
                         vehiclePath: "App/Vehicle.swift", doc: "README.md",
                         lane: "per-pr", laneRef: "some-test", execKind: "scripted"),
            ],
            baselineRows: ["demo-cap\t1\t1\t1"],
            extraFiles: ["App/Vehicle.swift": "// vehicle\n"]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let (status, output) = try Self.runScript(
            scriptPath: fixture.scriptPath, arguments: ["--check"]
        )
        XCTAssertEqual(status, 0, "A clean fixture must pass. Output:\n\(output)")
    }

    // MARK: - Fixture construction

    private struct Fixture {
        let root: URL
        let scriptPath: String
    }

    /// Builds a minimal repo the real script can run against: its own copy
    /// of `demo-coverage.sh` and `_lib/demo-coverage-types.py` (so `REPO_ROOT`,
    /// derived from `BASH_SOURCE`, resolves to the temp tree), a manifest, a
    /// baseline, and a `README.md` every row's `doc` column can point at.
    /// `Tests/APIFreezeTests/api-surface-baseline/` and `Example/` are left
    /// absent by default (added via `extraFiles` only by the one test that
    /// needs them) — safe for every `--check`-only sabotage test above
    /// because `--check` scores R1/R2/R3 entirely from `current_state`,
    /// which reads only the manifest, and NEVER invokes the Python
    /// type-coverage helper (only the scoreboard renderers do).
    private static func plantFixture(
        manifestRows: [String],
        baselineRows: [String],
        extraFiles: [String: String] = [:]
    ) throws -> Fixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("demo-coverage-sabotage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("scripts/_lib"), withIntermediateDirectories: true)

        let repoRoot = try Self.locateRepoRoot()
        try fm.copyItem(
            at: repoRoot.appendingPathComponent("scripts/demo-coverage.sh"),
            to: root.appendingPathComponent("scripts/demo-coverage.sh")
        )
        try fm.copyItem(
            at: repoRoot.appendingPathComponent("scripts/_lib/demo-coverage-types.py"),
            to: root.appendingPathComponent("scripts/_lib/demo-coverage-types.py")
        )

        let header = "id\ttitle\tproducts\tvehicle_kind\tvehicle_path\tdoc\tlane\tlane_ref\texec_kind\tnotes\n"
        try (header + manifestRows.joined(separator: "\n") + "\n")
            .write(to: root.appendingPathComponent("scripts/demo-coverage-manifest.tsv"), atomically: true, encoding: .utf8)

        let baselineHeader = "id\tr1\tr2\tr3\n"
        try (baselineHeader + baselineRows.joined(separator: "\n") + "\n")
            .write(to: root.appendingPathComponent("scripts/demo-coverage-baseline.tsv"), atomically: true, encoding: .utf8)

        try "# Fixture README\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        for (relativePath, content) in extraFiles {
            let fileURL = root.appendingPathComponent(relativePath)
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        return Fixture(root: root, scriptPath: root.appendingPathComponent("scripts/demo-coverage.sh").path)
    }

    /// One manifest data row, tab-joined in column order
    /// (id/title/products/vehicle_kind/vehicle_path/doc/lane/lane_ref/exec_kind/notes).
    private static func row(
        id: String, vehicleKind: String, vehiclePath: String, doc: String,
        lane: String, laneRef: String, execKind: String,
        products: String = "SomeModule", notes: String = "—"
    ) -> String {
        [id, "\(id) title", products, vehicleKind, vehiclePath, doc, lane, laneRef, execKind, notes]
            .joined(separator: "\t")
    }

    // MARK: - Process helper

    private static func runScript(scriptPath: String, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Read before waiting: a full pipe buffer would deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func locateRepoRoot(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "DemoCoverageGateAuditTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Package.swift from #filePath",
        ])
    }
}
