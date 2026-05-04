#if Fuzz
import XCTest
@testable import BaseChatFuzz

final class SessionScriptTests: XCTestCase {

    func test_loadAll_returnsBundledScripts() {
        let scripts = SessionScript.loadAll()
        // We ship 3 named scripts — `session-swap.json` expands into 2 — so
        // 4 scripts total.
        XCTAssertGreaterThanOrEqual(scripts.count, 4,
            "loadAll should return all bundled session scripts; got \(scripts.map(\.id))")
        XCTAssertTrue(scripts.contains { $0.id == "edit-then-regenerate" })
        XCTAssertTrue(scripts.contains { $0.id == "rapid-send-cancel" })
        XCTAssertTrue(scripts.contains { $0.id == "session-swap-A" })
        XCTAssertTrue(scripts.contains { $0.id == "session-swap-B" })
    }

    func test_editThenRegenerate_hasExpectedSteps() throws {
        let scripts = SessionScript.loadAll()
        guard let script = scripts.first(where: { $0.id == "edit-then-regenerate" }) else {
            return XCTFail("edit-then-regenerate script missing")
        }
        XCTAssertEqual(script.steps.count, 4)
        // Step 0 must be a `.send`; step 1 a `.stop`; step 2 an `.edit`;
        // step 3 a `.regenerate`. The detector fixture tests rely on this
        // exact ordering.
        if case .send(let text) = script.steps[0] {
            XCTAssertFalse(text.isEmpty)
        } else { XCTFail("step 0 must be .send") }
        XCTAssertEqual(script.steps[1], .stop)
        if case .edit(let idx, let new) = script.steps[2] {
            XCTAssertEqual(idx, 0)
            XCTAssertFalse(new.isEmpty)
        } else { XCTFail("step 2 must be .edit") }
        XCTAssertEqual(script.steps[3], .regenerate)
    }

    func test_roundTrip_encodeDecode_preservesSteps() throws {
        let original = SessionScript(
            id: "rt",
            steps: [
                .send(text: "hi"),
                .stop,
                .edit(messageIndex: 0, newText: "hey"),
                .regenerate,
                .delete(messageIndex: 1),
            ],
            systemPrompt: "be brief",
            sessionLabel: "lbl"
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionScript.self, from: encoded)
        XCTAssertEqual(original, decoded)
    }

    func test_unknownOp_throwsDecoding() {
        let json = #"{"id":"x","steps":[{"op":"teleport"}]}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(SessionScript.self, from: Data(json.utf8))
        )
    }

    func test_opNameLabels() {
        XCTAssertEqual(SessionScript.Step.send(text: "x").opName, "send")
        XCTAssertEqual(SessionScript.Step.stop.opName, "stop")
        XCTAssertEqual(SessionScript.Step.edit(messageIndex: 0, newText: "x").opName, "edit")
        XCTAssertEqual(SessionScript.Step.regenerate.opName, "regenerate")
        XCTAssertEqual(SessionScript.Step.delete(messageIndex: 0).opName, "delete")
    }
}
#endif
