import XCTest
import ManifoldInference
import ManifoldRuntime
@testable import ManifoldSkills

/// Security-boundary tests: an active skill with `allowed-tools` MUST narrow
/// the advertised tool surface to exactly that list (or deny-all when the
/// list is empty).
final class AllowedToolsEnforcementTests: XCTestCase {

    private func makeSource(skill: Skill) async -> (SkillToolSource, ChatSession) {
        let registry = SkillRegistry()
        await registry.load([skill])
        let source = SkillToolSource(registry: registry)
        let session = ChatSession(id: UUID(), title: "fixture")
        await source.markActive(skillName: skill.name, for: session.id)
        return (source, session)
    }

    func test_allowedToolNames_emptyAllowedTools_returnsEmptySet() async {
        let skill = Skill(
            name: "prompt-only",
            description: "no tools",
            allowedTools: [],
            promptTemplate: "body",
            sourcePath: URL(fileURLWithPath: "/tmp/prompt-only/SKILL.md")
        )
        let (source, session) = await makeSource(skill: skill)
        let allowed = await source.allowedToolNames(for: session)
        XCTAssertEqual(allowed, Set<String>())
        // Sabotage-evidence: M1 change the `allowedTools == nil` short-circuit
        // to also short-circuit on `allowedTools.isEmpty` → returns nil and
        // assertion fails; M2 swap empty array for nil in the skill init →
        // returns nil and assertion fails; M3 inject `invoke_skill` into
        // the returned set → equality fails.
    }

    func test_allowedToolNames_subsetAllowedTools_returnsThatSubset() async {
        let skill = Skill(
            name: "narrow",
            description: "narrow scope",
            allowedTools: ["read_file", "list_dir"],
            promptTemplate: "body",
            sourcePath: URL(fileURLWithPath: "/tmp/narrow/SKILL.md")
        )
        let (source, session) = await makeSource(skill: skill)
        let allowed = await source.allowedToolNames(for: session)
        XCTAssertEqual(allowed, Set(["read_file", "list_dir"]))
        // Sabotage-evidence: M1 hard-code Set(["read_file"]) → assertion
        // fails (missing list_dir); M2 swap to nil → fails; M3 return
        // `Set(allowed).union(["something_else"])` → assertion fails on
        // superset.
    }

    func test_allowedToolNames_nilAllowedTools_returnsNil() async {
        let skill = Skill(
            name: "unrestricted",
            description: "no restriction",
            allowedTools: nil,
            promptTemplate: "body",
            sourcePath: URL(fileURLWithPath: "/tmp/unrestricted/SKILL.md")
        )
        let (source, session) = await makeSource(skill: skill)
        let allowed = await source.allowedToolNames(for: session)
        XCTAssertNil(allowed)
        // Sabotage-evidence: M1 change "nil → no restriction" to "nil → []"
        // → returns Set() and assertion fails; M2 set allowedTools to []
        // in the skill init → assertion fails; M3 make `allowedToolNames`
        // always return Set() → assertion fails.
    }

    func test_allowedToolNames_noActiveSkill_returnsNil() async {
        let skill = Skill(
            name: "any",
            description: "any",
            allowedTools: ["read_file"],
            promptTemplate: "body",
            sourcePath: URL(fileURLWithPath: "/tmp/any/SKILL.md")
        )
        let registry = SkillRegistry()
        await registry.load([skill])
        let source = SkillToolSource(registry: registry)
        let session = ChatSession(id: UUID(), title: "no-active-skill")
        // Deliberately skip markActive — no skill is active for this session.
        let allowed = await source.allowedToolNames(for: session)
        XCTAssertNil(allowed)
        // Sabotage-evidence: M1 call `markActive` here → returns the
        // restricted set; M2 default the storage to a non-nil first skill
        // → assertion fails; M3 short-circuit the `guard let activeName`
        // to return Set() → assertion fails.
    }
}
