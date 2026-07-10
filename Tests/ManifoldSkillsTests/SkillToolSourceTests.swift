import XCTest
import ManifoldInference
import ManifoldRuntime
import ManifoldContractTestSupport
@testable import ManifoldSkills

final class SkillToolSourceTests: XCTestCase, SessionToolSourceContract {

    // MARK: SessionToolSourceContract

    func makeSource() -> any SessionToolSource {
        // Contract assertions don't require a non-empty advertised list;
        // an empty registry exercises the `toolDefinitions == []` path
        // (stable across calls) and the unknown-tool throw path. Skill-
        // population tests below construct their own registries directly.
        SkillToolSource(registry: SkillRegistry())
    }

    // MARK: Contract adoption

    func test_contract_toolDefinitionsStableAcrossCalls() async {
        await assertSessionToolSource_toolDefinitions_stableAcrossCalls()
    }

    func test_contract_resolveUnknownToolThrows() async {
        await assertSessionToolSource_resolve_unknownTool_throws()
    }

    /// Overrides the default-nil contract assertion intentionally: this
    /// source DOES restrict the advertised list when a skill is active.
    /// The default-nil assertion only applies when no skill is active.
    func test_contract_allowedToolNamesNilWhenNoSkillActive() async {
        await assertSessionToolSource_allowedToolNames_defaultsToNil()
    }

    // MARK: Dispatcher shape

    func test_toolDefinitions_capsAtSix_whenMoreSkillsRegistered() async {
        let registry = SkillRegistry()
        let many = (0..<8).map {
            SkillDefinition(
                name: String(format: "skill-%02d", $0),
                description: "d",
                promptTemplate: "body",
                sourcePath: URL(fileURLWithPath: "/tmp/x/SKILL.md")
            )
        }
        await registry.load(many)
        let source = SkillToolSource(registry: registry)
        let defs = await source.toolDefinitions(for: makeSession())
        XCTAssertEqual(defs.count, 1)
        guard case .object(let params)? = defs.first?.parameters,
              case .object(let props)? = params["properties"],
              case .object(let nameSchema)? = props["skill_name"],
              case .array(let enumValues)? = nameSchema["enum"]
        else {
            return XCTFail("Expected JSON Schema enum on skill_name")
        }
        XCTAssertEqual(enumValues.count, SkillToolSource.maxAdvertisedSkills)
        // First six alphabetical names ("skill-00" .. "skill-05").
        let names = enumValues.compactMap { value -> String? in
            if case .string(let s) = value { return s }
            return nil
        }
        XCTAssertEqual(names, (0..<6).map { String(format: "skill-%02d", $0) })
        // Sabotage-evidence: M1 raise `maxAdvertisedSkills` to 10 → count
        // becomes 8 (no warning); M2 sort skills reverse → assertion on
        // first-six-alphabetical fails; M3 drop the cap entirely — count
        // is 8 and equality fails.
    }

    func test_toolDefinitions_emptyRegistry_returnsNoDefinitions() async {
        let source = SkillToolSource(registry: SkillRegistry())
        let defs = await source.toolDefinitions(for: makeSession())
        XCTAssertEqual(defs, [])
        // Sabotage-evidence: M1 always emit a placeholder tool → assert
        // fails; M2 register a skill before calling → 1 definition; M3
        // make the function throw — would surface in compile, not at
        // runtime (so build break, not assertion).
    }

    func test_resolve_unknownInvokeSkillName_throws() async {
        let source = SkillToolSource(registry: SkillRegistry())
        do {
            _ = try await source.resolve(
                toolName: SkillToolSource.invokeSkillToolName,
                arguments: #"{"skill_name": "ghost"}"#,
                session: makeSession()
            )
            XCTFail("Expected throw")
        } catch let error as SkillDispatchError {
            XCTAssertEqual(error, .unknownSkill("ghost"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        // Sabotage-evidence: M1 seed a skill named "ghost" → no throw;
        // M2 change the dispatched name to a real skill — no throw;
        // M3 make `resolve` swallow unknown-skill → catch-all hits and
        // assertion fires.
    }

    func test_resolve_validSkill_returnsPromptTemplate() async throws {
        let registry = SkillRegistry()
        let skill = SkillDefinition(
            name: "explain",
            description: "Explain a snippet",
            promptTemplate: "Please explain the snippet thoroughly.",
            sourcePath: URL(fileURLWithPath: "/tmp/explain/SKILL.md")
        )
        await registry.load([skill])
        let source = SkillToolSource(registry: registry)
        let result = try await source.resolve(
            toolName: SkillToolSource.invokeSkillToolName,
            arguments: #"{"skill_name": "explain", "args": "func foo()"}"#,
            session: makeSession()
        )
        XCTAssertTrue(result.content.contains("Please explain the snippet thoroughly."))
        XCTAssertTrue(result.content.contains("func foo()"))
        XCTAssertNil(result.errorKind)
        // Sabotage-evidence: M1 strip the body interpolation in
        // `resolve` → template snippet missing; M2 swap to a different
        // skill — assertion fails; M3 mark result errored — `errorKind`
        // becomes non-nil.
    }

    func test_resolve_setsActiveSkill_observableViaAllowedToolNames() async throws {
        let registry = SkillRegistry()
        let skill = SkillDefinition(
            name: "narrow",
            description: "narrow scope",
            allowedTools: ["read_file"],
            promptTemplate: "narrow body",
            sourcePath: URL(fileURLWithPath: "/tmp/narrow/SKILL.md")
        )
        await registry.load([skill])
        let source = SkillToolSource(registry: registry)
        let session = makeSession()

        // Before resolve: no restriction.
        let preAllowed = await source.allowedToolNames(for: session)
        XCTAssertNil(preAllowed)

        _ = try await source.resolve(
            toolName: SkillToolSource.invokeSkillToolName,
            arguments: #"{"skill_name": "narrow"}"#,
            session: session
        )

        let postAllowed = await source.allowedToolNames(for: session)
        XCTAssertEqual(postAllowed, Set(["read_file"]))
        // Sabotage-evidence: M1 remove the `setActive` call from `resolve` →
        // postAllowed stays nil; M2 swap to a skill without `allowed-tools` →
        // postAllowed becomes nil; M3 set the wrong session id in the
        // closure — postAllowed stays nil.
    }
}
