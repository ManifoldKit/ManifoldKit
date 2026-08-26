import XCTest

/// Tripwire for the two release-only steps in `.github/workflows/lint.yml`.
///
/// Those steps are gated on `steps.release_context.outputs.is_release`, and
/// the only CI this PR can produce on a non-release change is the *skip*
/// path. A typo in an `if:` (or dropping `merge_group` from the
/// `--release` step) leaves every ordinary lint run green and is
/// indistinguishable from an inert gate. This audit reads the workflow
/// text and asserts the load-bearing `if:` shapes are still present.
///
/// Completeness (`migration-index-check.sh` with no `--release`) is
/// separately demonstrated by #2463; this file is specifically the
/// skip-path-green hole for the two *release* steps.
final class ReleaseReadinessWorkflowAuditTest: XCTestCase {

    func test_releaseGateIfConditionsAreLive() throws {
        let workflow = try Self.loadLintWorkflow()
        let violations = Self.ifConditionViolations(in: workflow)
        if !violations.isEmpty {
            XCTFail("""
                .github/workflows/lint.yml release-gate `if:` conditions drifted. \
                A skip-path-green lint run cannot prove these fire:

                \(violations.map { "  - \($0)" }.joined(separator: "\n"))
                """)
        }
    }

    /// Plants a workflow whose companion-canary dispatch `if:` has dropped
    /// `is_release`, and whose `--release` step has dropped `merge_group`,
    /// and asserts ``ifConditionViolations(in:)`` flags both.
    func test_sabotage_ifConditionViolationsDetectsDroppedPredicates() {
        let sabotaged = """
            - name: "companion-canary-gate (pull_request) — dispatch fresh companion canary runs and wait"
              if: always() && github.event_name == 'pull_request'
              run: bash scripts/companion-canary-check.sh --dispatch

            - name: migration-index-gate — no migration-note row may still say "next"
              if: always() && github.event_name == 'pull_request' && steps.release_context.outputs.is_release == 'true'
              run: bash scripts/migration-index-check.sh --release

            - name: "migration-index-completeness — every docs/MIGRATION-*.md has an index row"
              if: always()
              run: bash scripts/migration-index-check.sh
            """
        let violations = Self.ifConditionViolations(in: sabotaged)
        XCTAssertTrue(
            violations.contains(where: { $0.contains("companion-canary") && $0.contains("is_release") }),
            "dropping is_release from the canary dispatch if: must be flagged: \(violations)"
        )
        XCTAssertTrue(
            violations.contains(where: { $0.contains("migration-index-gate") && $0.contains("merge_group") }),
            "dropping merge_group from the --release if: must be flagged: \(violations)"
        )
        XCTAssertTrue(
            violations.contains(where: { $0.contains("release_context") }),
            "a workflow with no release_context step must be flagged: \(violations)"
        )
    }

    /// Safe demonstrated-red fixture for the release-context gate: restoring
    /// the original string-inequality predicate makes an older branch version
    /// look like a release. The audit must reject that workflow shape before
    /// it can ship as a skip-path-green required check.
    func test_sabotage_releaseContextRejectsStringInequalityComparison() {
        let sabotaged = """
            id: release_context
            echo "is_release=true" >> "$GITHUB_OUTPUT"
            echo "is_release=false" >> "$GITHUB_OUTPUT"
            if [ "$current_version" != "$latest_version" ]; then
              echo "is_release=true" >> "$GITHUB_OUTPUT"
            fi
            """

        let violations = Self.releaseContextViolations(in: sabotaged)
        XCTAssertTrue(
            violations.contains(where: { $0.contains("strict-SemVer comparator") }),
            "a string-inequality release predicate must be rejected: \(violations)"
        )
        XCTAssertTrue(
            violations.contains(where: { $0.contains("fail closed") }),
            "the malformed-SemVer failure path must remain load-bearing: \(violations)"
        )
    }

    // MARK: - Detection

    /// Walks `workflow` as text (same shape as other workflow audits — we
    /// do not YAML-parse) and returns one string per missing predicate.
    static func ifConditionViolations(in workflow: String) -> [String] {
        var violations: [String] = []

        guard let canaryIf = Self.ifLine(
            afterNameContaining: "companion-canary-gate (pull_request)",
            in: workflow
        ) else {
            violations.append("missing companion-canary-gate (pull_request) dispatch step")
            return violations + Self.releaseAndCompletenessViolations(in: workflow)
        }
        if !canaryIf.contains("pull_request") {
            violations.append("companion-canary dispatch if: must require pull_request")
        }
        if !canaryIf.contains("is_release") {
            violations.append("companion-canary dispatch if: must require is_release")
        }

        violations.append(contentsOf: Self.releaseAndCompletenessViolations(in: workflow))
        violations.append(contentsOf: Self.releaseContextViolations(in: workflow))
        return violations
    }

    /// The `if:` predicates are inert if nothing writes `is_release`.
    private static func releaseContextViolations(in workflow: String) -> [String] {
        var violations: [String] = []
        if !workflow.contains("id: release_context") {
            violations.append("missing release_context step id — is_release would be always empty and both gates would skip")
        }
        if !workflow.contains("is_release=true") {
            violations.append("release_context never writes is_release=true")
        }
        if !workflow.contains("is_release=false") {
            violations.append("release_context never writes is_release=false")
        }
        if !workflow.contains("bash scripts/release-context-check.sh --is-strictly-greater") {
            violations.append("release_context must invoke the tested strict-SemVer comparator, not use string inequality")
        }
        if !workflow.contains("Could not compare version.txt") {
            violations.append("release_context comparator must fail closed on malformed SemVer input")
        }
        return violations
    }

    private static func releaseAndCompletenessViolations(in workflow: String) -> [String] {
        var violations: [String] = []

        guard let releaseIf = Self.ifLine(
            afterNameContaining: "migration-index-gate — no migration-note row may still say",
            in: workflow
        ) else {
            violations.append("missing migration-index-gate --release step")
            return violations
        }
        if !releaseIf.contains("is_release") {
            violations.append("migration-index-gate --release if: must require is_release")
        }
        if !releaseIf.contains("merge_group") {
            violations.append("migration-index-gate --release if: must include merge_group (leftover next rows in the tagged tree are true positives)")
        }
        if !releaseIf.contains("pull_request") {
            violations.append("migration-index-gate --release if: must include pull_request")
        }

        guard let completenessIf = Self.ifLine(
            afterNameContaining: "migration-index-completeness",
            in: workflow
        ) else {
            violations.append("missing migration-index-completeness step")
            return violations
        }
        if !completenessIf.contains("always()") {
            violations.append("migration-index-completeness if: must be always() so docs-only PRs still run it")
        }
        return violations
    }

    /// The `if:` line of the first step whose `- name:` contains `needle`.
    private static func ifLine(afterNameContaining needle: String, in workflow: String) -> String? {
        let lines = workflow.components(separatedBy: .newlines)
        guard let nameIndex = lines.firstIndex(where: { $0.contains("- name:") && $0.contains(needle) }) else {
            return nil
        }
        for line in lines.dropFirst(nameIndex + 1).prefix(8) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("if:") {
                return trimmed
            }
            if trimmed.hasPrefix("- name:") {
                break
            }
        }
        return nil
    }

    private static func loadLintWorkflow() throws -> String {
        let root = try locateRepoRoot()
        let url = root.appendingPathComponent(".github/workflows/lint.yml")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func locateRepoRoot(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "ReleaseReadinessWorkflowAuditTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Package.swift from #filePath",
        ])
    }
}
