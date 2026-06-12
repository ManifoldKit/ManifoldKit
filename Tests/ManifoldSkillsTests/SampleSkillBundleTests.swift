import XCTest
@testable import ManifoldSkills

/// Smoke-tests the SKILL.md file bundled with the Advanced demo app
/// (`Example/Advanced/SampleSkills/explain/SKILL.md`).
///
/// This is the W3B "shape-only" gate the brief calls for: the
/// `skill-explain` demo card depends on this file parsing cleanly via the
/// same `SkillLoader` machinery host apps use. If a future edit introduces
/// malformed frontmatter or drops a required field, this test fails before
/// the demo silently stops surfacing the skill at runtime.
///
/// Headless UITest coverage of the full LLM-driven path is deferred to a
/// nightly tier per the W3B brief — model-driven `invoke_skill` calls
/// flake too often to ship as per-PR CI.
final class SampleSkillBundleTests: XCTestCase {

    /// Locates the demo app's bundled sample-skills directory relative to
    /// this test file's path. Uses `#filePath` so the test stays
    /// CI-portable (the test runner's `Bundle.module` does not include
    /// files outside the test target).
    private func sampleSkillsRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()                  // ManifoldSkillsTests/
            .deletingLastPathComponent()                  // Tests/
            .deletingLastPathComponent()                  // repo root
            .appendingPathComponent("Example/Advanced/SampleSkills", isDirectory: true)
    }

    func test_bundledExplainSkill_parsesViaSkillLoader() throws {
        #if !os(macOS)
        throw XCTSkip("SkillLoader discovery is macOS-only in v1")
        #else
        let root = sampleSkillsRoot()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("explain/SKILL.md").path),
            "Bundled sample skill file must exist at Example/Advanced/SampleSkills/explain/SKILL.md"
        )

        let loader = SkillLoader(searchPaths: [root])
        let skills = loader.discover()

        guard let explain = skills.first(where: { $0.name == "explain" }) else {
            XCTFail("SkillLoader did not discover 'explain' skill in bundled SampleSkills dir")
            return
        }

        XCTAssertEqual(explain.name, "explain")
        XCTAssertFalse(explain.description.isEmpty, "description is required")
        XCTAssertEqual(explain.aliases, ["eli5"])
        // `allowed-tools` not set → no restriction; nil is the sentinel.
        XCTAssertNil(explain.allowedTools)
        XCTAssertNotNil(explain.whenToUse)
        XCTAssertFalse(explain.promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        // Sabotage-evidence M1: removing the SKILL.md file causes discover()
        // to return an empty array and the `guard let explain` above fails.
        // M2: malforming the frontmatter (e.g. dropping `description:`)
        // makes SkillLoader log a warning and skip the entry — the guard
        // again fails. M3: typo'ing the alias to `aliases: ["E.L.I.5"]`
        // makes `XCTAssertEqual(explain.aliases, ["eli5"])` fail. All three
        // checked locally before commit.
        #endif
    }
}
