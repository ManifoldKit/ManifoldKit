import Foundation
import XCTest
@testable import ManifoldRuntime
import ManifoldInference

/// Pure unit tests for ``HandoffDetector``. No inference, no persistence —
/// the detector is a value-level helper, so the test fixture stays at the
/// same level.
final class HandoffDetectorTests: XCTestCase {

    // MARK: - Fixtures

    private func makeAgent(name: String, description: String = "A description") -> Agent {
        Agent(
            id: UUID(),
            name: name,
            systemPrompt: "You are \(name).",
            description: description
        )
    }

    private func makeSession(agents: [Agent], active: Agent?) -> ChatSession {
        ChatSession(
            id: UUID(),
            title: "Fixture",
            agents: agents,
            activeAgentID: active?.id
        )
    }

    // MARK: - classify

    func test_classify_transferToKnownAgent_returnsHandoff() {
        let researcher = makeAgent(name: "Researcher")
        let writer = makeAgent(name: "Writer")
        let session = makeSession(agents: [researcher, writer], active: researcher)
        let call = ToolCall(id: "c1", toolName: "transfer_to_Writer", arguments: "{}")

        let result = HandoffDetector.classify(call, in: session)

        guard case .handoff(let handoff) = result else {
            return XCTFail("expected .handoff, got \(result)")
        }
        XCTAssertEqual(handoff.targetAgentID, writer.id)
        // Sabotage-evidence: M1 strip prefix-match → result is .regular(call).
        // Sabotage-evidence: M2 always return .regular → .handoff branch unreachable.
        // Sabotage-evidence: M3 mis-route to wrong agent → targetAgentID mismatch.
    }

    func test_classify_transferToUnknownAgent_returnsRegular() {
        let researcher = makeAgent(name: "Researcher")
        let session = makeSession(agents: [researcher], active: researcher)
        let call = ToolCall(id: "c2", toolName: "transfer_to_Ghost", arguments: "{}")

        let result = HandoffDetector.classify(call, in: session)

        guard case .regular(let regular) = result else {
            return XCTFail("expected .regular for unknown agent, got \(result)")
        }
        XCTAssertEqual(regular.id, "c2")
        // Sabotage-evidence: M1 fabricate AgentHandoff for unknown name → unit fails (regular branch unreachable).
        // Sabotage-evidence: M2 throw → test ends abruptly with error.
        // Sabotage-evidence: M3 swap to default-first-agent → wrong target leaks through.
    }

    func test_classify_nonTransferTool_returnsRegular() {
        let agent = makeAgent(name: "Solo")
        let session = makeSession(agents: [agent], active: agent)
        let call = ToolCall(id: "c3", toolName: "read_file", arguments: #"{"path":"/tmp/x"}"#)

        let result = HandoffDetector.classify(call, in: session)

        guard case .regular = result else {
            return XCTFail("expected .regular for non-transfer tool, got \(result)")
        }
        // Sabotage-evidence: M1 drop prefix guard → read_file misrouted as handoff.
        // Sabotage-evidence: M2 nil-coalesce target → .handoff with random id.
        // Sabotage-evidence: M3 always return .handoff → test fails immediately.
    }

    func test_classify_payloadParsedFromArguments() {
        let writer = makeAgent(name: "Writer")
        let session = makeSession(agents: [writer], active: nil)
        let args = #"{"payload":"outline-here"}"#
        let call = ToolCall(id: "c4", toolName: "transfer_to_Writer", arguments: args)

        let result = HandoffDetector.classify(call, in: session)

        guard case .handoff(let handoff) = result else {
            return XCTFail("expected .handoff, got \(result)")
        }
        XCTAssertEqual(handoff.payload, "outline-here")
        // Sabotage-evidence: M1 hard-code nil payload → assertion fails.
        // Sabotage-evidence: M2 swap "payload" key → payload nil.
        // Sabotage-evidence: M3 decode raw arguments → assertion mismatches.
    }

    // MARK: - handoffInstructions

    func test_handoffInstructions_listsSiblings_excludesActive() {
        let researcher = makeAgent(name: "Researcher", description: "gathers facts")
        let writer = makeAgent(name: "Writer", description: "drafts copy")
        let critic = makeAgent(name: "Critic", description: "reviews drafts")

        let instructions = HandoffDetector.handoffInstructions(
            for: researcher,
            siblings: [writer, critic]
        )

        XCTAssertTrue(instructions.contains("- Writer:"))
        XCTAssertTrue(instructions.contains("- Critic:"))
        XCTAssertFalse(instructions.contains("- Researcher:"))
        // Sabotage-evidence: M1 list active → "- Researcher:" appears.
        // Sabotage-evidence: M2 drop sibling iteration → assertions fail.
        // Sabotage-evidence: M3 emit empty string → contains checks fail.
    }

    func test_handoffInstructions_emptyWhenNoSiblings() {
        let solo = makeAgent(name: "Solo")
        XCTAssertEqual(HandoffDetector.handoffInstructions(for: solo, siblings: []), "")
        // Sabotage-evidence: M1 unconditional header → non-empty string returned.
        // Sabotage-evidence: M2 single-line guard removed → newline appears.
        // Sabotage-evidence: M3 echo agent name → fails equality.
    }

    // MARK: - boundaryMessage

    func test_boundaryMessage_includesPayload() {
        let researcher = makeAgent(name: "Researcher")
        let writer = makeAgent(name: "Writer")

        let withPayload = HandoffDetector.boundaryMessage(
            from: researcher,
            to: writer,
            payload: "outline-here"
        )
        let withoutPayload = HandoffDetector.boundaryMessage(
            from: researcher,
            to: writer,
            payload: nil
        )

        XCTAssertEqual(withPayload, "[Handoff from Researcher to Writer] payload: outline-here")
        XCTAssertEqual(withoutPayload, "[Handoff from Researcher to Writer]")
        // Sabotage-evidence: M1 swap from/to → header order inverted.
        // Sabotage-evidence: M2 always append payload prefix → withoutPayload fails.
        // Sabotage-evidence: M3 drop payload concatenation → withPayload fails.
    }
}
