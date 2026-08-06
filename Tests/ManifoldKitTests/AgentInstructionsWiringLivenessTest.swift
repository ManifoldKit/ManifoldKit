import XCTest
import ManifoldKit

/// End-to-end liveness proof for the ManifoldAgentInstructions extraction
/// (#2434). `AgentInstructionContextProvider` sat on
/// `Tests/APIFreezeTests/inert-surface-allowlist.txt` under the old
/// `ManifoldSkills` module with the reason "host-consumed" — which was false:
/// nothing in `Sources/` ever constructed it. The extraction is conditioned on
/// fixing that, not carrying the same inert allowlist entry under a new module
/// name.
///
/// This test drives the real, documented recipe —
/// `ConversationRuntimeOptions.withAgentInstructions(currentDirectory:stoppingAt:)`
/// (`Sources/ManifoldKit/ConversationRuntimeOptions+AgentInstructions.swift`)
/// — against a real `AGENTS.md` on disk, through the real
/// `PromptContextPipeline.assemble(messageCount:)`, and asserts the actual
/// file content lands in the `.systemPreamble` slot. A no-op wiring (empty
/// pipeline, wrong slot position, or swallowed content) cannot pass this.
final class AgentInstructionsWiringLivenessTest: XCTestCase {

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

    private func makeTempDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-instructions-wiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoots.append(root)
        return root
    }

    /// A real `AGENTS.md`, discovered, merged, and observably present in the
    /// assembled prompt's `.systemPreamble` slot — the exact shape #2434
    /// required for the extraction to count as live rather than merely wired.
    func test_withAgentInstructions_injectsRealFileContentIntoSystemPreamble() async throws {
        #if !os(macOS)
        throw XCTSkip("AgentInstructionLoader.discover() is macOS-only in v1")
        #else
        let projectRoot = try makeTempDir()
        let marker = "MK-2434-LIVENESS-MARKER-\(UUID().uuidString)"
        let agentsMdContent = "# Project instructions\n\(marker): follow the house style."
        try agentsMdContent.write(
            to: projectRoot.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )

        let options = ConversationRuntimeOptions.withAgentInstructions(
            currentDirectory: projectRoot,
            stoppingAt: projectRoot
        )
        let pipeline = try XCTUnwrap(
            options.pipeline,
            "withAgentInstructions(...) must populate .pipeline — a nil pipeline is a silent no-op"
        )

        let slots = try await pipeline.assemble(messageCount: 0)

        XCTAssertEqual(slots.count, 1, "exactly one AGENTS.md on disk must produce exactly one slot")
        let slot = try XCTUnwrap(slots.first)
        XCTAssertEqual(slot.position, .systemPreamble,
            "AGENTS.md content must land in the system preamble, per AgentInstructionContextProvider's contract")
        XCTAssertTrue(slot.content.contains(marker),
            "assembled slot content must contain the real AGENTS.md file text, not a placeholder")
        XCTAssertEqual(slot.content, agentsMdContent,
            "single-file merge must round-trip the file content exactly")
        // Sabotage-evidence (verified locally, removed before commit):
        //   M1 remove the .contains(marker) assertion → passes vacuously even
        //      if the provider returns an unrelated hardcoded string.
        //   M2 swap `.systemPreamble` for `.contextSetup` → position check
        //      catches a provider wired to the wrong slot.
        //   M3 delete AGENTS.md before assemble() → count check below catches
        //      a provider that returns a slot anyway.
        #endif
    }

    /// Negative control: no `AGENTS.md` on disk must produce zero slots, not a
    /// slot with placeholder/empty content. Without this, a provider hardcoded
    /// to always emit one slot would pass the positive test above too.
    func test_withAgentInstructions_noFileOnDisk_producesNoSlots() async throws {
        #if !os(macOS)
        throw XCTSkip("AgentInstructionLoader.discover() is macOS-only in v1")
        #else
        let projectRoot = try makeTempDir()
        // Deliberately no AGENTS.md written here.

        let options = ConversationRuntimeOptions.withAgentInstructions(
            currentDirectory: projectRoot,
            stoppingAt: projectRoot
        )
        let pipeline = try XCTUnwrap(options.pipeline)
        let slots = try await pipeline.assemble(messageCount: 0)

        XCTAssertTrue(slots.isEmpty, "no AGENTS.md on disk must yield zero slots")
        #endif
    }
}
