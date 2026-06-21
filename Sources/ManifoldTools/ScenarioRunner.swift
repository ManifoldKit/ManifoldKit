import Foundation
import ManifoldInference

/// Runs a single ``Scenario`` against a supplied ``InferenceService``.
///
/// The runner is the glue between the declarative scenario JSON and the
/// production inference path. It performs **one** ``InferenceService/enqueue``
/// per scenario turn and consumes the resulting ``GenerationStream`` end to
/// end. The orchestrator (`GenerationQueue` → `GenerationToolDispatchLoop`)
/// owns the tool loop entirely:
///
/// 1. It renders the prompt through `PromptRenderer` / `JinjaPromptRenderer`,
///    which is the only path that applies the chat template and injects the
///    tool definitions (`[AVAILABLE_TOOLS]` / native tool blocks). Local
///    backends never see that the tools exist otherwise (#1983).
/// 2. It dispatches each `.toolCall` the model emits through the
///    ``ToolRegistry`` carried by the service, re-generating to continue the
///    turn up to `config.maxToolIterations`.
/// 3. It emits `.toolCall` / `.toolResult` events back into the stream and a
///    terminal `.generationCompleted` event.
///
/// The runner therefore just observes the stream: it accumulates token text
/// for the final answer and reconstructs ``Outcome/toolCallsExecuted`` /
/// ``Outcome/toolResults`` from the `.toolCall` / `.toolResult` events. This
/// is deliberately the **real** orchestration path, not a parallel
/// hand-rolled tool loop — the whole point of the harness is to validate what
/// production does.
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

    /// The production inference service driving generation. It carries the
    /// ``ToolRegistry`` the orchestrator dispatches through, so the runner
    /// never dispatches tools itself.
    public let service: InferenceService
    public let logger: TranscriptLogger?
    public let maxIterations: Int

    /// The registry the service dispatches through. Used to derive the tool
    /// definitions advertised to the model for a given scenario.
    private var registry: ToolRegistry? { service.toolRegistry }

    public init(
        service: InferenceService,
        logger: TranscriptLogger? = nil,
        maxIterations: Int = 6
    ) {
        self.service = service
        self.logger = logger
        self.maxIterations = maxIterations
    }

    /// Executes a scenario. Errors bubble out; ``Outcome/passed`` captures
    /// the assertion verdict.
    public func run(_ scenario: Scenario) async throws -> Outcome {
        logger?.append(.prompt(scenarioId: scenario.id, system: scenario.systemPrompt, user: scenario.userPrompt))

        let messages: [StructuredMessage] = [
            StructuredMessage(role: "user", content: scenario.userPrompt)
        ]

        let allDefinitions = registry?.definitions ?? []
        let definitions = allDefinitions.filter {
            scenario.requiredTools.isEmpty || scenario.requiredTools.contains($0.name)
        }

        let config = makeConfig(for: scenario, tools: definitions)

        var accumulatedText = ""
        var toolCallsExecuted: [String] = []
        var toolResults: [ToolResultRecord] = []

        // Single enqueue through the production orchestrator. The dispatch
        // loop runs every tool iteration internally and surfaces each turn's
        // `.toolCall` / `.toolResult` events on this one stream — the runner
        // does not loop or dispatch.
        let (_, stream) = try service.enqueue(
            structuredMessages: messages,
            systemPrompt: scenario.systemPrompt,
            config: config
        )

        for try await event in stream.events {
            switch event {
            case .token(let text):
                accumulatedText += text
                logger?.append(.tokenDelta(scenarioId: scenario.id, text: text))

            case .toolCall(let call):
                toolCallsExecuted.append(call.toolName)
                logger?.append(.toolCall(scenarioId: scenario.id, name: call.toolName, arguments: call.arguments))

            case .toolResult(let result):
                toolResults.append(ToolResultRecord(
                    toolName: toolName(for: result, executed: toolCallsExecuted, recorded: toolResults),
                    content: result.content,
                    errorKind: result.errorKind?.rawValue
                ))
                logger?.append(.toolResult(
                    scenarioId: scenario.id,
                    name: toolResults.last?.toolName ?? "",
                    content: result.content,
                    errorKind: result.errorKind?.rawValue
                ))

            case .generationCompleted:
                // Terminal marker — the orchestrator finished the whole turn
                // (all tool iterations included). Stop consuming.
                break

            case .prefillProgress, .promptRendered, .usage, .thinkingToken,
                 .thinkingCompleted, .thinkingSignature, .kvCacheReuse,
                 .throttleDiagnostic, .toolCallStart, .toolCallArgumentsDelta,
                 .toolProgress, .toolDispatchStarted, .toolDispatchCompleted,
                 .toolCallApproved, .toolCallParseFailed, .toolCallTruncated,
                 .handoffRequested, .toolIterationLimitExceeded,
                 .runTokenBudgetExceeded:
                // Observational / lifecycle markers. Tool accounting flows
                // through `.toolCall` / `.toolResult`; the runner reconstructs
                // its Outcome from those alone. Stay exhaustive so a new
                // GenerationEvent case forces a compile error here.
                continue
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

    /// Resolves the tool name for a `.toolResult` event. ``ToolResult`` only
    /// carries the call id, not the tool name, so we recover the name by
    /// matching the result against the pending `.toolCall` events in dispatch
    /// order: the Nth recorded result corresponds to the Nth executed call.
    private func toolName(
        for result: ToolResult,
        executed: [String],
        recorded: [ToolResultRecord]
    ) -> String {
        let index = recorded.count
        if index < executed.count {
            return executed[index]
        }
        return executed.last ?? ""
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
