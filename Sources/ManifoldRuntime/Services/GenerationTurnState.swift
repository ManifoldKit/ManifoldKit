import Foundation
import ManifoldInference

// Phase-boundary value types for ``ConversationTurnExecutor/runGenerationTurn``.
//
// `runGenerationTurn` was historically one ~688-line method that ran eight
// phases inline against a wall of local `var`s. These types make the phase
// boundaries explicit: each phase is now a `func` with named inputs and one
// of these as its output (or threaded through as `inout` for the drain →
// finalise → post-turn handoff). They carry no behaviour — only state — so
// the decomposition stays a pure refactor.

/// Output of the pre-assembly history-preparation phase. Carries the prompt-
/// visible history after host shaping + additive history providers plus the
/// resolved turn context snapshot used by downstream prompt assembly and
/// post-generation hooks.
///
/// `package` so ``TurnPreparation/prepareHistory`` can surface it across the
/// package boundary used by direct unit tests (#1957 Priority 3).
package struct PreparedTurnHistory: Sendable {
    package var history: [ChatMessage]
    package var turnContext: TurnContext

    package init(history: [ChatMessage], turnContext: TurnContext) {
        self.history = history
        self.turnContext = turnContext
    }
}

/// Output of phase 1 (context assembly). Carries the assembled prompt slots,
/// any RAG citations, the once-per-turn session snapshot, and the host-mutable
/// bindings snapshot (tool sources + hook registry) read at the top of the
/// turn so a concurrent host reconfiguration only takes effect next turn.
struct AssembledContext {
    var slots: [PromptSlot]
    var ragCitations: [Citation]
    var sessionRecord: ChatSession?
    var turnSessionToolSources: [any SessionToolSource]
    var turnHookRegistry: HookRegistry?
}

/// Output of phase 2 (turn setup). Everything `enqueueAsync` needs plus the
/// pre-built assistant message slot whose `id` token deltas reference from the
/// first emitted token.
struct GenerationPlan {
    var composedSystemPrompt: String?
    var structuredHistory: [StructuredMessage]
    var advertisedTools: [ToolDefinition]
    var assistantMessage: ChatMessage
    /// Per-request handoff detector for this turn, passed into `enqueueAsync`
    /// rather than mutated onto the shared `InferenceService`. Threading it per
    /// request closes the race where two concurrent turns clobbered the
    /// service-global detector between set and stream consumption (#1494).
    /// `nil` for sessionless / single-agent turns.
    var handoffDetector: (@Sendable (UUID?, ToolCall) -> HandoffDetectionResult)?
    /// Per-request pre-tool-use hook for this turn. See ``handoffDetector`` for
    /// the rationale. `nil` when no host hook registry is wired.
    var preToolUseHook: PreToolUseHook?
}

/// The enqueued backend request: the cancellation token and the event stream
/// to drain.
struct EnqueuedGeneration {
    var token: InferenceService.GenerationRequestToken
    var stream: GenerationStream
}

/// Mutable per-turn state threaded by `inout` through the drain →
/// finalise phases. `assistantMessage` accumulates tool-call / tool-result
/// content parts during the drain; `sessionRecord` is updated in place on a
/// mid-stream agent handoff; `accumulated` collects flushed token batches;
/// `streamFailed` is set when the stream throws (cancellation or inference
/// error); `tokenUsage` captures a `recordUsage` event if the backend emits
/// one inline.
struct GenerationTurnState {
    var accumulated: String = ""
    var emptyResponse: Bool = true
    var streamFailed: ConversationError?
    var tokenUsage: (promptTokens: Int, completionTokens: Int)?
    var assistantMessage: ChatMessage
    var sessionRecord: ChatSession?
}

/// Output of phase 4 (finalisation), returned only on the happy path. Carries
/// the resolved token usage forward to post-turn effects so usage recording
/// and compression don't re-read it.
struct FinalizedTurn {
    var usage: (promptTokens: Int, completionTokens: Int)?
}
