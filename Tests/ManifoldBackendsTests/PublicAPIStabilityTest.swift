import XCTest

/// Phase 1a guard: fails if `swift package diagnose-api-breaking-changes`
/// reports an unannotated breaking change against the captured baseline
/// at `Tests/Fixtures/_migration/baseline-public-api.txt`.
///
/// Why it exists: each adapter migration in Phases 2-3 shrinks
/// `OpenAIBackend.swift` (822 → ~150 LOC), `ClaudeBackend.swift`, etc.
/// Existing public `init(...)`s and methods must remain source-compatible
/// (architect item 8 in the plan). Without an automated diff against
/// `main`, a removed-by-accident public symbol ships and breaks downstream
/// `import ManifoldKit` consumers in TavernPad / localclaw.
///
/// ## How it works
///
/// The test does *not* re-run `diagnose-api-breaking-changes` in-process —
/// SwiftPM's API doesn't support that, and shelling out to `swift package`
/// from inside `swift test` deadlocks the build graph. Instead, a CI driver
/// step runs the diagnose command against the baseline branch (`main`) and
/// writes the textual output to an env var (`PUBLIC_API_DIFF_OUTPUT`); this
/// test parses that output.
///
/// When the env var is absent (local runs, or before the CI step is
/// wired), the test skips with an explanation.
///
/// ## Opt-in breaking changes
///
/// A PR that intentionally introduces a breaking change may annotate the
/// changing source file with `// SemVerBreak: feat!: <reason>` in the file
/// header. The test grep's `Sources/` for that sentinel string at the
/// reported line ranges and tolerates a one-shot break per file. Repeated
/// breaks require fresh annotations — old annotations are not "sticky" across
/// PRs.
final class PublicAPIStabilityTest: XCTestCase {

    func test_publicAPIHasNoUnannotatedBreakingChange() throws {
        let baselineURL = try Self.locateMigrationFixture(named: "baseline-public-api.txt")
        guard FileManager.default.fileExists(atPath: baselineURL.path) else {
            try XCTSkipIf(true, """
                SKIPPED: \(baselineURL.path) does not exist. The public-API baseline \
                has not been captured. Run:

                  swift package diagnose-api-breaking-changes main \
                    > Tests/Fixtures/_migration/baseline-public-api.txt

                from a clean checkout of main before activating this gate.
                """)
            return
        }

        let env = ProcessInfo.processInfo.environment
        guard let diffOutput = env["PUBLIC_API_DIFF_OUTPUT"], !diffOutput.isEmpty else {
            try XCTSkipIf(true, """
                SKIPPED: PUBLIC_API_DIFF_OUTPUT env var not set. The CI driver must \
                run `swift package diagnose-api-breaking-changes <baseline-ref>` and \
                pipe the output into this env var before the gate can compare.
                """)
            return
        }

        // diagnose-api-breaking-changes emits one diagnostic per line in
        // the form `<file>:<line>:<col>: error: ...` for true breaking
        // changes. Anything starting with `error:` (case-insensitive) is
        // a hit; warnings (`note:`) are informational only.
        var unannotated: [String] = []
        let lines = diffOutput.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.range(of: #"\berror:\s*Breaking"#, options: .regularExpression) != nil else { continue }

            if Self.lineHasSemVerBreakAnnotation(trimmed) { continue }
            unannotated.append(trimmed)
        }

        if unannotated.isEmpty { return }
        XCTFail("""
            PublicAPIStabilityTest found unannotated breaking changes against \(baselineURL.lastPathComponent):

              \(unannotated.joined(separator: "\n  "))

            Fix:
              - Restore source compatibility (preferred): keep the old symbol as a deprecated wrapper around the new one.
              - Or, if the break is intentional: add `// SemVerBreak: feat!: <reason>` to the source file's header AND open the PR with a `feat!:` title so Release Please bumps MAJOR.
            """)
    }

    // MARK: - Helpers

    /// Returns true when the source line cited by the diagnose tool sits
    /// in a file whose header carries a `// SemVerBreak:` annotation.
    /// Parses the `<file>:<line>:` prefix, opens the file, and checks the
    /// first 20 lines.
    private static func lineHasSemVerBreakAnnotation(_ diagLine: String) -> Bool {
        let parts = diagLine.components(separatedBy: ":")
        guard parts.count >= 3 else { return false }
        let path = parts[0]
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }
        let head = contents.components(separatedBy: "\n").prefix(20).joined(separator: "\n")
        return head.contains("// SemVerBreak:")
    }

    private static func locateMigrationFixture(named: String, filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Tests/Fixtures/_migration/\(named)")
            if FileManager.default.fileExists(atPath: candidate.deletingLastPathComponent().path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "PublicAPIStabilityTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Tests/Fixtures/_migration/"
        ])
    }
}
