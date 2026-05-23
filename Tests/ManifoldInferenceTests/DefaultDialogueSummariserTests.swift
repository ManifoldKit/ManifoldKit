import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Unit coverage for ``DefaultDialogueSummariser``.
///
/// Verifies that:
/// - The prompt sent to the backend contains the turn content.
/// - The backend's accumulated output is returned verbatim as the summary.
/// - ``NoOpDialogueSummariser`` always returns an empty string.
@MainActor
final class DefaultDialogueSummariserTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTurns(sessionID: UUID = UUID()) -> [ChatMessageRecord] {
        [
            ChatMessageRecord(role: .user, content: "What is the weather in Paris?", sessionID: sessionID),
            ChatMessageRecord(role: .assistant, content: "It is 18°C and sunny in Paris.", sessionID: sessionID),
            ChatMessageRecord(role: .user, content: "Thanks! And in Rome?", sessionID: sessionID),
            ChatMessageRecord(role: .assistant, content: "Rome is currently 22°C.", sessionID: sessionID),
        ]
    }

    // MARK: - CapturingBackend

    /// Wraps MockInferenceBackend and records the last prompt it received.
    final class CapturingBackend: InferenceBackend, @unchecked Sendable {
        let inner: MockInferenceBackend
        private(set) var capturedPrompt: String?

        init(inner: MockInferenceBackend) {
            self.inner = inner
        }

        var isModelLoaded: Bool { inner.isModelLoaded }
        var isGenerating: Bool { inner.isGenerating }
        var capabilities: BackendCapabilities { inner.capabilities }

        func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
            try await inner.loadModel(from: url, plan: plan)
        }

        func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
            capturedPrompt = prompt
            return try inner.generate(prompt: prompt, systemPrompt: systemPrompt, config: config)
        }

        func stopGeneration() { inner.stopGeneration() }
        func unloadModel() { inner.unloadModel() }
    }

    // MARK: - Tests

    func test_promptContainsTurnContent() async throws {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["This", " is", " a", " summary."]
        let capturing = CapturingBackend(inner: mock)
        let summariser = DefaultDialogueSummariser()
        let sessionID = UUID()
        let turns = makeTurns(sessionID: sessionID)

        _ = try await summariser.summarise(turns: turns, using: capturing)

        let prompt = try XCTUnwrap(capturing.capturedPrompt, "backend should have received a prompt")
        XCTAssertTrue(prompt.contains("What is the weather in Paris?"),
            "prompt should contain first user turn; got: \(prompt)")
        XCTAssertTrue(prompt.contains("18°C and sunny in Paris"),
            "prompt should contain first assistant turn; got: \(prompt)")
        XCTAssertTrue(prompt.contains("Rome is currently 22°C"),
            "prompt should contain last assistant turn; got: \(prompt)")
    }

    func test_backendOutputReturnedAsSummary() async throws {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        let expectedSummary = "NONCE-A8F2: The user asked about the weather in two cities."
        mock.tokensToYield = [expectedSummary]
        let capturing = CapturingBackend(inner: mock)
        let summariser = DefaultDialogueSummariser()
        let sessionID = UUID()

        let summary = try await summariser.summarise(turns: makeTurns(sessionID: sessionID), using: capturing)

        XCTAssertEqual(summary, expectedSummary)

        // Sabotage: make the mock yield a different string and confirm the result changes.
        mock.tokensToYield = ["DIFFERENT_OUTPUT"]
        let sabotage = try await summariser.summarise(turns: makeTurns(sessionID: sessionID), using: capturing)
        XCTAssertNotEqual(sabotage, expectedSummary,
            "sabotage: result should change when mock yields different output")
    }

    func test_promptIncludesRoleLabels() async throws {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["OK"]
        let capturing = CapturingBackend(inner: mock)
        let summariser = DefaultDialogueSummariser()
        let turns = makeTurns()

        _ = try await summariser.summarise(turns: turns, using: capturing)

        let prompt = try XCTUnwrap(capturing.capturedPrompt)
        XCTAssertTrue(prompt.contains("User:"),
            "prompt should contain User: role label; got: \(prompt)")
        XCTAssertTrue(prompt.contains("Assistant:"),
            "prompt should contain Assistant: role label; got: \(prompt)")
    }

    func test_noOpSummariserReturnsEmptyString() async throws {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        // Ensure mock yields tokens — NoOp should never reach the backend.
        mock.tokensToYield = ["should not appear"]
        let summariser = NoOpDialogueSummariser()
        let turns = makeTurns()

        let result = try await summariser.summarise(turns: turns, using: mock)

        XCTAssertTrue(result.isEmpty, "NoOpDialogueSummariser must return an empty string; got '\(result)'")
    }

    func test_singleTurnSummarySucceeds() async throws {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["Single turn summary."]
        let summariser = DefaultDialogueSummariser()
        let turn = ChatMessageRecord(role: .user, content: "Hello!", sessionID: UUID())

        let result = try await summariser.summarise(turns: [turn], using: mock)

        XCTAssertFalse(result.isEmpty, "summary should not be empty for a single non-empty turn")
    }
}
