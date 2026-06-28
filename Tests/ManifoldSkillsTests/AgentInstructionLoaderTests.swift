import XCTest
@testable import ManifoldSkills

/// Tests for `AgentInstructionLoader` filesystem discovery and merging.
///
/// All tests use sandboxed temp dirs; never probe the real `$HOME`.
final class AgentInstructionLoaderTests: XCTestCase {

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

    private func makeTempDir(named label: String = UUID().uuidString) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agents-loader-\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoots.append(root)
        return root
    }

    private func writeAgentsMd(content: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(AgentInstructionLoader.defaultFileName)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Discovery

    func test_discover_findsAgentsMd_inCurrentDirectory() throws {
        #if !os(macOS)
        throw XCTSkip("AgentInstructionLoader.discover() is macOS-only in v1")
        #else
        let cwd = try makeTempDir()
        try writeAgentsMd(content: "# Project instructions\nDo the thing.", in: cwd)

        let loader = AgentInstructionLoader()
        let found = loader.discover(from: cwd, stoppingAt: cwd)

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.directory.standardizedFileURL, cwd.standardizedFileURL)
        XCTAssertTrue(found.first?.content.contains("Do the thing.") ?? false)
        // Sabotage-evidence: M1 rename the file to AGENTS.txt → count drops to 0;
        // M2 remove the `content.contains` check body → passes vacuously;
        // M3 change stoppingAt to a non-matching dir → count could grow.
        #endif
    }

    func test_discover_findsAgentsMd_inParentDirectory() throws {
        #if !os(macOS)
        throw XCTSkip("AgentInstructionLoader.discover() is macOS-only in v1")
        #else
        let root = try makeTempDir()
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try writeAgentsMd(content: "Root instructions.", in: root)
        // No AGENTS.md in `sub`.

        let loader = AgentInstructionLoader()
        let found = loader.discover(from: sub, stoppingAt: root)

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.directory.standardizedFileURL, root.standardizedFileURL)
        // Sabotage-evidence: M1 add AGENTS.md to `sub` → count becomes 2;
        // M2 swap stoppingAt to `sub` → root's file is outside the walk, count 0;
        // M3 remove the root AGENTS.md → count drops to 0.
        #endif
    }

    func test_discover_rootToLeafOrdering() throws {
        #if !os(macOS)
        throw XCTSkip("AgentInstructionLoader.discover() is macOS-only in v1")
        #else
        let root = try makeTempDir()
        let mid = root.appendingPathComponent("mid", isDirectory: true)
        let leaf = mid.appendingPathComponent("leaf", isDirectory: true)
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        try writeAgentsMd(content: "ROOT", in: root)
        try writeAgentsMd(content: "MID", in: mid)
        try writeAgentsMd(content: "LEAF", in: leaf)

        let loader = AgentInstructionLoader()
        let found = loader.discover(from: leaf, stoppingAt: root)

        XCTAssertEqual(found.count, 3)
        XCTAssertEqual(found.map(\.content), ["ROOT", "MID", "LEAF"])
        // Sabotage-evidence: M1 swap root ↔ leaf in the returned order →
        // the map equality fails ("LEAF", "MID", "ROOT" ≠ expected);
        // M2 remove `mid` AGENTS.md → count becomes 2, map fails;
        // M3 flip stoppingAt to `mid` → root is excluded, count becomes 2.
        #endif
    }

    func test_discover_stopsAtStopDirectory_excludesAbove() throws {
        #if !os(macOS)
        throw XCTSkip("AgentInstructionLoader.discover() is macOS-only in v1")
        #else
        let grandparent = try makeTempDir()
        let parent = grandparent.appendingPathComponent("parent", isDirectory: true)
        let child = parent.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try writeAgentsMd(content: "Grandparent — should be excluded.", in: grandparent)
        try writeAgentsMd(content: "Parent — is the stop.", in: parent)
        try writeAgentsMd(content: "Child — should be included.", in: child)

        let loader = AgentInstructionLoader()
        let found = loader.discover(from: child, stoppingAt: parent)

        XCTAssertEqual(found.count, 2)
        XCTAssertFalse(found.contains { $0.content.contains("Grandparent") })
        XCTAssertTrue(found.contains { $0.content.contains("Parent") })
        XCTAssertTrue(found.contains { $0.content.contains("Child") })
        // Sabotage-evidence: M1 change stoppingAt to `grandparent` → count
        // becomes 3 and the Grandparent exclusion check fails;
        // M2 remove grandparent AGENTS.md → count stays 2 but the first
        // assertion masks stoppingAt bugs — test remains valid.
        #endif
    }

    func test_discover_skipsEmptyAgentsMd() throws {
        #if !os(macOS)
        throw XCTSkip("AgentInstructionLoader.discover() is macOS-only in v1")
        #else
        let root = try makeTempDir()
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try writeAgentsMd(content: "   \n\n  \t  \n", in: root)   // whitespace-only
        try writeAgentsMd(content: "# Real instructions", in: sub)

        let loader = AgentInstructionLoader()
        let found = loader.discover(from: sub, stoppingAt: root)

        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found.first?.content.contains("Real instructions") ?? false)
        // Sabotage-evidence: M1 add non-whitespace to root's file → count
        // becomes 2; M2 remove the whitespace-trim in the loader → root
        // included, count 2.
        #endif
    }

    func test_discover_noAgentsMd_returnsEmpty() throws {
        #if !os(macOS)
        throw XCTSkip("AgentInstructionLoader.discover() is macOS-only in v1")
        #else
        let cwd = try makeTempDir()

        let loader = AgentInstructionLoader()
        let found = loader.discover(from: cwd, stoppingAt: cwd)

        XCTAssertTrue(found.isEmpty)
        // Sabotage-evidence: M1 add AGENTS.md to cwd → count becomes 1;
        // M2 flip the isEmpty check to !isEmpty → assertion inverts.
        #endif
    }

    func test_discover_currentDirectoryAboveStop_returnsEmpty() throws {
        #if !os(macOS)
        throw XCTSkip("AgentInstructionLoader.discover() is macOS-only in v1")
        #else
        let root = try makeTempDir()
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try writeAgentsMd(content: "Root instructions.", in: root)
        // currentDirectory is root, stopDirectory is sub → root is ABOVE sub.
        // The loader must return empty and warn rather than silently walking
        // all the way to the filesystem root.
        let loader = AgentInstructionLoader()
        let found = loader.discover(from: root, stoppingAt: sub)

        XCTAssertTrue(found.isEmpty)
        // Sabotage-evidence: M1 remove the inversion guard → loader walks
        // root → / and may pick up AGENTS.md files along the way, making
        // found non-empty; M2 fix the guard to only warn without returning
        // early → found would contain root's file.
        #endif
    }

    // MARK: - Merging

    func test_merged_returnsNilForEmptyInput() {
        let loader = AgentInstructionLoader()
        XCTAssertNil(loader.merged([]))
        // Sabotage-evidence: M1 return "" instead of nil → nil check fails.
    }

    func test_merged_singleInstruction_returnsItsContent() throws {
        let url = URL(fileURLWithPath: "/fake/dir")
        let instruction = AgentInstruction(directory: url, content: "Hello.")
        let loader = AgentInstructionLoader()

        let result = loader.merged([instruction])
        XCTAssertEqual(result, "Hello.")
        // Sabotage-evidence: M1 wrap in extra "\n" → equality fails;
        // M2 join with "---" unconditionally → single-item gets separator.
    }

    func test_merged_multipleInstructions_separatedByRule() throws {
        let url = URL(fileURLWithPath: "/fake/dir")
        let instructions = [
            AgentInstruction(directory: url, content: "A"),
            AgentInstruction(directory: url, content: "B"),
            AgentInstruction(directory: url, content: "C"),
        ]
        let loader = AgentInstructionLoader()

        let result = loader.merged(instructions)
        XCTAssertEqual(result, "A\n\n---\n\nB\n\n---\n\nC")
        // Sabotage-evidence: M1 change separator to "\n---\n" → equality fails;
        // M2 use "," as separator → equality fails.
    }

    // MARK: - ContextProvider

    func test_contextProvider_returnsEmptySlots_whenNoAgentsMd() async throws {
        #if !os(macOS)
        throw XCTSkip("AgentInstructionLoader.discover() is macOS-only in v1")
        #else
        let cwd = try makeTempDir()
        let provider = AgentInstructionContextProvider(
            currentDirectory: cwd,
            stoppingAt: cwd
        )

        let slots = try await provider.contributeSlots(messageCount: 0)
        XCTAssertTrue(slots.isEmpty)
        // Sabotage-evidence: M1 add AGENTS.md → slots count becomes 1.
        #endif
    }

    func test_contextProvider_injectsSystemPreambleSlot() async throws {
        #if !os(macOS)
        throw XCTSkip("AgentInstructionLoader.discover() is macOS-only in v1")
        #else
        let cwd = try makeTempDir()
        try writeAgentsMd(content: "Be helpful.", in: cwd)
        let provider = AgentInstructionContextProvider(
            currentDirectory: cwd,
            stoppingAt: cwd
        )

        let slots = try await provider.contributeSlots(messageCount: 0)
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots.first?.id, "agents-md-ambient")
        XCTAssertEqual(slots.first?.position, .systemPreamble)
        XCTAssertTrue(slots.first?.content.contains("Be helpful.") ?? false)
        // Sabotage-evidence: M1 change position to .contextSetup → position
        // check fails; M2 change id → id check fails; M3 remove content →
        // content check fails.
        #endif
    }
}
