import Foundation

/// Transforms raw ``GenerationEvent`` values into UI-actionable commands.
///
/// Extracted from `ChatViewModel+Generation` so the event→action mapping
/// can be tested without SwiftData, `@MainActor`, or any UI state.
public struct GenerationStreamConsumer: Sendable {

    /// Whether to check for repetitive looping in appended text.
    public var loopDetectionEnabled: Bool

    public init(loopDetectionEnabled: Bool = true) {
        self.loopDetectionEnabled = loopDetectionEnabled
    }

    /// Processes a single generation event and returns the action the caller should take.
    public mutating func handle(_ event: GenerationEvent) -> StreamAction {
        switch event {
        case .prefillProgress:
            return .ignore

        case .token(let text):
            return .appendText(text)

        case .usage(let prompt, let completion):
            return .recordUsage(prompt: prompt, completion: completion)

        case .toolCall(let call):
            return .dispatchToolCall(call)

        case .thinkingToken(let text):
            return .appendThinkingText(text)

        case .thinkingComplete:
            return .finalizeThinking

        case .thinkingSignature(let signature):
            return .recordThinkingSignature(signature)

        case .toolResult(let result):
            return .appendToolResult(result)

        case .toolLoopLimitReached(let iterations):
            return .toolLoopLimitReached(iterations: iterations)

        case .kvCacheReuse:
            return .ignore

        case .diagnosticThrottle:
            // Throttle hints are advisory metadata; the consumer has no
            // text/usage state to mutate. UI surfaces that want to render
            // a "paused — device throttling" badge observe the raw event
            // upstream instead of going through the action mapping.
            return .ignore

        case .toolCallStart, .toolCallArgumentsDelta:
            // Streaming tool-call deltas are observed by UI surfaces
            // upstream (rendering an in-flight call card). The
            // GenerationStreamConsumer drives chat-message text/thinking
            // state and has nothing to do for the deltas — the
            // authoritative arguments string lands on `.toolCall(_:)`,
            // which `dispatchToolCall` already handles.
            return .ignore

        case .toolDispatchStarted, .toolDispatchCompleted:
            // Lifecycle metadata for UI timers / spinners; consumed
            // directly by surfaces that want to render duration / error
            // kind. The chat-message state mapping has no work here —
            // text and tool-result accumulation are driven by the
            // existing `.toolCall` / `.toolResult` events.
            return .ignore
        }
    }

    /// Checks whether the accumulated content looks like a repetition loop.
    ///
    /// Call this after processing `.appendText` actions once enough content
    /// has been accumulated (the caller decides the threshold).
    public func shouldStopForLoop(content: String) -> Bool {
        guard loopDetectionEnabled else { return false }
        guard content.count >= 100 else { return false }
        return RepetitionDetector.looksLikeLooping(content)
    }

    /// Actions the caller should take in response to a generation event.
    public enum StreamAction: Equatable, Sendable {
        /// Append the text to the current assistant message.
        case appendText(String)
        /// Record token usage on the current assistant message.
        case recordUsage(prompt: Int, completion: Int)
        /// Execute the requested tool call and feed a ``ToolResult`` back into the conversation.
        case dispatchToolCall(ToolCall)
        /// Append the text to the current thinking accumulation buffer.
        case appendThinkingText(String)
        /// Reasoning block complete — finalize and store the accumulated thinking content.
        case finalizeThinking
        /// Provider attached an opaque signature to the in-flight thinking
        /// block. Caller stashes it so the next ``finalizeThinking`` writes
        /// a ``MessagePart/thinking(_:signature:)`` carrying the signature
        /// verbatim, enabling multi-turn replay against APIs that require
        /// it (Anthropic).
        case recordThinkingSignature(String)
        /// Append a dispatched ``ToolResult`` to the current assistant message's parts.
        case appendToolResult(ToolResult)
        /// The orchestrator stopped the tool-dispatch loop because the
        /// ``GenerationConfig/maxToolIterations`` budget was exhausted.
        case toolLoopLimitReached(iterations: Int)
        /// The backend reused a KV-cache prefix from the previous turn; no UI action needed.
        case ignore
    }
}
