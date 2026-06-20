import Foundation
import ManifoldInference

/// Runs a single ``Scenario`` against a supplied backend and registry.
///
/// The runner is the glue between the declarative scenario JSON, the generic
/// ``ToolRegistry`` dispatch seam, and the chosen ``InferenceBackend``. It
/// loops up to ``maxIterations`` times:
///
/// 1. Request generation from the backend with the current conversation state.
/// 2. Consume every ``GenerationEvent`` — accumulating token text and any
///    ``ToolCall`` the model emits.
/// 3. If the model requested tool calls, dispatch each through the registry,
///    record the results on the conversation, and go round again.
/// 4. If no tool calls were emitted (or the budget is exhausted), the
///    accumulated text is the final answer and assertions run against it.
///
/// Conversation history is plumbed into backends that conform to
/// ``ConversationHistoryReceiver`` (same pattern as ``GenerationQueue``);
/// backends that do not conform get a plain-text prompt with appended tool
/// results.
@MainActor
public final class ScenarioRunner {

    public struct Outcome: Sendable {
        public let scenarioId: String
        public let finalAnswer: String
        public let toolCallsExecuted: [String]
        public let toolResults: [ToolResultRecord]
        public let assertions: [AssertionOutcome]
        public var passed: Bool { assertions.allSatisfy(\.passed) }
    }

    public let backend: any InferenceBackend
    public let registry: ToolRegistry
    public let logger: TranscriptLogger?
    public let maxIterations: Int

    public init(
        backend: any InferenceBackend,
        registry: ToolRegistry,
        logger: TranscriptLogger? = nil,
        maxIterations: Int = 6
    ) {
        self.backend = backend
        self.registry = registry
        self.logger = logger
        self.maxIterations = maxIterations
    }

    /// Executes a scenario. Errors bubble out; ``Outcome/passed`` captures
    /// the assertion verdict.
    public func run(_ scenario: Scenario) async throws -> Outcome {
        logger?.append(.prompt(scenarioId: scenario.id, system: scenario.systemPrompt, user: scenario.userPrompt))

        var history: [(role: String, content: String)] = [
            (role: "system", content: scenario.systemPrompt),
            (role: "user", content: scenario.userPrompt)
        ]
        var accumulatedText = ""
        var toolCallsExecuted: [String] = []
        var toolResults: [ToolResultRecord] = []

        let definitions = registry.definitions.filter { scenario.requiredTools.isEmpty || scenario.requiredTools.contains($0.name) }

        let config = makeConfig(for: scenario, tools: definitions)

        for _ in 0..<maxIterations {
            if let receiver = backend as? ConversationHistoryReceiver {
                receiver.setConversationHistory(history)
            }

            let prompt = history.last { $0.role == "user" || $0.role == "tool" }?.content ?? scenario.userPrompt
            let system = scenario.systemPrompt

            let stream = try backend.generate(prompt: prompt, systemPrompt: system, config: config)

            var turnText = ""
            var turnToolCalls: [ToolCall] = []

            for try await event in stream.events {
                switch event {
                case .token(let t):
                    turnText += t
                    logger?.append(.tokenDelta(scenarioId: scenario.id, text: t))
                case .toolCall(let call):
                    turnToolCalls.append(call)
                    logger?.append(.toolCall(scenarioId: scenario.id, name: call.toolName, arguments: call.arguments))
                case .prefillProgress, .promptRendered, .usage, .thinkingToken, .thinkingCompleted, .thinkingSignature:
                    continue
                case .toolResult, .toolIterationLimitExceeded, .runTokenBudgetExceeded:
                    // ScenarioRunner calls backend.generate() directly and owns
                    // dispatch below, so it never receives GenerationQueue's
                    // orchestrator events on this path. Stay exhaustive for growth.
                    continue
                case .kvCacheReuse:
                    continue
                case .throttleDiagnostic:
                    // Advisory pause signal from the orchestrator; scenarios
                    // are deterministic replays so we just keep accumulating.
                    continue
                case .toolCallStart, .toolCallArgumentsDelta:
                    // Streaming tool-call deltas are observational; the
                    // authoritative call lands on `.toolCall(_:)`.
                    continue
                case .toolProgress, .toolDispatchStarted, .toolDispatchCompleted, .toolCallApproved:
                    // Dispatch lifecycle markers are observational; tool
                    // accounting flows through `.toolCall` / `.toolResult`.
                    continue
                case .toolCallParseFailed, .toolCallTruncated:
                    // Non-fatal tool-call diagnostics (#1857 / #1858); the
                    // authoritative call still lands on `.toolCall(_:)` when it
                    // parses. Observational here.
                    continue
                case .handoffRequested:
                    // Multi-agent handoffs are runtime-driven; deterministic
                    // single-agent replays never observe them.
                    continue
                case .generationCompleted:
                    // Terminal "response finished" marker. ScenarioRunner
                    // accumulates text directly and detects stable state via
                    // empty tool-calls below; the completion event is purely
                    // observational here.
                    continue
                }
            }

            accumulatedText += turnText
            if !turnText.isEmpty {
                history.append((role: "assistant", content: turnText))
            }

            if turnToolCalls.isEmpty {
                // Stable state — the model produced a final text answer.
                break
            }

            for call in turnToolCalls {
                let result = await registry.dispatch(call)
                toolCallsExecuted.append(call.toolName)
                toolResults.append(ToolResultRecord(
                    toolName: call.toolName,
                    content: result.content,
                    errorKind: result.errorKind?.rawValue
                ))
                logger?.append(.toolResult(
                    scenarioId: scenario.id,
                    name: call.toolName,
                    content: result.content,
                    errorKind: result.errorKind?.rawValue
                ))
                // Append as a "tool" role message so ConversationHistoryReceiver
                // backends can feed it back. Plain-text backends get it concatenated
                // to the next user prompt as a fallback below.
                history.append((role: "tool", content: result.content))
            }

            // Non-history-aware backends need the tool result spliced into the
            // next prompt — otherwise they regenerate from the same input and
            // loop forever. This branch is only exercised by backends that do
            // not conform to ConversationHistoryReceiver.
            if !(backend is ConversationHistoryReceiver) {
                let toolTrace = turnToolCalls.enumerated().map { idx, call in
                    "[tool \(call.toolName)] → \(history[history.count - turnToolCalls.count + idx].content)"
                }.joined(separator: "\n")
                history.append((role: "user", content: "Tool results:\n\(toolTrace)\nContinue your answer using these results."))
            }
        }

        logger?.append(.final(scenarioId: scenario.id, text: accumulatedText))

        var assertionOutcomes: [AssertionOutcome] = []
        for assertion in scenario.assertions {
            let outcome = AssertionEvaluator.evaluate(
                assertion,
                finalAnswer: accumulatedText,
                toolsInvoked: toolCallsExecuted,
                toolResults: toolResults
            )
            assertionOutcomes.append(outcome)
            logger?.append(.assertion(scenarioId: scenario.id, passed: outcome.passed, message: outcome.message))
        }

        return Outcome(
            scenarioId: scenario.id,
            finalAnswer: accumulatedText,
            toolCallsExecuted: toolCallsExecuted,
            toolResults: toolResults,
            assertions: assertionOutcomes
        )
    }

    private func makeConfig(for scenario: Scenario, tools: [ToolDefinition]) -> GenerationConfig {
        GenerationConfig(
            temperature: Float(scenario.backend.temperature ?? 0.0),
            topP: 0.9,
            repeatPenalty: 1.1,
            topK: scenario.backend.topK.map(Int32.init),
            typicalP: nil,
            maxOutputTokens: 1024,
            tools: tools,
            toolChoice: .auto,
            maxThinkingTokens: nil,
            jsonMode: false,
            thinkingMarkers: nil,
            maxToolIterations: maxIterations
        )
    }
}
