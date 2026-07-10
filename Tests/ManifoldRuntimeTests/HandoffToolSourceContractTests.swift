import XCTest
import ManifoldInference
import ManifoldRuntime
import ManifoldContractTestSupport

/// Exercises ``HandoffToolSource`` against the shared
/// ``SessionToolSourceContract`` mixin plus the W2B-specific shape
/// requirements (synth-tools list, active-agent exclusion, soft cap).
final class HandoffToolSourceContractTests: XCTestCase, SessionToolSourceContract {

    // MARK: - Contract adoption

    func makeSource() -> any SessionToolSource {
        HandoffToolSource()
    }

    /// `makeSession()` overrides the default no-agents fixture so the
    /// contract's stableAcrossCalls assertion runs against a session that
    /// actually produces a non-empty advertised list.
    func makeSession() -> ChatSession {
        let researcher = AgentDefinition(name: "Researcher", systemPrompt: "P1", description: "D1")
        let writer = AgentDefinition(name: "Writer", systemPrompt: "P2", description: "D2")
        return ChatSession(
            id: UUID(),
            title: "Contract fixture",
            agents: [researcher, writer],
            activeAgentID: researcher.id
        )
    }

    // Sabotage-evidence:
    // M1: have toolDefinitions return a randomized copy on each call.
    // M2: have toolDefinitions cache by reference rather than session content.
    // M3: have toolDefinitions return [] on the second call.
    func test_toolDefinitions_stableAcrossCalls() async {
        await assertSessionToolSource_toolDefinitions_stableAcrossCalls()
    }

    // Sabotage-evidence:
    // M1: have resolve return a synthesised ToolResult for transfer_to_*.
    // M2: have resolve swallow the unknown name and succeed.
    // M3: have resolve return a failing ToolResult instead of throwing.
    func test_resolve_unknownTool_throws() async {
        await assertSessionToolSource_resolve_unknownTool_throws()
    }

    // Sabotage-evidence:
    // M1: override allowedToolNames to return Set(["transfer_to_Writer"]).
    // M2: override allowedToolNames to return [].
    // M3: remove the protocol default-impl from SessionToolSource entirely.
    func test_allowedToolNames_defaultsToNil() async {
        await assertSessionToolSource_allowedToolNames_defaultsToNil()
    }

    // MARK: - Synthesis shape

    func test_toolDefinitions_synthesizesTransferTools_excludingActiveAgent() async {
        let researcher = AgentDefinition(name: "Researcher", systemPrompt: "", description: "")
        let writer = AgentDefinition(name: "Writer", systemPrompt: "", description: "")
        let critic = AgentDefinition(name: "Critic", systemPrompt: "", description: "")
        let session = ChatSession(
            id: UUID(),
            title: "T",
            agents: [researcher, writer, critic],
            activeAgentID: researcher.id
        )

        let source = HandoffToolSource()
        let defs = await source.toolDefinitions(for: session)

        let names = defs.map(\.name).sorted()
        XCTAssertEqual(names, ["transfer_to_Critic", "transfer_to_Writer"])
        // Sabotage-evidence: M1 drop active-agent filter → "transfer_to_Researcher" appears.
        // Sabotage-evidence: M2 return only first agent → list has one entry.
        // Sabotage-evidence: M3 swap prefix → assertion fails.
    }

    func test_toolDefinitions_emptyWhenSingleAgent() async {
        let solo = AgentDefinition(name: "Solo", systemPrompt: "", description: "")
        let session = ChatSession(
            id: UUID(),
            title: "Solo",
            agents: [solo],
            activeAgentID: solo.id
        )
        let source = HandoffToolSource()
        let defs = await source.toolDefinitions(for: session)
        XCTAssertTrue(defs.isEmpty)
        // Sabotage-evidence: M1 unconditional synthesis → [transfer_to_Solo] returned.
        // Sabotage-evidence: M2 inverted active filter → self-transfer appears.
        // Sabotage-evidence: M3 default-construct one tool → defs.count==1.
    }

    func test_toolDefinitions_warnsOver4Agents_butStillReturns() async {
        // The soft cap is informational — the source must still return
        // every non-active agent's transfer tool so handoff isn't silently
        // truncated mid-conversation.
        let active = AgentDefinition(name: "A", systemPrompt: "", description: "")
        let agents: [AgentDefinition] = [
            active,
            AgentDefinition(name: "B", systemPrompt: "", description: ""),
            AgentDefinition(name: "C", systemPrompt: "", description: ""),
            AgentDefinition(name: "D", systemPrompt: "", description: ""),
            AgentDefinition(name: "E", systemPrompt: "", description: ""),
        ]
        let session = ChatSession(
            id: UUID(),
            title: "Big",
            agents: agents,
            activeAgentID: active.id
        )
        let source = HandoffToolSource()
        let defs = await source.toolDefinitions(for: session)
        XCTAssertEqual(defs.count, 4)
        // Sabotage-evidence: M1 hard-cap truncation → defs.count<4.
        // Sabotage-evidence: M2 drop warning → silent breach (covered by code review).
        // Sabotage-evidence: M3 include active → defs.count==5.
    }

    // MARK: - resolve error surface

    func test_resolve_handoffName_throwsHandoffMustBeInterceptedUpstream() async {
        let writer = AgentDefinition(name: "Writer", systemPrompt: "", description: "")
        let session = ChatSession(
            id: UUID(),
            title: "T",
            agents: [writer],
            activeAgentID: nil
        )
        let source = HandoffToolSource()
        do {
            _ = try await source.resolve(
                toolName: "transfer_to_Writer",
                arguments: "{}",
                session: session
            )
            XCTFail("expected throw")
        } catch HandoffSourceError.handoffMustBeInterceptedUpstream(let name) {
            XCTAssertEqual(name, "transfer_to_Writer")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        // Sabotage-evidence: M1 silent return → XCTFail("expected throw") triggers.
        // Sabotage-evidence: M2 throw wrong case → unexpected-error-type branch fires.
        // Sabotage-evidence: M3 swallow prefix check → unknownTransferTarget thrown instead.
    }
}
