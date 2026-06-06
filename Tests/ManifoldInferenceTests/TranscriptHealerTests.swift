import XCTest
@testable import ManifoldInference

/// Unit tests for ``TranscriptHealer``. These cover the orphan-detection and
/// synthesis logic in isolation — no SwiftData, no backends — so they pin the
/// pure value-level contract independent of how the healer is wired into
/// session reload.
final class TranscriptHealerTests: XCTestCase {

    private let sessionID = UUID()

    // MARK: - Helpers

    private func record(
        role: MessageRole,
        parts: [MessagePart]
    ) -> ChatMessage {
        ChatMessage(
            role: role,
            contentParts: parts,
            sessionID: sessionID
        )
    }

    private func toolCall(id: String, name: String = "search", args: String = "{\"q\":\"x\"}") -> ToolCall {
        ToolCall(id: id, toolName: name, arguments: args)
    }

    // MARK: - heal(_:)

    func test_heal_emptyTranscript_returnsEmpty() {
        XCTAssertEqual(TranscriptHealer.heal([]).count, 0)
    }

    func test_heal_textOnlyTranscript_returnsUnchanged() {
        let transcript: [ChatMessage] = [
            record(role: .user, parts: [.text("hi")]),
            record(role: .assistant, parts: [.text("hello")])
        ]
        let healed = TranscriptHealer.heal(transcript)
        XCTAssertEqual(healed, transcript)
    }

    func test_heal_pairedToolCallAndResult_returnsUnchanged() {
        let call = toolCall(id: "call-1")
        let result = ToolResult(callId: "call-1", content: "ok")
        let transcript: [ChatMessage] = [
            record(role: .user, parts: [.text("look it up")]),
            record(role: .assistant, parts: [.toolCall(call), .toolResult(result), .text("done")])
        ]
        let healed = TranscriptHealer.heal(transcript)
        XCTAssertEqual(healed, transcript)
    }

    func test_heal_orphanCall_synthesisesCancelledResultRightAfterCall() {
        let orphan = toolCall(id: "orphan-1", name: "writeFile", args: "{\"path\":\"/tmp/x\"}")
        let transcript: [ChatMessage] = [
            record(role: .user, parts: [.text("write the file")]),
            record(role: .assistant, parts: [.text("ok"), .toolCall(orphan)])
        ]
        let healed = TranscriptHealer.heal(transcript)

        XCTAssertEqual(healed.count, 2)
        XCTAssertEqual(healed[1].contentParts.count, 3)
        // Synthesised result is the part immediately after the orphan call.
        guard case .toolResult(let synth) = healed[1].contentParts[2] else {
            XCTFail("Expected synthesised toolResult after orphan call")
            return
        }
        XCTAssertEqual(synth.callId, "orphan-1")
        XCTAssertEqual(synth.errorKind, .cancelled)
        XCTAssertTrue(synth.content.contains("interrupted"))
        XCTAssertTrue(
            synth.content.contains("{\"path\":\"/tmp/x\"}"),
            "Synthesised content must include the original arguments"
        )
        XCTAssertTrue(synth.isError)
    }

    /// Acceptance criterion: multiple orphans in one session each get their
    /// own synthesised result, with each result keyed to the matching call id.
    func test_heal_multipleOrphans_synthesisesOnePerCall() {
        let a = toolCall(id: "orphan-A", name: "writeFile")
        let b = toolCall(id: "orphan-B", name: "deleteFile")
        let c = toolCall(id: "orphan-C", name: "send")
        let transcript: [ChatMessage] = [
            record(role: .user, parts: [.text("do many things")]),
            record(role: .assistant, parts: [.toolCall(a), .toolCall(b)]),
            record(role: .user, parts: [.text("and one more")]),
            record(role: .assistant, parts: [.toolCall(c)])
        ]
        let healed = TranscriptHealer.heal(transcript)

        let synthesised = healed
            .flatMap { $0.contentParts }
            .compactMap { part -> ToolResult? in
                if case .toolResult(let r) = part { return r }
                return nil
            }

        XCTAssertEqual(Set(synthesised.map(\.callId)), ["orphan-A", "orphan-B", "orphan-C"])
        XCTAssertTrue(synthesised.allSatisfy { $0.errorKind == .cancelled })
        XCTAssertEqual(synthesised.count, 3, "Each orphan must get exactly one synthesised result")
    }

    func test_heal_onlySomeCallsAreOrphans_healsOnlyOrphans() {
        let resolved = toolCall(id: "ok-1", name: "search")
        let orphan = toolCall(id: "orphan-1", name: "writeFile")
        let transcript: [ChatMessage] = [
            record(role: .assistant, parts: [
                .toolCall(resolved),
                .toolResult(ToolResult(callId: "ok-1", content: "found")),
                .toolCall(orphan)
            ])
        ]
        let healed = TranscriptHealer.heal(transcript)

        // Original 3 parts + 1 synthesised result = 4
        XCTAssertEqual(healed[0].contentParts.count, 4)
        guard case .toolResult(let synth) = healed[0].contentParts[3] else {
            XCTFail("Expected synthesised toolResult")
            return
        }
        XCTAssertEqual(synth.callId, "orphan-1")
        XCTAssertEqual(synth.errorKind, .cancelled)
    }

    /// Result for an orphan can sit in a *later* assistant turn — that still
    /// counts as resolved and must not be double-synthesised.
    func test_heal_resultInLaterMessage_isStillConsideredResolved() {
        let call = toolCall(id: "split-1")
        let result = ToolResult(callId: "split-1", content: "ok")
        let transcript: [ChatMessage] = [
            record(role: .assistant, parts: [.toolCall(call)]),
            record(role: .assistant, parts: [.toolResult(result)])
        ]
        let healed = TranscriptHealer.heal(transcript)
        XCTAssertEqual(healed, transcript, "Result in a later message resolves the call")
    }

    /// Healing must be idempotent: running heal twice produces the same
    /// transcript as running it once.
    func test_heal_isIdempotent() {
        let orphan = toolCall(id: "orphan-X")
        let transcript: [ChatMessage] = [
            record(role: .assistant, parts: [.toolCall(orphan)])
        ]
        let once = TranscriptHealer.heal(transcript)
        let twice = TranscriptHealer.heal(once)
        XCTAssertEqual(once, twice)
    }
}
