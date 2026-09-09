import XCTest

/// End-to-end fixture coverage for the `evalmain` repository boundary in
/// `scripts/local-integration-sweep.sh`.
///
/// The fixture uses real Git repositories and a real linked worktree. Swift is
/// replaced with a recording executable so this suite proves command routing
/// without compiling ManifoldKit and manifold-eval during every unit gate.
final class LocalIntegrationSweepScriptTests: XCTestCase {
    func test_evalmain_acceptsOrdinaryCheckoutAndLinkedWorktree() throws {
        let fixture = try makeGitFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        for (name, evalDirectory) in [
            ("checkout", fixture.checkout),
            ("linked-worktree", fixture.linkedWorktree),
        ] {
            let outputDirectory = fixture.root.appendingPathComponent("out-\(name)")
            let invocationLog = fixture.root.appendingPathComponent("swift-\(name).log")
            let result = try runSweep(
                evalDirectory: evalDirectory,
                outputDirectory: outputDirectory,
                fakeBin: fixture.fakeBin,
                invocationLog: invocationLog
            )

            XCTAssertEqual(
                result.status,
                0,
                "evalmain must run from a \(name), not skip it. Output:\n\(result.output)"
            )
            let invocations = try String(contentsOf: invocationLog, encoding: .utf8)
            XCTAssertTrue(invocations.contains("package edit manifoldkit --path "), invocations)
            XCTAssertTrue(invocations.split(separator: "\n").contains("build"), invocations)
            XCTAssertTrue(invocations.split(separator: "\n").contains("test"), invocations)
            XCTAssertTrue(
                result.report.contains("evalmain: pass (passed=1 failed=0 skipped=0)"),
                "The accepted repository must reach the isolated clone and test lane. Report:\n\(result.report)"
            )
        }
    }

    func test_evalmain_reportsAbsentAndInvalidGitDirectoriesAsNoWork() throws {
        let fixture = try makeGitFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let invalidGit = fixture.root.appendingPathComponent("invalid-git", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidGit, withIntermediateDirectories: true)
        try packageManifest.write(
            to: invalidGit.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "gitdir: /definitely/missing\n".write(
            to: invalidGit.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )

        let absent = fixture.root.appendingPathComponent("absent")
        for (name, evalDirectory) in [("invalid", invalidGit), ("absent", absent)] {
            let result = try runSweep(
                evalDirectory: evalDirectory,
                outputDirectory: fixture.root.appendingPathComponent("out-\(name)"),
                fakeBin: fixture.fakeBin,
                invocationLog: fixture.root.appendingPathComponent("swift-\(name).log")
            )

            XCTAssertEqual(result.status, 1, "A \(name) repo must make the sweep non-zero")
            XCTAssertTrue(
                result.report.contains("evalmain: SKIP-NO-WORK (manifold-eval absent (or not a git repo)"),
                "A \(name) repo must be reported as no work. Report:\n\(result.report)"
            )
            XCTAssertTrue(result.report.contains("1 REQUESTED LANE(S) DID NO WORK"), result.report)
        }
    }

    private struct GitFixture {
        let root: URL
        let checkout: URL
        let linkedWorktree: URL
        let fakeBin: URL
    }

    private var packageManifest: String {
        """
        // swift-tools-version: 6.2
        import PackageDescription
        // Pinned in the real project: https://github.com/ManifoldKit/ManifoldKit.git
        let package = Package(name: "Fixture")
        """
    }

    private func makeGitFixture() throws -> GitFixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("evalmain-worktree-\(UUID().uuidString)", isDirectory: true)
        let checkout = root.appendingPathComponent("checkout", isDirectory: true)
        let linkedWorktree = root.appendingPathComponent("linked", isDirectory: true)
        let bareOrigin = root.appendingPathComponent("origin.git", isDirectory: true)
        let fakeBin = root.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: checkout, withIntermediateDirectories: true)
        try fm.createDirectory(at: fakeBin, withIntermediateDirectories: true)

        try runGit(["init", "--bare", bareOrigin.path], currentDirectory: root)
        try runGit(["init"], currentDirectory: checkout)
        try runGit(["config", "user.name", "Fixture"], currentDirectory: checkout)
        try runGit(["config", "user.email", "fixture@example.invalid"], currentDirectory: checkout)
        try packageManifest.write(
            to: checkout.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "Package.swift"], currentDirectory: checkout)
        try runGit(["commit", "-m", "chore: seed fixture"], currentDirectory: checkout)
        try runGit(["remote", "add", "origin", bareOrigin.path], currentDirectory: checkout)
        try runGit(["push", "-u", "origin", "HEAD:main"], currentDirectory: checkout)
        try runGit(["worktree", "add", "--detach", linkedWorktree.path], currentDirectory: checkout)

        let fakeSwift = fakeBin.appendingPathComponent("swift")
        try """
        #!/bin/bash
        printf '%s\\n' "$*" >> "$SWIFT_INVOCATIONS"
        if [ "$1" = "test" ]; then
          echo "Test Case 'EvalFixtureTests.testSmoke' passed (0.001 seconds)"
        fi
        exit 0
        """.write(to: fakeSwift, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSwift.path)

        return GitFixture(
            root: root,
            checkout: checkout,
            linkedWorktree: linkedWorktree,
            fakeBin: fakeBin
        )
    }

    private func runSweep(
        evalDirectory: URL,
        outputDirectory: URL,
        fakeBin: URL,
        invocationLog: URL
    ) throws -> (status: Int32, output: String, report: String) {
        let repoRoot = try Self.locateRepoRoot()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            repoRoot.appendingPathComponent("scripts/local-integration-sweep.sh").path,
            "--lanes", "evalmain",
            "--out", outputDirectory.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin"
        environment["EVAL_DIR"] = evalDirectory.path
        environment["MODELS_DIR"] = evalDirectory
            .appendingPathComponent("no-models", isDirectory: true).path
        environment["COMPANIONS_DIR"] = evalDirectory
            .appendingPathComponent("no-companions", isDirectory: true).path
        environment["SWIFT_INVOCATIONS"] = invocationLog.path
        environment["SKIP_NEGATIVE_CONTROL"] = "1"
        environment["LANE_TIMEOUT"] = "2"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        let reportURL = outputDirectory.appendingPathComponent("REPORT.md")
        let report = (try? String(contentsOf: reportURL, encoding: .utf8)) ?? ""
        return (process.terminationStatus, output, report)
    }

    private func runGit(_ arguments: [String], currentDirectory: URL) throws {
        let isolatedArguments = [
            "-c", "commit.gpgsign=false",
            "-c", "core.hooksPath=/dev/null",
        ] + arguments
        let result = try run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: isolatedArguments,
            currentDirectory: currentDirectory
        )
        guard result.status == 0 else {
            throw NSError(domain: "LocalIntegrationSweepScriptTests", code: Int(result.status), userInfo: [
                NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed:\n\(result.output)",
            ])
        }
    }

    private func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func locateRepoRoot(filePath: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Package.swift").path
            ) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        throw NSError(domain: "LocalIntegrationSweepScriptTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Package.swift from #filePath",
        ])
    }
}
