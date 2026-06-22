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

    /// When `true`, ALL tools in the registry are advertised to the model on
    /// every generation — not just the subset named in `scenario.requiredTools`.
    /// Set this to enable distractor-pressure testing: extra decoy tools are
    /// registered in the registry and included in the prompt so the model must
    /// identify the correct tool among irrelevant ones.
    ///
    /// Assertions still check only `scenario.requiredTools`; extra tools never
    /// affect scoring.
    public let passAllRegisteredTools: Bool

    public init(
        service: InferenceService,
        logger: TranscriptLogger? = nil,
        maxIterations: Int = 6,
        passAllRegisteredTools: Bool = false
    ) {
        self.service = service
        self.logger = logger
        self.maxIterations = maxIterations
        self.passAllRegisteredTools = passAllRegisteredTools
    }

    /// Executes a scenario. Errors bubble out; ``Outcome/passed`` captures
    /// the assertion verdict.
    public func run(_ scenario: Scenario) async throws -> Outcome {
        // Defer the advertisedTools list until after we know which definitions
        // we're forwarding, so we log them below after the definitions are resolved.

        let messages: [StructuredMessage] = [
            StructuredMessage(role: "user", content: scenario.userPrompt)
        ]

        let allDefinitions = registry?.definitions ?? []
        // When passAllRegisteredTools is true (decoy-pressure mode) every
        // registered tool is advertised to the model so distractors are visible.
        // Otherwise only required tools are forwarded — preserves the baseline
        // semantics where decoys can't accidentally inflate recall denominators.
        let definitions: [ToolDefinition]
        if passAllRegisteredTools {
            definitions = allDefinitions
        } else {
            definitions = allDefinitions.filter {
                scenario.requiredTools.isEmpty || scenario.requiredTools.contains($0.name)
            }
        }

        logger?.append(.prompt(
            scenarioId: scenario.id,
            system: scenario.systemPrompt,
            user: scenario.userPrompt,
            requiredTools: scenario.requiredTools,
            advertisedTools: definitions.map(\.name)
        ))

        let config = makeConfig(for: scenario, tools: definitions)

        var accumulatedText = ""
        var toolCallsExecuted: [String] = []
        var toolResults: [ToolResultRecord] = []
        // `.toolResult` carries only the call id (not the tool name), so map
        // each result back to its originating `.toolCall` by id. This is robust
        // to any short-circuit path (cancellation/byte-budget) that emits a
        // result whose position doesn't line up with the call ordinal.
        var toolNameByCallID: [String: String] = [:]

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
                toolNameByCallID[call.id] = call.toolName
                logger?.append(.toolCall(scenarioId: scenario.id, name: call.toolName, arguments: call.arguments))

            case .toolResult(let result):
                let name = toolNameByCallID[result.callId] ?? ""
                toolResults.append(ToolResultRecord(
                    toolName: name,
                    content: result.content,
                    errorKind: result.errorKind?.rawValue
                ))
                logger?.append(.toolResult(
                    scenarioId: scenario.id,
                    name: name,
                    content: result.content,
                    errorKind: result.errorKind?.rawValue
                ))

            case .generationCompleted:
                // Terminal marker — the orchestrator finished the whole turn
                // (all tool iterations included); the stream finishes right
                // after, so the `for await` loop ends on its own.
                continue

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
