import XCTest
import ManifoldInference
@testable import ManifoldRuntime

/// Pins payload survival end-to-end through the detector + boundary helper
/// so a refactor of either side fails the round-trip rather than silently
/// dropping the payload on the wire.
final class HandoffPayloadRoundtripTests: XCTestCase {

    func test_payload_nil_roundtrips() {
        let previous = Agent(name: "Researcher", systemPrompt: "", description: "")
        let next = Agent(name: "Writer", systemPrompt: "", description: "")
        let handoff = AgentHandoff(targetAgentID: next.id, payload: nil)

        let boundary = HandoffDetector.boundaryMessage(
            from: previous,
            to: next,
            payload: handoff.payload
        )

        XCTAssertEqual(boundary, "[Handoff from Researcher to Writer]")
        XCTAssertFalse(boundary.contains("payload:"))
        // Sabotage-evidence: M1 force header to include "payload:" → contains check fails.
        // Sabotage-evidence: M2 swap to optional("") behaviour → trailing whitespace breaks equality.
        // Sabotage-evidence: M3 ignore nil → "(null)" rendered into boundary.
    }

    func test_payload_present_roundtrips() {
        let previous = Agent(name: "Researcher", systemPrompt: "", description: "")
        let next = Agent(name: "Writer", systemPrompt: "", description: "")
        let handoff = AgentHandoff(targetAgentID: next.id, payload: "outline-here")

        let boundary = HandoffDetector.boundaryMessage(
            from: previous,
            to: next,
            payload: handoff.payload
        )

        XCTAssertEqual(boundary, "[Handoff from Researcher to Writer] payload: outline-here")
        // Sabotage-evidence: M1 drop payload concatenation → equality fails.
        // Sabotage-evidence: M2 URL-encode payload → fails verbatim match.
        // Sabotage-evidence: M3 swap "payload:" delimiter → equality fails.
    }

    func test_payload_extractedFromArguments() {
        let writer = Agent(name: "Writer", systemPrompt: "", description: "")
        let session = ChatSessionRecord(
            id: UUID(),
            title: "T",
            agents: [writer],
            activeAgentID: nil
        )
        let call = ToolCall(
            id: "rt-1",
            toolName: "transfer_to_Writer",
            arguments: #"{"payload":"outline-here"}"#
        )

        let result = HandoffDetector.classify(call, in: session)
        guard case .handoff(let handoff) = result else {
            return XCTFail("expected .handoff")
        }
        XCTAssertEqual(handoff.payload, "outline-here")
        // Sabotage-evidence: M1 hard-code nil payload → assertion fails.
        // Sabotage-evidence: M2 misread key as "data" → payload nil.
        // Sabotage-evidence: M3 capture raw arguments string → equality breaks.
    }
}
