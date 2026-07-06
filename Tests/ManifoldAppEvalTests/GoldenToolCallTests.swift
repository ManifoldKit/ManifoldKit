import XCTest
import ManifoldInference
import ManifoldAppEval

// MARK: - GoldenToolCallTests

/// End-to-end coverage for the `scriptedToolCall` seam: a JSON fixture
/// scripts a tool call, the mapper synthesizes the executor from the `result`
/// payload, and the `expectedToolCalls` checkpoint passes — proving the
/// assertion kind is satisfiable from the JSON path alone.
final class GoldenToolCallTests: XCTestCase {

    private let toolCallFixtureJSON = """
    {
      "id": "tool-roundtrip-fixture",
      "turns": [
        {
          "kind": "send",
          "text": "Use the echo tool.",
          "cannedResponse": "Echoed result.",
          "scriptedToolCall": {
            "name": "echo",
            "arguments": "{\\"message\\": \\"hello world\\"}",
            "result": "Echo: hello world"
          }
        }
      ],
      "checkpoints": [
        {
          "afterTurnIndex": 0,
          "label": "tool round trip",
          "requiredContent": ["Echoed"],
          "expectedEvents": ["streamStarted", "toolCallRequested", "toolCallApproved", "toolCallCompleted", "tokenEmitted", "streamFinished"],
          "expectedToolCalls": [ { "name": "echo", "argumentsContain": { "message": "hello" } } ]
        }
      ]
    }
    """

    func test_scriptedToolCall_expectedToolCallsCheckpointPasses() async throws {
        let fixture = try JSONDecoder().decode(GoldenTaskFixture.self, from: Data(toolCallFixtureJSON.utf8))
        let outcome = try await GoldenTaskRunner.run(fixture)

        let result = try XCTUnwrap(outcome.checkpointResults.first)

        let toolCallsScore = try XCTUnwrap(result.scores["expectedToolCalls"])
        XCTAssertEqual(toolCallsScore.value, .bool(true), toolCallsScore.explanation ?? "")

        let eventsScore = try XCTUnwrap(result.scores["expectedEvents"])
        XCTAssertEqual(eventsScore.value, .bool(true), eventsScore.explanation ?? "")

        let contentScore = try XCTUnwrap(result.scores["requiredContent"])
        XCTAssertEqual(contentScore.value, .bool(true), contentScore.explanation ?? "")
    }

    /// Negative variant: expecting a tool that the fixture never scripts
    /// must fail, proving the pass above is load-bearing rather than vacuous.
    func test_scriptedToolCall_wrongExpectedToolName_fails() async throws {
        var fixture = try JSONDecoder().decode(GoldenTaskFixture.self, from: Data(toolCallFixtureJSON.utf8))
        fixture = GoldenTaskFixture(
            id: fixture.id,
            systemPrompt: fixture.systemPrompt,
            turns: fixture.turns,
            checkpoints: [
                GoldenCheckpoint(
                    afterTurnIndex: 0,
                    label: "wrong tool",
                    expectedToolCalls: [GoldenExpectedToolCall(name: "not-the-echo-tool")]
                ),
            ]
        )
        let outcome = try await GoldenTaskRunner.run(fixture)

        let result = try XCTUnwrap(outcome.checkpointResults.first)
        let score = try XCTUnwrap(result.scores["expectedToolCalls"])
        XCTAssertEqual(score.value, .bool(false))
        XCTAssertNotNil(score.explanation)
    }

    /// Negative variant: right tool, wrong argument substring — fails on the
    /// argument-level check, not just tool presence.
    func test_scriptedToolCall_wrongArgumentSubstring_fails() async throws {
        var fixture = try JSONDecoder().decode(GoldenTaskFixture.self, from: Data(toolCallFixtureJSON.utf8))
        fixture = GoldenTaskFixture(
            id: fixture.id,
            systemPrompt: fixture.systemPrompt,
            turns: fixture.turns,
            checkpoints: [
                GoldenCheckpoint(
                    afterTurnIndex: 0,
                    label: "wrong argument",
                    expectedToolCalls: [
                        GoldenExpectedToolCall(name: "echo", argumentsContain: ["message": "goodbye"]),
                    ]
                ),
            ]
        )
        let outcome = try await GoldenTaskRunner.run(fixture)

        let result = try XCTUnwrap(outcome.checkpointResults.first)
        let score = try XCTUnwrap(result.scores["expectedToolCalls"])
        XCTAssertEqual(score.value, .bool(false))
    }

    /// A caller-supplied executor with the same tool name wins over the
    /// synthetic one, so apps can exercise their real executor against a
    /// fixture-scripted call.
    func test_callerSuppliedExecutor_winsOverSynthetic() async throws {
        let fixture = try JSONDecoder().decode(GoldenTaskFixture.self, from: Data(toolCallFixtureJSON.utf8))

        final class RecordingEchoTool: ToolExecutor, @unchecked Sendable {
            private let lock = NSLock()
            private var _executed = false
            var executed: Bool { lock.withLock { _executed } }

            var definition: ToolDefinition {
                ToolDefinition(name: "echo", description: "recording echo", parameters: .object([:]))
            }

            func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
                lock.withLock { _executed = true }
                return ToolResult(callId: "", content: "recorded")
            }
        }

        let recorder = RecordingEchoTool()
        let outcome = try await GoldenTaskRunner.run(fixture, toolExecutors: [recorder])

        XCTAssertTrue(recorder.executed, "caller-supplied executor must be the one dispatched, not the synthetic")
        let result = try XCTUnwrap(outcome.checkpointResults.first)
        let score = try XCTUnwrap(result.scores["expectedToolCalls"])
        XCTAssertEqual(score.value, .bool(true))
    }

    /// A tool-call turn contributes two backend scripts to one user turn — a
    /// later checkpoint's prefix slicing must stay aligned across the tool
    /// turn (regression guard for the group-based prefix construction).
    func test_toolCallTurn_prefixSlicingStaysAlignedForLaterCheckpoints() async throws {
        let json = """
        {
          "id": "tool-then-plain",
          "turns": [
            {
              "kind": "send",
              "text": "Use the echo tool.",
              "cannedResponse": "Echoed.",
              "scriptedToolCall": { "name": "echo", "arguments": "{}", "result": "Echo: ok" }
            },
            { "kind": "send", "text": "Now just answer.", "cannedResponse": "Plain answer." }
          ],
          "checkpoints": [
            {
              "afterTurnIndex": 1,
              "label": "post-tool plain turn",
              "requiredContent": ["Plain answer."],
              "expectedEvents": ["toolCallCompleted", "streamFinished", "streamFinished"]
            }
          ]
        }
        """
        let fixture = try JSONDecoder().decode(GoldenTaskFixture.self, from: Data(json.utf8))
        let outcome = try await GoldenTaskRunner.run(fixture)

        let result = try XCTUnwrap(outcome.checkpointResults.first)
        for (assertion, score) in result.scores.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(score.value, .bool(true), "\(assertion): \(score.explanation ?? "")")
        }
    }
}
