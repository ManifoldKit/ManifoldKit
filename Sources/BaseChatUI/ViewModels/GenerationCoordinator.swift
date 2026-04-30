import Foundation
import BaseChatRuntime
import BaseChatInference

// StreamingTokenBatcher was moved to BaseChatInference/Services/StreamingTokenBatcher.swift
// so that ConversationRuntime (in BaseChatCore) can share the same type.

// File-private top-level — nonisolated, initialized once, thread-safe.
// Kept outside the @MainActor-isolated GenerationCoordinator so that
// nonisolated `applySystemPromptContext` can access it without a Swift 6
// actor-isolation warning.
private let _systemPromptContextRegex: NSRegularExpression = {
    // Force-unwrap is safe: the pattern is a compile-time constant with no user input.
    try! NSRegularExpression(pattern: #"\{\{(\w+)\}\}"#, options: [])
}()

// MARK: - GenerationCoordinator

/// Owns the token-streaming loop extracted from `ChatViewModel` (phase 4 of #329).
///
/// The coordinator is `@MainActor` but NOT `@Observable` — it holds no
/// SwiftUI-observed state of its own. All observable side-effects are routed
/// back to `ChatViewModel` through the callback seams set at construction.
@MainActor
final class GenerationCoordinator {

    // MARK: - Read Seams

    /// Returns the current snapshot of messages (all messages, not filtered).
    var messages: () -> [ChatMessageRecord] = { [] }

    /// Returns the current system prompt string.
    var systemPrompt: () -> String = { "" }

    /// Returns the current system prompt context dictionary.
    var systemPromptContext: () -> [String: String] = { [:] }

    /// Returns the current max token budget.
    var contextMaxTokens: () -> Int = { 2048 }

    /// Returns the configured cap on visible output tokens, or `nil` for "no explicit cap".
    ///
    /// Wired from `ChatViewModel.maxOutputTokens`. Used by ``trimMessages`` to
    /// reserve context for the model's response so the prompt is trimmed
    /// aggressively enough to leave room for it.
    var maxOutputTokens: () -> Int? = { 2048 }

    /// Returns the configured cap on reasoning tokens, or `nil` for "no explicit cap".
    ///
    /// Wired from `ChatViewModel.maxThinkingTokens`. A `nil` value means the
    /// trim math reserves zero thinking tokens — see issue #587 for why this
    /// is opt-in rather than a backend default.
    var maxThinkingTokens: () -> Int? = { nil }

    /// Returns the current temperature setting.
    var temperature: () -> Float = { 0.7 }

    /// Returns the current top-P setting.
    var topP: () -> Float = { 0.9 }

    /// Returns the current repeat penalty setting.
    var repeatPenalty: () -> Float = { 1.0 }

    /// Returns the active session ID, or nil if no session is selected.
    var activeSessionID: () -> UUID? = { nil }

    /// Returns whether loop detection is enabled.
    var loopDetectionEnabled: () -> Bool = { true }

    /// Returns the streaming update interval.
    var streamingUpdateInterval: () -> Duration = { .milliseconds(33) }

    /// Returns the streaming batch character limit.
    var streamingBatchCharacterLimit: () -> Int = { 128 }

    /// Returns the streaming update interval for reasoning tokens.
    var thinkingStreamingUpdateInterval: () -> Duration = { .milliseconds(33) }

    /// Returns the streaming batch character limit for reasoning tokens.
    var thinkingStreamingBatchCharacterLimit: () -> Int = { 128 }

    /// Returns the active backend name, or nil if none.
    var activeBackendName: () -> String? = { nil }

    /// Returns the active session record, or nil.
    var activeSession: () -> ChatSessionRecord? = { nil }

    /// Returns the registered post-generation tasks.
    var postGenerationTasks: () -> [any PostGenerationTask] = { [] }

    /// Returns the reusable caching tokenizer.
    var reusableCachingTokenizer: () -> CachingTokenizer

    /// Returns whether the upgrade hint has already been shown.
    var showUpgradeHint: () -> Bool = { false }

    // MARK: - Write-back Seams

    /// Forwards to `ChatViewModel.transitionPhase(to:)`. Returns `true` if accepted.
    var onTransitionPhase: (BackendActivityPhase) -> Bool = { _ in false }

    /// Surfaces a structured error on the view model.
    var onSurfaceError: (any Error, ChatError.Kind, String?) -> Void = { _, _, _ in }

    /// Sets `ChatViewModel.errorMessage` to an optional string.
    var onSetErrorMessage: (String?) -> Void = { _ in }

    /// Forwards to `ChatViewModel.mutateMessage(id:_:)`.
    var onMutateMessage: (UUID, (inout ChatMessageRecord) -> Void) -> Void = { _, _ in }

    /// Sets `ChatViewModel.activeGenerationToken`.
    var onSetActiveGenerationToken: (InferenceService.GenerationRequestToken?) -> Void = { _ in }

    /// Sets `ChatViewModel.generationTask`.
    var onSetGenerationTask: (Task<Void, Never>?) -> Void = { _ in }

    /// Sets `ChatViewModel.backgroundTask`.
    var onSetBackgroundTask: (Task<Void, Never>?) -> Void = { _ in }

    /// Sets `ChatViewModel.backgroundTaskError`.
    var onSetBackgroundTaskError: (Error?) -> Void = { _ in }

    /// Sets `ChatViewModel.showUpgradeHint`.
    var onSetShowUpgradeHint: (Bool) -> Void = { _ in }

    /// Called when the upgrade hint is first triggered. Optional.
    var onUpgradeHintTriggered: (() -> Void)?

    /// Triggers a context estimate update on the view model.
    var onUpdateContextEstimate: () -> Void = {}

    /// Persists a completed message.
    var onSaveMessage: (ChatMessageRecord) async throws -> Void = { _ in }

    /// Removes an assistant message from the view model (called for empty responses).
    var onRemoveMessage: (UUID) -> Void = { _ in }

    /// Notifies the view model that the given message has started or finished
    /// streaming reasoning text. The UI uses this to switch between the
    /// "Thinking… <preview>" affordance and the finalized disclosure group.
    var onMarkThinkingStreaming: (UUID, Bool) -> Void = { _, _ in }

    // MARK: - Dependencies

    private let inferenceService: InferenceService

    // MARK: - Init

    init(
        inferenceService: InferenceService,
        reusableCachingTokenizer: @escaping () -> CachingTokenizer
    ) {
        self.inferenceService = inferenceService
        self.reusableCachingTokenizer = reusableCachingTokenizer
    }

    // MARK: - Public Interface

    /// Streams tokens from the inference service into an assistant message.
    ///
    /// Handles context trimming, token usage capture, empty response cleanup,
    /// and the Foundation model upgrade hint.
    func generate(into assistantMessage: ChatMessageRecord) async {
        onSetBackgroundTaskError(nil)
        _ = onTransitionPhase(.waitingForFirstToken)
        let messageID = assistantMessage.id
        var didEnqueue = false
        defer {
            // Only update state if we actually started a generation. If enqueue()
            // threw (e.g. queue full), activeGenerationToken is nil and we should
            // not touch anyone else's active request.
            if didEnqueue {
                onSetActiveGenerationToken(nil)
                // InferenceService auto-drains when our stream terminates, so by
                // the time this defer fires the next request (if any) is already
                // active. Only go idle if the service is no longer running anything
                // — staying in .streaming would lie about UI state if we own the
                // active gen, but going idle would lie if a sibling consumer's
                // request just took over.
                if !inferenceService.isGenerating {
                    _ = onTransitionPhase(.idle)
                }
            } else {
                _ = onTransitionPhase(.idle)
            }
        }

        do {
            // Build the message history, trimming to fit the context window.
            let allMessages = messages().filter { $0.id != messageID }
            let prompt = systemPrompt()
            let rawSystemPrompt = prompt.isEmpty ? nil : prompt
            let effectiveSystemPrompt: String? = rawSystemPrompt.map { prompt in
                Self.applySystemPromptContext(prompt, context: systemPromptContext())
            }
            // Reuse the persistent caching tokenizer — token counts for unchanged
            // messages carry over between generation cycles.
            let cachingTokenizer: TokenizerProvider = reusableCachingTokenizer()

            // Reserve context for the model's visible response and (optionally)
            // its reasoning tokens. `maxThinkingTokens == nil` reserves zero
            // rather than a default slice so non-thinking models don't silently
            // lose 2048 tokens of prompt to a reservation they won't use. See
            // issue #587 and the reservation-policy memo on
            // ``ContextWindowManager`` for the full rationale.
            let visibleReserve = maxOutputTokens() ?? 2048
            let thinkingReserve = maxThinkingTokens() ?? 0
            let responseBuffer = visibleReserve + thinkingReserve

            let trimmed = ContextWindowManager.trimMessages(
                allMessages,
                systemPrompt: effectiveSystemPrompt,
                maxTokens: contextMaxTokens(),
                responseBuffer: responseBuffer,
                tokenizer: cachingTokenizer
            )
            // Build structured history that carries thinking signatures
            // through to backends with structured wire formats (Anthropic).
            // Text-only backends collapse this back to (role, content) at
            // their own boundary via ``StructuredMessage/textContent``.
            let history: [StructuredMessage] = trimmed.map {
                StructuredMessage(role: $0.role.rawValue, parts: $0.contentParts)
            }

            // Surface the registered tool definitions so the model can call
            // them. Without this, tools registered on `InferenceService.toolRegistry`
            // are never advertised to the backend and the model — correctly —
            // refuses to call something it doesn't know about.
            let registeredTools = inferenceService.toolRegistry?.definitions ?? []

            let (token, stream) = try inferenceService.enqueue(
                structuredMessages: history,
                systemPrompt: effectiveSystemPrompt,
                temperature: temperature(),
                topP: topP(),
                repeatPenalty: repeatPenalty(),
                maxOutputTokens: maxOutputTokens(),
                maxThinkingTokens: maxThinkingTokens(),
                tools: registeredTools,
                toolChoice: .auto,
                priority: .userInitiated,
                sessionID: activeSessionID()
            )
            onSetActiveGenerationToken(token)
            didEnqueue = true

            var tokenCount = 0
            // GenerationStream.phase tracks backend-level lifecycle (connecting, streaming, stalled, retrying).
            // ChatViewModel.activityPhase tracks UI-level state (waitingForFirstToken, streaming, idle).
            // These are intentionally separate: activityPhase drives UI chrome, stream.phase drives
            // reliability indicators. A future PR may unify them.
            let task = Task { [weak self] in
                guard let self else { return }
                var batcher = StreamingTokenBatcher(
                    interval: self.streamingUpdateInterval(),
                    maxBufferedCharacters: self.streamingBatchCharacterLimit()
                )
                var thinkingBatcher = StreamingTokenBatcher(
                    interval: self.thinkingStreamingUpdateInterval(),
                    maxBufferedCharacters: self.thinkingStreamingBatchCharacterLimit()
                )
                var consumer = GenerationStreamConsumer(loopDetectionEnabled: self.loopDetectionEnabled())
                var thinkingAccumulator = ""
                // Tracks the text already flushed to the thinking part so partial
                // updates can append rather than overwrite. Reset on finalize so
                // a subsequent <think>…</think> block in the same response starts
                // a fresh accumulator.
                var thinkingDisplayed = ""
                // Most recent provider-supplied signature for the in-flight
                // reasoning block. Set by ``recordThinkingSignature`` actions
                // (Anthropic emits via `signature_delta`); consumed by the
                // next ``finalizeThinking`` so the persisted
                // ``MessagePart/thinking`` carries the signature for
                // multi-turn replay.
                var pendingThinkingSignature: String?

                do {
                    eventLoop: for try await event in stream.events {
                        if Task.isCancelled { break }

                        switch consumer.handle(event) {
                        case .appendText(let token):
                            tokenCount += 1
                            if tokenCount == 1 {
                                _ = self.onTransitionPhase(.streaming)
                            }
                            if let batch = batcher.append(token, now: ContinuousClock.now) {
                                var looping = false
                                self.onMutateMessage(messageID) { msg in
                                    Self.appendVisibleText(batch, into: &msg)
                                    if consumer.shouldStopForLoop(content: msg.content) {
                                        looping = true
                                    }
                                }
                                if looping {
                                    self.inferenceService.stopGeneration()
                                    self.onSetErrorMessage("Generation stopped: the model appears to be repeating itself.")
                                    break eventLoop
                                }
                            }

                        case .recordUsage(let prompt, let completion):
                            self.onMutateMessage(messageID) { msg in
                                msg.promptTokens = prompt
                                msg.completionTokens = completion
                            }

                        case .dispatchToolCall(let call):
                            // Tool execution itself is a host-app concern; ChatViewModel does
                            // not implement a tool dispatch loop. But the UI needs the call
                            // persisted in contentParts so ``MessagePartsView`` can pair the
                            // later ``.toolResult`` with the originating call (and render a
                            // named "completed" disclosure instead of an opaque callId).
                            // ``InferenceService.GenerationCoordinator`` dispatches through
                            // its ``ToolRegistry`` and emits the result downstream; that
                            // event lands on the ``appendToolResult`` branch below.
                            self.onMutateMessage(messageID) { msg in
                                msg.contentParts.append(.toolCall(call))
                            }

                        case .appendThinkingText(let text):
                            let isFirstThinkingFragment = thinkingAccumulator.isEmpty
                            thinkingAccumulator += text
                            if isFirstThinkingFragment {
                                // Insert a placeholder `.thinking("")` part immediately so the
                                // UI can render the "Thinking…" label during the reasoning phase
                                // rather than staying on the generic typing placeholder. The
                                // placeholder is the *most recent* thinking-shaped part —
                                // partial flushes and the next finalize target it via
                                // `lastIndex(where:)` so multiple thinking blocks within one
                                // response stay separate. (#604: signatures are per-block.)
                                self.onMarkThinkingStreaming(messageID, true)
                                self.onMutateMessage(messageID) { msg in
                                    let insertAt = msg.contentParts.firstIndex(where: { $0.textContent != nil }) ?? msg.contentParts.endIndex
                                    msg.contentParts.insert(.thinking(""), at: insertAt)
                                }
                            }
                            // Flush partial reasoning text into the thinking part on the
                            // configured cadence so the user sees live progress instead of
                            // a frozen "Thinking…" label.
                            if let batch = thinkingBatcher.append(text, now: ContinuousClock.now) {
                                thinkingDisplayed += batch
                                let displayed = thinkingDisplayed
                                self.onMutateMessage(messageID) { msg in
                                    Self.writeThinkingPartialText(displayed, into: &msg)
                                }
                                if consumer.shouldStopForLoop(content: thinkingAccumulator) {
                                    self.inferenceService.stopGeneration()
                                    self.onSetErrorMessage("Generation stopped: the model appears to be looping in its reasoning.")
                                    break eventLoop
                                }
                            }

                        case .recordThinkingSignature(let signature):
                            // Stash the provider-supplied signature; the next
                            // `.finalizeThinking` writes it onto the in-flight
                            // thinking part. Anthropic emits this between
                            // `content_block_start` and the first `thinking_delta`,
                            // so the placeholder may not exist yet — that's fine,
                            // we apply at finalize time regardless of order.
                            pendingThinkingSignature = signature

                        case .finalizeThinking:
                            // Drain any buffered partial fragments first so we don't
                            // miss display content on tight streams that finish before
                            // the batcher's interval elapses.
                            if let batch = thinkingBatcher.flush(now: ContinuousClock.now) {
                                thinkingDisplayed += batch
                            }
                            let block = thinkingAccumulator
                            let signature = pendingThinkingSignature
                            thinkingAccumulator = ""
                            thinkingDisplayed = ""
                            pendingThinkingSignature = nil
                            self.onMarkThinkingStreaming(messageID, false)
                            guard !block.isEmpty else { break }
                            self.onMutateMessage(messageID) { msg in
                                // Each finalize creates a fresh part rather than
                                // merging with prior thinking parts. This preserves
                                // per-block signatures (Anthropic issues one per
                                // `content_block_start{type:"thinking"}`) and keeps
                                // multiple reasoning rounds within one response
                                // visually distinct in MessagePartsView.
                                //
                                // The placeholder for the *current* block is the
                                // last `.thinking` part in the array — partial
                                // flushes have been writing into it. Convert that
                                // placeholder to the final text + signature; if no
                                // placeholder exists (e.g. signature arrived after
                                // a synthetic finalize), insert one ahead of text.
                                if let idx = msg.contentParts.lastIndex(where: { $0.thinkingContent != nil }),
                                   msg.contentParts[idx].thinkingSignature == nil {
                                    msg.contentParts[idx] = .thinking(block, signature: signature)
                                } else {
                                    let insertAt = msg.contentParts.firstIndex(where: { $0.textContent != nil }) ?? msg.contentParts.endIndex
                                    msg.contentParts.insert(.thinking(block, signature: signature), at: insertAt)
                                }
                            }

                        case .appendToolResult(let result):
                            // Append the dispatched tool result as a first-class
                            // part so the transcript records the full call →
                            // result round trip alongside any visible text. UI
                            // renders these via MessagePartsView's tool-call
                            // switch branch.
                            self.onMutateMessage(messageID) { msg in
                                msg.contentParts.append(.toolResult(result))
                            }

                        case .toolLoopLimitReached(let iterations):
                            // The orchestrator stopped the dispatch loop before
                            // the model produced a final visible answer. Surface
                            // an error so the user isn't left staring at an
                            // empty bubble.
                            self.onSetErrorMessage("Tool-call loop stopped after \(iterations) iterations.")

                        case .ignore:
                            break
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        Log.inference.error("Generation stream error: \(error)")
                        self.onSurfaceError(error, .generation, "Generation failed")
                    }
                }

                // Flush remaining buffered tokens after stream ends (normal, error, or cancellation).
                if let batch = batcher.flush(now: ContinuousClock.now) {
                    self.onMutateMessage(messageID) { msg in
                        Self.appendVisibleText(batch, into: &msg)
                    }
                }

                // Finalize an unclosed thinking block — a model may emit <think>…
                // without a closing tag if generation is cut short. Targets
                // the *last* in-flight thinking part so previously finalized
                // blocks (including their signatures) survive untouched.
                if !thinkingAccumulator.isEmpty {
                    _ = thinkingBatcher.flush(now: ContinuousClock.now)
                    let block = thinkingAccumulator
                    let signature = pendingThinkingSignature
                    thinkingAccumulator = ""
                    thinkingDisplayed = ""
                    pendingThinkingSignature = nil
                    self.onMutateMessage(messageID) { msg in
                        if let idx = msg.contentParts.lastIndex(where: { $0.thinkingContent != nil }),
                           msg.contentParts[idx].thinkingSignature == nil {
                            msg.contentParts[idx] = .thinking(block, signature: signature)
                        } else {
                            let insertAt = msg.contentParts.firstIndex(where: { $0.textContent != nil }) ?? msg.contentParts.endIndex
                            msg.contentParts.insert(.thinking(block, signature: signature), at: insertAt)
                        }
                    }
                }
                // Clear any lingering streaming flag if the stream ended without
                // an explicit `.finalizeThinking` (cancellation, error, etc.).
                self.onMarkThinkingStreaming(messageID, false)
            }

            onSetGenerationTask(task)
            await task.value

        } catch {
            Log.inference.error("Generation start error: \(error)")
            onSurfaceError(error, .generation, "Generation failed")
        }

        // Capture token usage from cloud backends.
        if let usage = inferenceService.lastTokenUsage {
            onMutateMessage(messageID) { msg in
                msg.promptTokens = usage.promptTokens
                msg.completionTokens = usage.completionTokens
            }
        }

        // Persist the completed assistant message.
        // Keep the message if it has visible text OR thinking content — a thinking-only
        // response (no visible text but `.thinking` parts present) is still meaningful.
        let currentMessages = messages()
        if let idx = currentMessages.firstIndex(where: { $0.id == messageID }) {
            let hasThinkingContent = currentMessages[idx].contentParts.contains(where: { $0.thinkingContent != nil })
            do {
                if !currentMessages[idx].hasVisibleContent && !hasThinkingContent {
                    onRemoveMessage(messageID)
                } else {
                    try await onSaveMessage(currentMessages[idx])
                }
            } catch {
                Log.persistence.error("Failed to persist assistant message: \(error)")
                onSurfaceError(error, .persistence, "Failed to save assistant response")
            }
        }

        // After the first assistant response on Foundation, nudge the user to
        // consider downloading a local model for longer context. Only show once
        // per session and only when Foundation is the active backend.
        if BaseChatConfiguration.shared.features.showUpgradeHint,
           !showUpgradeHint(),
           messages().first(where: { $0.id == messageID })?.hasVisibleContent == true,
           activeBackendName() == "Apple",
           messages().filter({ $0.role == .assistant }).count == 1 {
            onSetShowUpgradeHint(true)
            onUpgradeHintTriggered?()
        }

        onUpdateContextEstimate()

        // Fire post-generation tasks off @MainActor if we have a non-empty assistant message.
        if let completedMessage = messages().first(where: { $0.id == messageID }),
           completedMessage.hasVisibleContent,
           let session = activeSession() {
            runPostGenerationTasks(message: completedMessage, session: session)
        }
    }

    // MARK: - Private Helpers

    /// Launches post-generation tasks sequentially in a `Task` that inherits `@MainActor` isolation.
    ///
    /// A throwing task records its error via ``onSetBackgroundTaskError`` and execution
    /// continues with the next task. Cancellation via ``onSetBackgroundTask`` exits the loop.
    private func runPostGenerationTasks(message: ChatMessageRecord, session: ChatSessionRecord) {
        let tasks = postGenerationTasks()
        guard !tasks.isEmpty else { return }

        let bgTask = Task { [weak self, tasks, message, session] in
            for task in tasks {
                guard !Task.isCancelled else { break }
                do {
                    try await task.run(message: message, session: session)
                } catch is CancellationError {
                    break
                } catch {
                    self?.onSetBackgroundTaskError(error)
                }
            }
        }
        onSetBackgroundTask(bgTask)
    }

    /// Appends streamed visible-token text to a message without clobbering
    /// any existing non-text parts (thinking, tool calls, tool results).
    ///
    /// `ChatMessageRecord.content`'s setter replaces the entire `contentParts`
    /// array with a single `.text` part — convenient for the legacy text-only
    /// path, fatal for messages that hold a `.thinking` part placed ahead of
    /// the text. Preserve those parts by mutating only the trailing `.text`
    /// (or appending one when none exists).
    static func appendVisibleText(_ batch: String, into msg: inout ChatMessageRecord) {
        if let lastIdx = msg.contentParts.indices.reversed().first(where: {
            if case .text = msg.contentParts[$0] { return true } else { return false }
        }), case .text(let existing) = msg.contentParts[lastIdx] {
            msg.contentParts[lastIdx] = .text(existing + batch)
        } else {
            msg.contentParts.append(.text(batch))
        }
    }

    /// Writes `partial` into the message's last `.thinking` part for live preview.
    ///
    /// Used between `.appendThinkingText` events to flush batched reasoning text
    /// before the authoritative `.finalizeThinking` write. The text is written
    /// in-place into the existing placeholder (inserted on the first thinking
    /// fragment) so each flush mutates the same part rather than appending new
    /// ones — keeping the message structure stable across rerenders.
    static func writeThinkingPartialText(_ partial: String, into msg: inout ChatMessageRecord) {
        // Target the most recent thinking part — that's the in-flight
        // placeholder for the current reasoning block. Earlier blocks were
        // already finalized and must not be mutated.
        guard let idx = msg.contentParts.lastIndex(where: { $0.thinkingContent != nil }) else {
            // The placeholder should always exist by the time partial flushes
            // run, but if it doesn't (e.g. tests that drive this helper
            // directly), insert one ahead of any visible text.
            let insertAt = msg.contentParts.firstIndex(where: { $0.textContent != nil }) ?? 0
            msg.contentParts.insert(.thinking(partial), at: insertAt)
            return
        }
        // Preserve any signature already attached to this part — partial
        // flushes only update the text. Signatures arrive separately and
        // are written by the finalize path.
        let signature = msg.contentParts[idx].thinkingSignature
        msg.contentParts[idx] = .thinking(partial, signature: signature)
    }

    /// Substitutes `{{key}}` tokens in `text` with values from `context`.
    ///
    /// Single-pass scan: each `{{word}}` token in the source is examined exactly
    /// once, so substitution is non-recursive (a value containing `{{otherKey}}`
    /// is not re-expanded) and the result does not depend on dictionary
    /// iteration order. Tokens whose key is not present in `context` are left
    /// untouched, mirroring the pass-through behavior documented on
    /// ``ChatViewModel/systemPromptContext``.
    static func applySystemPromptContext(_ text: String, context: [String: String]) -> String {
        guard !context.isEmpty, text.contains("{{") else { return text }
        // `{{word}}` where `word` is one or more word characters. Anything that
        // doesn't match (whitespace, dots, empty `{{}}`) is ignored.
        let regex = _systemPromptContextRegex
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        // Walk matches in reverse so replacement ranges remain valid as we mutate.
        let matches = regex.matches(in: text, options: [], range: fullRange).reversed()
        var result = text
        for match in matches {
            guard let keyRange = Range(match.range(at: 1), in: result),
                  let fullMatchRange = Range(match.range, in: result) else { continue }
            let key = String(result[keyRange])
            if let replacement = context[key] {
                result.replaceSubrange(fullMatchRange, with: replacement)
            }
        }
        return result
    }
}
