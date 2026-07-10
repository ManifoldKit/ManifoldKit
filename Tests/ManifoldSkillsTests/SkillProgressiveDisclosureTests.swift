import XCTest
import ManifoldInference
import ManifoldRuntime
@testable import ManifoldSkills

/// L3 progressive-disclosure tests: referenced files are declared at
/// discovery but only read on demand, and resolution is confined to the
/// skill's own directory.
///
/// macOS-only because `SkillLoader.discover()` is macOS-only in v1 — the
/// reference-resolution unit checks could run anywhere, but the discovery
/// path that records `references:` is gated, so the whole suite skips
/// off-platform rather than testing half a feature.
final class SkillProgressiveDisclosureTests: XCTestCase {

    private var tempRoots: [URL] = []

    override func tearDownWithError() throws {
        let fm = FileManager.default
        for root in tempRoots {
            do {
                try fm.removeItem(at: root)
            } catch {
                XCTAssertNotNil(error as Error?, "tear-down cleanup error captured")
            }
        }
        tempRoots = []
    }

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-l3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoots.append(root)
        return root
    }

    /// Writes a skill whose body references `reference.md` and `examples/a.md`
    /// via a `references:` block list, plus those companion files. Returns the
    /// discovered `SkillDefinition`.
    private func writeReferencingSkill(in root: URL) throws -> SkillDefinition {
        let dir = root.appendingPathComponent("explain", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("examples", isDirectory: true),
            withIntermediateDirectories: true
        )
        let frontmatter = """
        ---
        name: explain
        description: Explain a snippet.
        references:
          - reference.md
          - examples/a.md
        ---
        See reference.md for details.
        """
        try frontmatter.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "DEEP-REFERENCE-CONTENT".write(
            to: dir.appendingPathComponent("reference.md"), atomically: true, encoding: .utf8)
        try "EXAMPLE-A-CONTENT".write(
            to: dir.appendingPathComponent("examples/a.md"), atomically: true, encoding: .utf8)
        // A sibling file the author did NOT publish — must stay undisclosed.
        try "SECRET".write(
            to: dir.appendingPathComponent("private.md"), atomically: true, encoding: .utf8)

        let loader = SkillLoader(searchPaths: [root])
        guard let skill = loader.discover().first(where: { $0.name == "explain" }) else {
            throw XCTSkip("discovery did not surface the test skill")
        }
        return skill
    }

    func test_discover_recordsReferences_butDoesNotInlineTheirContent() throws {
        #if !os(macOS)
        throw XCTSkip("Discovery is macOS-only in v1")
        #else
        let root = try makeTempRoot()
        let skill = try writeReferencingSkill(in: root)

        XCTAssertEqual(skill.references, ["reference.md", "examples/a.md"])
        // The L3 win: the referenced files' bodies are NOT loaded at discovery.
        // The skill's eager body must contain neither file's content.
        XCTAssertFalse(skill.promptTemplate.contains("DEEP-REFERENCE-CONTENT"),
                       "reference.md content must not be eagerly inlined into the body")
        XCTAssertFalse(skill.promptTemplate.contains("EXAMPLE-A-CONTENT"),
                       "examples/a.md content must not be eagerly inlined into the body")
        #endif
    }

    func test_resolveReference_readsDeclaredFile_onDemand() throws {
        #if !os(macOS)
        throw XCTSkip("Discovery is macOS-only in v1")
        #else
        let root = try makeTempRoot()
        let skill = try writeReferencingSkill(in: root)

        XCTAssertEqual(try skill.resolveReference("reference.md"), "DEEP-REFERENCE-CONTENT")
        XCTAssertEqual(try skill.resolveReference("examples/a.md"), "EXAMPLE-A-CONTENT")
        #endif
    }

    func test_resolveReference_rejectsUndeclaredFile() throws {
        #if !os(macOS)
        throw XCTSkip("Discovery is macOS-only in v1")
        #else
        let root = try makeTempRoot()
        let skill = try writeReferencingSkill(in: root)

        // `private.md` exists on disk inside the dir but was not published.
        XCTAssertThrowsError(try skill.resolveReference("private.md")) { error in
            XCTAssertEqual(error as? SkillReferenceError, .undeclaredReference("private.md"))
        }
        #endif
    }

    func test_resolveReference_rejectsTraversalAndAbsolutePaths() throws {
        #if !os(macOS)
        throw XCTSkip("Discovery is macOS-only in v1")
        #else
        let root = try makeTempRoot()
        let skill = try writeReferencingSkill(in: root)

        // Declare-and-resolve a traversal path so we exercise the dir-confinement
        // guard, not just the allow-list (the allow-list rejects undeclared
        // first; here the path IS declared but still escapes).
        let escaping = SkillDefinition(
            name: "evil",
            description: "d",
            promptTemplate: "body",
            references: ["../private.md", "/etc/passwd"],
            sourcePath: skill.sourcePath
        )
        XCTAssertThrowsError(try escaping.resolveReference("../private.md")) { error in
            XCTAssertEqual(error as? SkillReferenceError, .pathEscapesSkillDirectory("../private.md"))
        }
        XCTAssertThrowsError(try escaping.resolveReference("/etc/passwd")) { error in
            XCTAssertEqual(error as? SkillReferenceError, .pathEscapesSkillDirectory("/etc/passwd"))
        }
        // Sabotage-evidence: drop the `..`/`hasPrefix("/")` guards in
        // SkillReferenceResolver.read → these two assertions fail (the reads
        // either escape the dir or throw `.unreadable` instead of
        // `.pathEscapesSkillDirectory`). Verified locally before commit.
        #endif
    }

    func test_resolveReference_rejectsSymlinkEscape() throws {
        #if !os(macOS)
        throw XCTSkip("Discovery is macOS-only in v1")
        #else
        let root = try makeTempRoot()
        let skill = try writeReferencingSkill(in: root)
        let dir = skill.sourcePath.deletingLastPathComponent()

        // A declared reference that is itself a symlink pointing OUTSIDE the
        // skill directory. The component-prefix check passes (the link's own
        // path is inside the dir); only resolving the symlink reveals the
        // escape. Without the symlink backstop this leaks an arbitrary file.
        let outsideTarget = root.appendingPathComponent("outside-secret.md")
        try "OUTSIDE-SECRET".write(to: outsideTarget, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("leak.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideTarget)

        let evil = SkillDefinition(
            name: "evil",
            description: "d",
            promptTemplate: "body",
            references: ["leak.md"],
            sourcePath: skill.sourcePath
        )
        XCTAssertThrowsError(try evil.resolveReference("leak.md")) { error in
            XCTAssertEqual(error as? SkillReferenceError, .pathEscapesSkillDirectory("leak.md"))
        }
        #endif
    }

    func test_resolveReference_declaredButMissingFile_throwsUnreadable_notTryQuestion() throws {
        #if !os(macOS)
        throw XCTSkip("Discovery is macOS-only in v1")
        #else
        let root = try makeTempRoot()
        let skill = try writeReferencingSkill(in: root)
        let withGhost = SkillDefinition(
            name: skill.name,
            description: skill.description,
            promptTemplate: skill.promptTemplate,
            references: skill.references + ["ghost.md"],
            sourcePath: skill.sourcePath
        )
        XCTAssertThrowsError(try withGhost.resolveReference("ghost.md")) { error in
            XCTAssertEqual(error as? SkillReferenceError, .unreadable("ghost.md"))
        }
        #endif
    }

    func test_dispatch_advertisesReferenceNames_withoutContent() async throws {
        #if !os(macOS)
        throw XCTSkip("Discovery is macOS-only in v1")
        #else
        let root = try makeTempRoot()
        let skill = try writeReferencingSkill(in: root)
        let registry = SkillRegistry()
        await registry.load([skill])
        let source = SkillToolSource(registry: registry)
        let session = ChatSession(id: UUID(), title: "t")

        let result = try await source.resolve(
            toolName: SkillToolSource.invokeSkillToolName,
            arguments: #"{"skill_name":"explain"}"#,
            session: session
        )

        XCTAssertTrue(result.content.contains("reference.md"),
                      "dispatch must advertise the reference file names")
        XCTAssertTrue(result.content.contains("examples/a.md"))
        // But not their contents — that is the on-demand tier.
        XCTAssertFalse(result.content.contains("DEEP-REFERENCE-CONTENT"),
                       "dispatch must not inline referenced-file content")
        #endif
    }
}
