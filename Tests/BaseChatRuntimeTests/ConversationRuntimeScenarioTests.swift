import XCTest
import BaseChatRuntime
import BaseChatPersistenceSwiftData
import BaseChatInference
import BaseChatTestSupport

/// Demonstrates the ``ConversationRuntimeScenario`` harness against
/// `MockInferenceBackend`. Exists primarily to lock the harness contract:
/// scripted tokens flow through the runtime, are persisted in SwiftData,
/// and the assertion predicates in the scenario hold against the persisted
/// state.
@MainActor
final class ConversationRuntimeScenarioTests: XCTestCase {

    /// Sabotage-evidence:
    ///   M1: in `ConversationRuntimeScenarioRunner.run`, comment out
    ///       `try await stack.provider.insertSession(session)`; the
    ///       `runtime.send(...)` call traps because there's no session,
    ///       making `endedNormally=false` and the contains-assertion fails.
    ///   M2: change the OOD nonce `"§SCEN§…"` in `expectedFinalAssistantContains`
    ///       to `"§NOPE§"`; the contains-check below flips because the
    ///       persisted assistant message contains the original nonce, not
    ///       the mutated one.
    ///   M3: not capability-gated.
    func test_singleSend_persistsAssistantMessageContainingNonce() async throws {
        let nonce = "§SCEN§\(UUID().uuidString.prefix(8))"
        let scenario = ConversationRuntimeScenario(
            steps: [
                .init(
                    action: .send(text: "remember \(nonce)"),
                    scriptedTokens: ["sure: ", nonce, " — done"]
                )
            ],
            expectedFinalAssistantContains: nonce,
            expectedAssistantMessageCount: 1
        )

        let backend = MockInferenceBackend()
        let result = try await ConversationRuntimeScenarioRunner.run(
            scenario: scenario,
            backend: backend
        )

        XCTAssertTrue(result.assertionsPassed,
                      "scenario assertions must pass — reason: \(result.assertionFailureReason ?? "<unknown>")")
        XCTAssertEqual(result.stepResults.count, 1)
        XCTAssertTrue(result.stepResults[0].endedNormally,
                      "send step must end normally; got error \(String(describing: result.stepResults[0].error))")
        XCTAssertEqual(result.finalAssistantContents.count, 1)
        XCTAssertTrue(result.finalAssistantContents[0].contains(nonce),
                      "persisted assistant message must contain the OOD nonce")
    }

    /// Two consecutive sends must persist two distinct assistant messages
    /// — the runtime appends, doesn't replace. Discriminates send-vs-regenerate
    /// behaviour at the persistence layer.
    func test_twoSends_persistsTwoAssistantMessages() async throws {
        let nonceA = "§A§\(UUID().uuidString.prefix(6))"
        let nonceB = "§B§\(UUID().uuidString.prefix(6))"
        let scenario = ConversationRuntimeScenario(
            steps: [
                .init(action: .send(text: "first"), scriptedTokens: ["A:", nonceA]),
                .init(action: .send(text: "second"), scriptedTokens: ["B:", nonceB])
            ],
            expectedFinalAssistantContains: nonceB,
            expectedAssistantMessageCount: 2
        )

        let backend = MockInferenceBackend()
        let result = try await ConversationRuntimeScenarioRunner.run(
            scenario: scenario,
            backend: backend
        )

        XCTAssertTrue(result.assertionsPassed,
                      "scenario assertions must pass — reason: \(result.assertionFailureReason ?? "<unknown>")")
        XCTAssertEqual(result.finalAssistantContents.count, 2)
        XCTAssertTrue(result.finalAssistantContents[0].contains(nonceA),
                      "first persisted assistant must contain nonceA")
        XCTAssertTrue(result.finalAssistantContents[1].contains(nonceB),
                      "second persisted assistant must contain nonceB (and not be the regenerate-replaced shape)")
    }

    /// Failure-path scenario: assertion predicate fails when the scripted
    /// tokens don't satisfy `expectedFinalAssistantContains`.
    func test_failedAssertion_isReportedNotThrown() async throws {
        let scenario = ConversationRuntimeScenario(
            steps: [
                .init(action: .send(text: "x"), scriptedTokens: ["totally", " unrelated"])
            ],
            expectedFinalAssistantContains: "§MISSING§",
            expectedAssistantMessageCount: 1
        )

        let backend = MockInferenceBackend()
        let result = try await ConversationRuntimeScenarioRunner.run(
            scenario: scenario,
            backend: backend
        )

        XCTAssertFalse(result.assertionsPassed,
                       "predicate not satisfied — assertionsPassed must be false")
        XCTAssertNotNil(result.assertionFailureReason)
        XCTAssertTrue(result.assertionFailureReason?.contains("§MISSING§") == true,
                      "failure reason must mention the unmet predicate value")
    }

    /// The harness is JSON-codable. Round-trip a scenario through Data and
    /// verify the decoded form behaves identically. Lets host apps store
    /// scenarios as fixture files alongside their tests.
    func test_scenario_isCodable_roundTripsViaJSON() throws {
        let original = ConversationRuntimeScenario(
            steps: [
                .init(action: .send(text: "hi"), scriptedTokens: ["hello"])
            ],
            expectedFinalAssistantContains: "hello",
            expectedAssistantMessageCount: 1
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConversationRuntimeScenario.self, from: encoded)

        XCTAssertEqual(decoded.steps.count, original.steps.count)
        if case .send(let text) = decoded.steps[0].action {
            XCTAssertEqual(text, "hi")
        } else {
            XCTFail("decoded action must be .send")
        }
        XCTAssertEqual(decoded.expectedFinalAssistantContains, "hello")
        XCTAssertEqual(decoded.expectedAssistantMessageCount, 1)
    }
}
