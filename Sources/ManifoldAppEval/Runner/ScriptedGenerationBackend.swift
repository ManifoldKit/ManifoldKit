import Foundation
import ManifoldInference

/// A turn-by-turn ``InferenceBackend`` whose event sequence is fully
/// scripted. Each call to `generate` pops the next ``TurnScript`` and
/// emits its ``ScriptedEvent`` values in order.
///
/// Use `ScriptedGenerationBackend` when you need deterministic control
/// over ``GenerationEvent`` values that real backends only produce under
/// specific conditions — KV-cache reuse hits, throttle signals, partial
/// thinking blocks, mid-stream errors — and you want to assert the
/// runtime's handling via ``ConversationEventRecorder`` +
/// ``XCTAssertEventSubsequence``.
///
/// ## Basic usage
///
/// ```swift
/// let backend = ScriptedGenerationBackend(turns: [
///     .kvCacheReuse(reuseCount: 256, then: ["Hello", " world"]),
///     .tokens(["Follow", "-up"]),
/// ])
/// ```
///
/// ## Thread safety
///
/// `ScriptedGenerationBackend` is `@unchecked Sendable` — the same pattern
/// used by ``MockInferenceBackend`` in this module. An `NSLock` serialises
/// all reads and writes to `turns`, `cursor`, and `generateCallCount`.
/// `isGenerating` and `isModelLoaded` are unsynchronised because they are
/// used only for assertion purposes in tests, not for safety-critical paths.
public final class ScriptedGenerationBackend: InferenceBackend, @unchecked Sendable {

    // MARK: - Types

    /// One turn's event sequence.
    public struct TurnScript: Sendable {
        public let events: [ScriptedEvent]

        public init(_ events: [ScriptedEvent]) {
            self.events = events
        }

        // MARK: Convenience factories

        /// Emits plain text tokens and finishes normally.
        public static func tokens(_ tokens: [String]) -> TurnScript {
            TurnScript(tokens.map { .emit(.token($0)) })
        }

        /// Emits a `kvCacheReuse` event followed by text tokens.
        public static func kvCacheReuse(reuseCount: Int, then tokens: [String]) -> TurnScript {
            var events: [ScriptedEvent] = [.emit(.kvCacheReuse(promptTokensReused: reuseCount))]
            events += tokens.map { .emit(.token($0)) }
            return TurnScript(events)
        }

        /// Emits a `throttleDiagnostic` event followed by text tokens.
        public static func throttle(reason: String, then tokens: [String]) -> TurnScript {
            var events: [ScriptedEvent] = [.emit(.throttleDiagnostic(reason: reason))]
            events += tokens.map { .emit(.token($0)) }
            return TurnScript(events)
        }

        /// Emits a `usage` event followed by text tokens.
        public static func withUsage(prompt: Int, completion: Int, tokens: [String]) -> TurnScript {
            var events: [ScriptedEvent] = [.emit(.usage(TokenUsage(promptTokens: prompt, completionTokens: completion)))]
            events += tokens.map { .emit(.token($0)) }
            return TurnScript(events)
        }

        /// Throws `error` mid-stream after emitting `afterTokens` tokens from `tokens`.
        public static func failMidStream(_ error: Error, afterTokens: Int = 0, tokens: [String] = []) -> TurnScript {
            var events: [ScriptedEvent] = Array(tokens.prefix(afterTokens).map { .emit(.token($0)) })
            events.append(.throwError(error))
            return TurnScript(events)
        }

        /// Emits a single model-requested tool call and finishes — no visible
        /// text. The runtime's tool-dispatch loop executes the call through the
        /// registered ``ToolRegistry`` and re-prompts the backend, which then
        /// pops the *next* ``TurnScript`` in the queue for the follow-up round.
        ///
        /// A complete tool round trip is therefore two scripts:
        /// ```swift
        /// [.toolCall(ToolCall(id: "t1", toolName: "echo", arguments: "{}")),
        ///  .tokens(["Done"])]
        /// ```
        public static func toolCall(_ call: ToolCall) -> TurnScript {
            TurnScript([.emit(.toolCall(call))])
        }

        /// Empty turn — stream finishes with no events. The runtime treats
        /// this as a no-content response.
        public static var empty: TurnScript { TurnScript([]) }
    }

    /// A single scripted step within a ``TurnScript``.
    public enum ScriptedEvent: Sendable {
        /// Yield this ``GenerationEvent`` into the stream.
        case emit(GenerationEvent)
        /// Throw this error into the stream (terminates the turn).
        case throwError(Error)
        /// Sleep before the next event (keep <= 100 ms in tests).
        case delay(Duration)
    }

    // MARK: - InferenceBackend conformance

    public var isModelLoaded: Bool = true
    public var isGenerating: Bool = false
    public var capabilities: BackendCapabilities

    /// Optional per-token emission gate. When non-nil, the backend awaits
    /// ``AppEvalTokenEmissionGate/waitForAdvance()`` BEFORE yielding each
    /// `.token(_:)` event. The driver releases tokens one at a time so a
    /// scenario can deterministically cancel a turn after observing exactly N
    /// `.tokenEmitted` events — without racing the unbounded stream buffer that
    /// would otherwise let the terminal `streamFinished(.stop)` overtake the
    /// cancel call. Mirrors ``MockInferenceBackend/tokenEmissionGate`` in
    /// `ManifoldTestSupport` (a deliberately separate type — see
    /// ``AppEvalTokenEmissionGate``'s doc comment).
    ///
    /// Captured into a local at `generate` entry, so clearing it after a turn
    /// does not disturb an in-flight turn.
    public var tokenEmissionGate: AppEvalTokenEmissionGate?

    /// The number of `generate` calls made so far.
    public private(set) var generateCallCount: Int = 0

    // NSLock serialises mutations to `turns`, `cursor`, and `generateCallCount`.
    private let lock = NSLock()
    private var turns: [TurnScript]
    private var cursor: Int = 0

    public init(turns: [TurnScript] = [], capabilities: BackendCapabilities? = nil) {
        self.turns = turns
        self.capabilities = capabilities ?? BackendCapabilities(
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

    public func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
        let script = nextTurn()
        isGenerating = true

        // Snapshot the gate at entry so a later turn clearing the property does
        // not retroactively un-gate this in-flight turn.
        let emissionGate = tokenEmissionGate

        let (raw, continuation) = AsyncThrowingStream<GenerationEvent, Error>.makeStream()
        Task { [weak self] in
            for event in script.events {
                switch event {
                case .emit(let generationEvent):
                    // Gate visible-token emission so a cancellation driver can
                    // release exactly N tokens before issuing cancel.
                    if case .token = generationEvent, let gate = emissionGate {
                        await gate.waitForAdvance()
                    }
                    continuation.yield(generationEvent)
                case .throwError(let error):
                    self?.isGenerating = false
                    continuation.finish(throwing: error)
                    return
                case .delay(let duration):
                    do {
                        try await Task.sleep(for: duration)
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
            }
            self?.isGenerating = false
            continuation.finish()
        }
        return GenerationStream(raw)
    }

    public func stopGeneration() {
        isGenerating = false
    }

    public func unloadModel() {
        isModelLoaded = false
    }

    // MARK: - Script management

    /// Appends additional turns to the script at runtime.
    public func appendTurns(_ newTurns: [TurnScript]) {
        lock.withLock { turns.append(contentsOf: newTurns) }
    }

    /// Resets the cursor to turn 0 without clearing the script.
    public func reset() {
        lock.withLock { cursor = 0 }
    }

    private func nextTurn() -> TurnScript {
        lock.withLock {
            generateCallCount += 1
            if cursor < turns.count {
                let t = turns[cursor]
                cursor += 1
                return t
            }
            return .empty
        }
    }
}
