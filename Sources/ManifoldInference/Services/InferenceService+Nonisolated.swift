import Foundation

// MARK: - Nonisolated wrappers for off-main runtime composition
//
// `InferenceService` is `@MainActor`-isolated for SwiftUI view binding.
// Phase 1.2 sub-step 5 (`ConversationRuntime`) needs to compose the same
// service from off-main contexts without forcing every call site to wrap
// the call in `await MainActor.run { ... }`.
//
// These wrappers expose `nonisolated` async entry points that hop to the
// main actor internally. The underlying coordinators stay `@MainActor` —
// only the boundary changes. Returned types (`BackendCapabilities`,
// `TokenizerProvider`, `GenerationRequestToken`, `GenerationStream`) are
// all already `Sendable`, so crossing the actor boundary is safe.
//
// This is additive. The existing `@MainActor` accessors and methods on
// `InferenceService` are unchanged; view code keeps working with the
// synchronous main-actor surface.

extension InferenceService {

    // MARK: Capabilities

    /// Off-main read of ``capabilities``.
    ///
    /// Use from non-`@MainActor` contexts (runtime use cases, background
    /// tasks). View code should keep using the synchronous ``capabilities``
    /// property — the values are identical.
    public nonisolated func capabilitiesAsync() async -> BackendCapabilities? {
        await MainActor.run { self.capabilities }
    }

    // MARK: Tokenizer

    /// Off-main read of ``tokenizer``.
    ///
    /// The returned ``TokenizerProvider`` is `Sendable`; callers may use it
    /// from any isolation domain after the call returns.
    public nonisolated func tokenizerAsync() async -> (any TokenizerProvider)? {
        await MainActor.run { self.tokenizer }
    }

    // MARK: Enqueue

    /// Off-main variant of ``enqueue(messages:systemPrompt:temperature:topP:repeatPenalty:maxOutputTokens:maxThinkingTokens:jsonMode:grammar:tools:toolChoice:maxToolIterations:priority:sessionID:)``.
    ///
    /// Hops to the main actor to invoke the queued enqueue path. The
    /// returned ``GenerationRequestToken`` and ``GenerationStream`` are both
    /// `Sendable` — callers can drive the stream from their own isolation
    /// domain.
    ///
    /// `messages` is taken as `[StructuredMessage]` to keep the off-main
    /// surface `Sendable`. The tuple-of-strings convenience overload on
    /// the synchronous ``enqueue`` is for view-side ergonomics; runtime
    /// callers always have a structured representation already.
    public nonisolated func enqueueAsync(
        structuredMessages messages: [StructuredMessage],
        systemPrompt: String? = nil,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        maxOutputTokens: Int? = 2048,
        maxThinkingTokens: Int? = nil,
        jsonMode: Bool = false,
        grammar: String? = nil,
        tools: [ToolDefinition] = [],
        toolChoice: ToolChoice = .auto,
        maxToolIterations: Int = 10,
        priority: GenerationPriority = .normal,
        sessionID: UUID? = nil,
        handoffDetector: (@Sendable (UUID?, ToolCall) -> HandoffDetectionResult)? = nil,
        preToolUseHook: PreToolUseHook? = nil
    ) async throws -> (token: GenerationRequestToken, stream: GenerationStream) {
        try await MainActor.run {
            try self.enqueue(
                structuredMessages: messages,
                systemPrompt: systemPrompt,
                config: GenerationQueue.makeEnqueueConfig(
                    temperature: temperature,
                    topP: topP,
                    repeatPenalty: repeatPenalty,
                    topK: nil,
                    minP: nil,
                    presencePenalty: nil,
                    frequencyPenalty: nil,
                    seed: nil,
                    maxOutputTokens: maxOutputTokens,
                    maxThinkingTokens: maxThinkingTokens,
                    jsonMode: jsonMode,
                    grammar: grammar,
                    tools: tools,
                    toolChoice: toolChoice,
                    maxToolIterations: maxToolIterations
                ),
                priority: priority,
                sessionID: sessionID,
                handoffDetector: handoffDetector,
                preToolUseHook: preToolUseHook
            )
        }
    }

    /// Off-main cancellation by token.
    ///
    /// Mirrors ``cancel(_:)`` from a non-`@MainActor` context. Provided so
    /// runtime use cases can drive cancellation alongside ``enqueueAsync``
    /// without splitting the lifecycle across two isolation domains.
    public nonisolated func cancelAsync(_ token: GenerationRequestToken) async {
        await MainActor.run { self.cancel(token) }
    }
}
