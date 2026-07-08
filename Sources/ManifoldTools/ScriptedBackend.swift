import Foundation
import ManifoldInference

/// A minimal scripted ``InferenceBackend`` that replays a pre-built list of
/// per-turn events so the harness can run end-to-end without a real model.
///
/// Each call to ``generate(prompt:systemPrompt:config:)`` pops the next turn
/// off the script and streams its events. When the script is exhausted an
/// empty stream terminates — the runner treats "no tokens, no tool calls" as
/// a final turn, so tests can rely on deterministic completion.
public final class ScriptedBackend: InferenceBackend, ConversationHistoryReceiver, @unchecked Sendable {

    public enum Turn: Sendable {
        case toolCall(name: String, arguments: String)
        case tokens([String])
        case mixed(tokens: [String], toolCalls: [(name: String, arguments: String)])
    }

    public var isModelLoaded: Bool = true
    public var isGenerating: Bool = false
    public var capabilities: BackendCapabilities

    private var turns: [Turn]
    private var cursor: Int = 0
    private var nextCallId: Int = 0
    public private(set) var receivedHistories: [[(role: String, content: String)]] = []
    /// Every `GenerationConfig` this backend was asked to `generate(...)` with,
    /// in call order — lets tests assert on config wiring (e.g. `seed`)
    /// without needing a real backend to observe it on the wire.
    public private(set) var receivedConfigs: [GenerationConfig] = []

    public init(turns: [Turn]) {
        self.turns = turns
        self.capabilities = BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false
        )
    }

    public func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        isModelLoaded = true
    }

    public func generate(prompt: String, systemPrompt: String?, config: GenerationConfig, hints: GenerationRuntimeHints) throws -> GenerationStream {
        receivedConfigs.append(config)
        let turn: Turn
        if cursor < turns.count {
            turn = turns[cursor]
            cursor += 1
        } else {
            // Empty terminal turn — runner treats this as "no more tool calls → stop".
            turn = .tokens([])
        }

        isGenerating = true
        let captured = turn

        let raw = AsyncThrowingStream<GenerationEvent, Error> { [self] continuation in
            Task {
                switch captured {
                case .toolCall(let name, let args):
                    let id = "scripted-\(nextCallId)"
                    nextCallId += 1
                    continuation.yield(.toolCall(ToolCall(id: id, toolName: name, arguments: args)))
                case .tokens(let tokens):
                    for t in tokens { continuation.yield(.token(t)) }
                case .mixed(let tokens, let toolCalls):
                    for t in tokens { continuation.yield(.token(t)) }
                    for tc in toolCalls {
                        let id = "scripted-\(nextCallId)"
                        nextCallId += 1
                        continuation.yield(.toolCall(ToolCall(id: id, toolName: tc.name, arguments: tc.arguments)))
                    }
                }
                self.isGenerating = false
                continuation.finish()
            }
        }
        return GenerationStream(raw)
    }

    public func stopGeneration() {
        isGenerating = false
    }

    public func unloadModel() {
        isModelLoaded = false
    }

    // MARK: - ConversationHistoryReceiver

    public func setConversationHistory(_ messages: [(role: String, content: String)]) {
        receivedHistories.append(messages)
    }
}
