import XCTest
import ManifoldRuntime
import ManifoldAppEval

// MARK: - GoldenTaskMapperTests

final class GoldenTaskMapperTests: XCTestCase {

    func test_map_sendTurn_producesSendAction() throws {
        let fixture = GoldenTaskFixture(
            id: "send-only",
            turns: [GoldenTurn(kind: .send, text: "hi", cannedResponse: "hello")],
            checkpoints: []
        )
        let scenario = try GoldenTaskMapper.map(fixture)

        XCTAssertEqual(scenario.turns.count, 1)
        guard case .send(let text) = scenario.turns[0].action else {
            return XCTFail("expected a .send action")
        }
        XCTAssertEqual(text, "hi")
        XCTAssertEqual(scenario.scriptedTurns.count, 1)
    }

    func test_map_regenerateTurn_producesRegenerateAction() throws {
        let fixture = GoldenTaskFixture(
            id: "regen",
            turns: [
                GoldenTurn(kind: .send, text: "hi", cannedResponse: "hello"),
                GoldenTurn(kind: .regenerate, cannedResponse: "hello again"),
            ],
            checkpoints: []
        )
        let scenario = try GoldenTaskMapper.map(fixture)

        XCTAssertEqual(scenario.turns.count, 2)
        guard case .regenerate = scenario.turns[1].action else {
            return XCTFail("expected a .regenerate action")
        }
    }

    func test_map_editTurn_throwsNotYetSupported() {
        let fixture = GoldenTaskFixture(
            id: "edit",
            turns: [GoldenTurn(kind: .edit, text: "replacement")],
            checkpoints: []
        )
        XCTAssertThrowsError(try GoldenTaskMapper.map(fixture)) { error in
            guard let mapError = error as? GoldenTaskMapper.MapError else {
                return XCTFail("expected GoldenTaskMapper.MapError, got \(error)")
            }
            if case .editNotYetSupported(let turnIndex) = mapError {
                XCTAssertEqual(turnIndex, 0)
            } else {
                XCTFail("expected .editNotYetSupported, got \(mapError)")
            }
        }
    }

    func test_map_sendTurnMissingText_throws() {
        let fixture = GoldenTaskFixture(
            id: "missing-text",
            turns: [GoldenTurn(kind: .send, text: nil, cannedResponse: "hello")],
            checkpoints: []
        )
        XCTAssertThrowsError(try GoldenTaskMapper.map(fixture)) { error in
            guard let mapError = error as? GoldenTaskMapper.MapError else {
                return XCTFail("expected GoldenTaskMapper.MapError, got \(error)")
            }
            if case .sendTurnMissingText(let turnIndex) = mapError {
                XCTAssertEqual(turnIndex, 0)
            } else {
                XCTFail("expected .sendTurnMissingText, got \(mapError)")
            }
        }
    }

    func test_map_systemPrompt_isPlumbedThrough() throws {
        let fixture = GoldenTaskFixture(
            id: "sp",
            systemPrompt: "Be terse.",
            turns: [GoldenTurn(kind: .send, text: "hi", cannedResponse: "hello")],
            checkpoints: []
        )
        let scenario = try GoldenTaskMapper.map(fixture)
        XCTAssertEqual(scenario.systemPrompt, "Be terse.")
    }

    func test_map_cannedResponse_tokenizesLosslessly() async throws {
        // The scripted backend replays tokens verbatim; concatenating them
        // must reproduce the original cannedResponse string exactly,
        // including any double spaces.
        let fixture = GoldenTaskFixture(
            id: "tokenize",
            turns: [GoldenTurn(kind: .send, text: "hi", cannedResponse: "Hello  world, how are you?")],
            checkpoints: []
        )
        let scenario = try GoldenTaskMapper.map(fixture)
        let result = try await RuntimeScenarioRunner.run(scenario)
        let visibleText = result.producedMessages
            .filter { $0.role == .assistant }
            .map(\.content)
            .joined()
        XCTAssertEqual(visibleText, "Hello  world, how are you?")
    }

    /// A nil `cannedResponse` maps to an empty `TurnScript` — zero events, so
    /// generation finishes with `FinishReason.empty`. `ConversationRuntime`
    /// does not persist an empty assistant reply at all (see
    /// `ConversationRuntimeTests.test_finishState_emptyResponse_...`), so the
    /// turn still completes cleanly but with no assistant message in the
    /// store — that absence is the behavior under test here.
    func test_map_nilCannedResponse_producesEmptyTurn() async throws {
        let fixture = GoldenTaskFixture(
            id: "empty-response",
            turns: [GoldenTurn(kind: .send, text: "hi", cannedResponse: nil)],
            checkpoints: []
        )
        let scenario = try GoldenTaskMapper.map(fixture)
        let result = try await RuntimeScenarioRunner.run(scenario)
        let assistantMessages = result.producedMessages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 0, "an empty generation is not persisted as an assistant message")
        let userMessages = result.producedMessages.filter { $0.role == .user }
        XCTAssertEqual(userMessages.count, 1)
    }
}
