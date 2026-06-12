import XCTest
@testable import ManifoldSkills

final class SkillRegistryTests: XCTestCase {

    private func make(_ name: String, aliases: [String] = []) -> Skill {
        Skill(
            name: name,
            description: name,
            aliases: aliases,
            promptTemplate: "body",
            sourcePath: URL(fileURLWithPath: "/tmp/\(name)/SKILL.md")
        )
    }

    func test_load_lastWinsOnName() async {
        let registry = SkillRegistry()
        let a1 = make("foo")
        let a2 = Skill(
            name: "foo",
            description: "newer",
            promptTemplate: "BODY-2",
            sourcePath: URL(fileURLWithPath: "/tmp/foo2/SKILL.md")
        )
        await registry.load([a1])
        await registry.load([a2])

        let resolved = await registry.skill(named: "foo")
        XCTAssertEqual(resolved?.description, "newer")
        let all = await registry.all()
        XCTAssertEqual(all.count, 1)
        // Sabotage-evidence: M1 register `a1` last → description becomes
        // its name "foo"; M2 drop the second `load` call → "newer" never
        // wins; M3 add a third skill with a different name → all().count
        // becomes 2.
    }

    func test_load_aliasResolution() async {
        let registry = SkillRegistry()
        await registry.load([make("explain", aliases: ["walk-through", "wt"])])

        let viaName = await registry.skill(named: "explain")
        let viaAlias1 = await registry.skill(named: "walk-through")
        let viaAlias2 = await registry.skill(named: "wt")

        XCTAssertEqual(viaName?.name, "explain")
        XCTAssertEqual(viaAlias1?.name, "explain")
        XCTAssertEqual(viaAlias2?.name, "explain")
        // Sabotage-evidence: M1 drop one alias from the load list → that
        // lookup returns nil; M2 register a different skill with the same
        // alias → alias points to the later skill; M3 typo the lookup
        // string → returns nil and assertion fails.
    }

    func test_load_unknownName_returnsNil() async {
        let registry = SkillRegistry()
        let result = await registry.skill(named: "ghost")
        XCTAssertNil(result)
        // Sabotage-evidence: M1 load a skill named "ghost" → assertion
        // fails (no longer nil); M2 change lookup to "" → still nil but
        // for a different reason; M3 stub `skill(named:)` to always return
        // a placeholder → assertion fails.
    }
}
