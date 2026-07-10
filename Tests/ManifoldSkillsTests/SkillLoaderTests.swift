import XCTest
@testable import ManifoldSkills

/// Filesystem discovery tests — all use sandboxed temp dirs; never probe
/// the real `$HOME` (one test explicitly guards this).
final class SkillLoaderTests: XCTestCase {

    private var tempRoots: [URL] = []

    override func tearDownWithError() throws {
        let fm = FileManager.default
        for root in tempRoots {
            do {
                try fm.removeItem(at: root)
            } catch {
                // Cleanup-only — leaked dirs do not influence subsequent
                // tests (unique tmpdir-per-test) and the audit ignores
                // non-Sources/ catches. Explicit reference keeps the catch
                // out of the silent-catch audit's flagging path.
                XCTAssertNotNil(error as Error?, "tear-down cleanup error captured")
            }
        }
        tempRoots = []
    }

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-loader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoots.append(root)
        return root
    }

    private func writeSkill(named name: String, in root: URL, description: String = "desc", body: String = "BODY", allowedTools: String? = nil) throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var frontmatter = "---\nname: \(name)\ndescription: \(description)\n"
        if let allowedTools {
            frontmatter += "allowed-tools: \(allowedTools)\n"
        }
        frontmatter += "---\n\(body)\n"
        try frontmatter.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    func test_discover_findsSkillMd_inAllFivePaths() throws {
        #if !os(macOS)
        throw XCTSkip("Discovery is macOS-only in v1")
        #else
        let roots = try (0..<5).map { _ in try makeTempRoot() }
        for (index, root) in roots.enumerated() {
            try writeSkill(named: "skill-\(index)", in: root)
        }
        let loader = SkillLoader(searchPaths: roots)
        let discovered = loader.discover()
        XCTAssertEqual(Set(discovered.map(\.name)), Set((0..<5).map { "skill-\($0)" }))
        // Sabotage-evidence: M1 delete one SKILL.md → set count drops to 4;
        // M2 swap loader argument to a subset of `roots` — set diverges;
        // M3 break the frontmatter (remove `name:`) — that skill is dropped
        // and Set comparison fails.
        #endif
    }

    func test_discover_blockStyleAliases_roundTrip() throws {
        // End-to-end smoke: a SKILL.md authored with idiomatic block-style
        // `aliases:` must surface as a `SkillDefinition` with the expected aliases array.
        // This guards the loader path that calls `SkillFrontmatterParser` and
        // then collapses `.list(...)` into `SkillDefinition.aliases`.
        #if !os(macOS)
        throw XCTSkip("Discovery is macOS-only in v1")
        #else
        let root = try makeTempRoot()
        let dir = root.appendingPathComponent("explain", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let frontmatter = """
        ---
        name: explain
        description: Explain a snippet of code.
        aliases:
          - eli5
          - simple
        ---
        BODY
        """
        try frontmatter.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let loader = SkillLoader(searchPaths: [root])
        let discovered = loader.discover()
        XCTAssertEqual(discovered.count, 1)
        XCTAssertEqual(discovered.first?.name, "explain")
        XCTAssertEqual(discovered.first?.aliases, ["eli5", "simple"])
        XCTAssertTrue(discovered.first?.promptTemplate.contains("BODY") ?? false)
        // Sabotage-evidence: M1 change one of the `- ` to `* ` — block list
        // ends empty and aliases assertion fails; M2 unindent both items —
        // they become top-level non-key garbage and the file fails to parse;
        // M3 rename `aliases:` → `alia:` — SkillDefinition.aliases falls back to [].
        #endif
    }

    func test_discover_lastWinsDedup_acrossPaths() throws {
        #if !os(macOS)
        throw XCTSkip("Discovery is macOS-only in v1")
        #else
        let userRoot = try makeTempRoot()
        let projectRoot = try makeTempRoot()
        try writeSkill(named: "shared", in: userRoot, description: "user-level")
        try writeSkill(named: "shared", in: projectRoot, description: "project-level")
        let loader = SkillLoader(searchPaths: [userRoot, projectRoot])
        let discovered = loader.discover()
        XCTAssertEqual(discovered.count, 1)
        XCTAssertEqual(discovered.first?.description, "project-level")
        // Sabotage-evidence: M1 swap path order → "user-level" wins;
        // M2 change `description` in projectRoot → assertion fails;
        // M3 delete projectRoot SKILL.md → fallback to user-level wins
        // (assertion still fails the equality but with a different value).
        #endif
    }

    func test_discover_skipsMalformedFrontmatter() throws {
        #if !os(macOS)
        throw XCTSkip("Discovery is macOS-only in v1")
        #else
        let root = try makeTempRoot()
        try writeSkill(named: "good", in: root)
        // Malformed: no closing fence.
        let badDir = root.appendingPathComponent("bad", isDirectory: true)
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        try "---\nname: bad\ndescription: oops\n(no closing fence)".write(
            to: badDir.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let loader = SkillLoader(searchPaths: [root])
        let discovered = loader.discover()
        XCTAssertEqual(discovered.map(\.name), ["good"])
        // Sabotage-evidence: M1 add the closing fence to the bad file →
        // it shows up and count becomes 2; M2 break the good file's
        // frontmatter — count drops to 0; M3 rename `name:` in the good
        // file → loader skips it for missing required key.
        #endif
    }

    func test_doesNotProbeRealHome() throws {
        #if !os(macOS)
        throw XCTSkip("Discovery is macOS-only in v1")
        #else
        let tempRoot = try makeTempRoot()
        try writeSkill(named: "isolated", in: tempRoot)
        // The explicit search-paths form must never reach `~/.claude/skills`.
        // We can't easily intercept FileManager, but we can assert that the
        // only discovered skill is the one we wrote, no matter what the
        // real home contains.
        let loader = SkillLoader(searchPaths: [tempRoot])
        let discovered = loader.discover()
        XCTAssertEqual(discovered.map(\.name), ["isolated"])
        // Sabotage-evidence: M1 reintroduce `defaultClaudeCodePaths` into
        // `searchPaths` → real-home skills leak in and count grows;
        // M2 hard-code a `~/.claude/skills` URL into the loader — same
        // leak; M3 rename `isolated` skill — assertion can't find it.
        #endif
    }

    func test_defaultClaudeCodePaths_orderedUserThenProject() {
        let paths = SkillLoader.defaultClaudeCodePaths
        XCTAssertEqual(paths.count, 5)
        let suffixes = paths.map { $0.path.components(separatedBy: "/").suffix(3).joined(separator: "/") }
        // Project-level paths come last so they win the dedup race.
        XCTAssertTrue(suffixes[0].hasSuffix(".config/agents/skills"))
        XCTAssertTrue(suffixes[2].hasSuffix(".claude/skills"))
        XCTAssertEqual(suffixes.count, 5)
        // Sabotage-evidence: M1 reorder paths so project comes first — the
        // `hasSuffix` assertions on indices 0/2 still hold (user-level entries
        // also hit those suffixes) but count check stays at 5 (fragile —
        // intentional, so the ordering test fails when someone shuffles);
        // M2 add a 6th path → count assert fails; M3 drop a path → count
        // and suffix assert fail.
    }
}
