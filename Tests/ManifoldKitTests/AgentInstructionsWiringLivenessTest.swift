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
/// `ConversationRuntimeOptions.addAgentInstructions(currentDirectory:stoppingAt:)`
/// (`Sources/ManifoldKit/ConversationRuntimeOptions+AgentInstructions.swift`)
/// — against a real `AGENTS.md` on disk, through the real
/// `PromptContextPipeline.assemble(totalBudget:contextSize:context:)` — the
/// SAME three-arg overload `TurnPreparation.swift` calls on the live turn
/// path (`totalBudget: Int.max, contextSize: 0`, since `addAgentInstructions`
/// only ever populates `.pipeline`, never `.budgetPlanner`) — and asserts the
/// actual file content lands in the `.systemPreamble` slot. The two-arg
/// `assemble(messageCount:)` overload converges with this one only via
/// `PromptContextProvider`'s protocol-extension default, so calling it here
/// would not catch a future provider override of the budget-aware path. A
/// no-op wiring (empty pipeline, wrong slot position, or swallowed content)
/// cannot pass this.
final class AgentInstructionsWiringLivenessTest: XCTestCase {

    private var tempRoots: [URL] = []

    override func tearDownWithError() throws {
        // Best-effort cleanup — a temp dir another test already removed, or a
        // transient permission hiccup, must not fail an otherwise-passing
        // test. Matches the established convention elsewhere in the suite
        // (e.g. DownloadHygieneJanitorTests.tearDownWithError).
        let fm = FileManager.default
        for root in tempRoots {
            try? fm.removeItem(at: root)
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

    private func assembledSlots(_ options: ConversationRuntimeOptions) async throws -> [PromptSlot] {
        let pipeline = try XCTUnwrap(
            options.pipeline,
            "addAgentInstructions(...) must populate .pipeline — a nil pipeline is a silent no-op"
        )
        // Matches TurnPreparation.swift's live-turn call exactly: totalBudget
        // Int.max / contextSize 0 is what it passes when only `.pipeline` is
        // set (no `.budgetPlanner`) — the shape addAgentInstructions produces.
        let turnContext = TurnContext(sessionID: UUID(), messageCount: 0)
        return try await pipeline.assemble(totalBudget: Int.max, contextSize: 0, context: turnContext)
    }

    /// A real `AGENTS.md`, discovered, merged, and observably present in the
    /// assembled prompt's `.systemPreamble` slot — the exact shape #2434
    /// required for the extraction to count as live rather than merely wired.
    func test_addAgentInstructions_injectsRealFileContentIntoSystemPreamble() async throws {
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

        var options = ConversationRuntimeOptions()
        options.addAgentInstructions(currentDirectory: projectRoot, stoppingAt: projectRoot)
        let slots = try await assembledSlots(options)

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
    func test_addAgentInstructions_noFileOnDisk_producesNoSlots() async throws {
        #if !os(macOS)
        throw XCTSkip("AgentInstructionLoader.discover() is macOS-only in v1")
        #else
        let projectRoot = try makeTempDir()
        // Deliberately no AGENTS.md written here.

        var options = ConversationRuntimeOptions()
        options.addAgentInstructions(currentDirectory: projectRoot, stoppingAt: projectRoot)
        let slots = try await assembledSlots(options)

        XCTAssertTrue(slots.isEmpty, "no AGENTS.md on disk must yield zero slots")
        #endif
    }

    /// `addAgentInstructions` must ADD to a pipeline the host already
    /// configured, not silently discard it (#2434 review finding 9). A
    /// static factory returning a fresh `ConversationRuntimeOptions()` would
    /// drop both the host's other option fields and any provider already
    /// registered on `.pipeline`.
    func test_addAgentInstructions_preservesOtherOptionsAndComposesWithExistingPipeline() async throws {
        #if !os(macOS)
        throw XCTSkip("AgentInstructionLoader.discover() is macOS-only in v1")
        #else
        let projectRoot = try makeTempDir()
        try "AGENTS instructions.".write(
            to: projectRoot.appendingPathComponent("AGENTS.md"),
            atomically: true,
            encoding: .utf8
        )

        struct HostProvider: PromptContextProvider {
            func contributeSlots(messageCount: Int) async throws -> [PromptSlot] {
                [PromptSlot(id: "host-slot", content: "host content", position: .contextSetup, label: "host")]
            }
        }
        let hostHook = FirstMessageOnlyHook()

        var options = ConversationRuntimeOptions()
        options.pipeline = PromptContextPipeline(providers: [HostProvider()])
        options.generationHooks = [hostHook]
        options.addAgentInstructions(currentDirectory: projectRoot, stoppingAt: projectRoot)

        // The host's non-pipeline field must survive untouched.
        XCTAssertEqual(options.generationHooks.count, 1,
            "addAgentInstructions must not discard other ConversationRuntimeOptions fields set beforehand")

        // Both the host's own provider and AGENTS.md must contribute slots —
        // composed, not one replacing the other.
        let slots = try await assembledSlots(options)
        XCTAssertEqual(slots.count, 2,
            "addAgentInstructions must compose with an existing pipeline, not replace it")
        XCTAssertTrue(slots.contains { $0.id == "host-slot" },
            "the host's pre-existing provider must still contribute after addAgentInstructions")
        XCTAssertTrue(slots.contains { $0.content.contains("AGENTS instructions.") },
            "AGENTS.md must still contribute after composing with an existing pipeline")
        // Sabotage-evidence (verified locally, removed before commit):
        //   M1 revert to a static factory returning ConversationRuntimeOptions()
        //      → generationHooks.count becomes 0, first assertion fails.
        //   M2 have addAgentInstructions replace .pipeline outright instead of
        //      wrapping the existing one → slots.count becomes 1 and the
        //      host-slot assertion fails.
        #endif
    }

    private struct FirstMessageOnlyHook: GenerationHook {
        func postGeneration(_ turn: CompletedTurn) async {}
    }
}
