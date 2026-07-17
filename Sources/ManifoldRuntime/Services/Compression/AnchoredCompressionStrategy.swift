import Foundation
import ManifoldInference

/// Summarises old messages via an inference call, then prepends the summary
/// (as a `.memory("summary")` record) to a verbatim recency tail. Falls back
/// to ``ExtractiveCompressionStrategy`` on any failure — failed or empty
/// inference (including a no-op summariser), or an oversized summary.
///
/// Adapted from Fireside's `AnchoredStoryCompressor`, preserving its
/// hard-won behaviors: input-window decoupling (`summarizerInputWindow`),
/// chunk-and-fold for over-window input, a minimum-summary floor, and a
/// cancellation early-return. The summary prompt is passed to `generate` as a
/// single-message mini-conversation.
///
// TODO(#1885, optional P2): collapse/fold a prior `.memory("summary")` record
// into the new summarisation pass instead of pinning it (as load-bearing) into
// the tail and prepending a SECOND inline summary each cycle. Across many
// compression cycles the inline summary blocks stack. Doing this right means
// detecting the prior summary, excluding it from the verbatim tail, and
// feeding its text into the summariser input alongside the old messages — a
// non-trivial change to the tail/old-message partition. Deliberately deferred
// to keep this fix-round diff bounded; the stack is bounded in practice by the
// budget enforcement and is correctness-neutral (just less compact).
struct AnchoredCompressionStrategy: CompressionStrategy {
    let name = "anchored"

    let tailBudgetFraction: Double
    /// The summariser model's REAL usable window (tokens), used to size how
    /// much old text it may READ. Decoupled from `contextSize`, which is the
    /// small overflow *trigger* and the *output-brief* budget. `nil` sizes
    /// input against `contextSize` (legacy behavior).
    let summarizerInputWindow: Int?
    /// Minimum tokens reserved for the output brief even when `contextSize` is
    /// tiny — a short brief beats no brief.
    let minSummaryBudget: Int
    /// Tokens reserved for the summariser's own response when sizing the INPUT
    /// window. This is the SAME reservation knob as the policy's
    /// `reservedTokens` (the factory threads `reservedTokens` here), so there is
    /// one source of truth — there is no longer a separate hard-coded buffer.
    let summarizerResponseBuffer: Int
    let summaryTemplate: String

    private let fallback = ExtractiveCompressionStrategy()

    // MARK: - Cached constants

    /// Precompiled regex for `parseSummaryResponse` — hoisted from the call site
    /// to avoid recompiling the same NSRegularExpression on every compression
    /// cycle. The pattern is a compile-time constant; `preconditionFailure` here
    /// signals a toolchain regression, not bad input (there is no recovery path).
    private static let summaryFieldRegex: NSRegularExpression = {
        do {
            return try NSRegularExpression(
                pattern: "^([A-Z][A-Z _]*[A-Z]):\\s*(.+)$",
                options: [.anchorsMatchLines, .caseInsensitive]
            )
        } catch {
            preconditionFailure("[AnchoredCompression] failed to compile summary regex: \(error)")
        }
    }()

    /// Cached template `ThinkingTransform` for the Qwen3/DeepSeek `<think>` marker.
    /// `ThinkingTransform` is a struct — each call copies this value-typed template,
    /// so the per-call mutable state (`depth`, `buffer`) is always reset to zero.
    private static let qwen3ThinkingTemplate = ThinkingTransform(markers: .qwen3)

    /// Cached template `ThinkingTransform` for the Mistral/Sky-T1 `<thinking>` marker.
    /// Same copy-on-use semantics as `qwen3ThinkingTemplate`.
    private static let mistralThinkingTemplate = ThinkingTransform(markers: .mistralReasoning)

    /// Placeholder `{old_text}` is replaced with the concatenated old messages.
    static let defaultSummaryTemplate = """
        Summarize the conversation so far. Be concise. Use only what is in the text.

        TOPIC: [main subject of the conversation, brief]
        KEY POINTS: [up to 3 important points, semicolon-separated]
        OPEN QUESTIONS: [unresolved items or pending decisions, if any]
        LAST DISCUSSED: [most recent topic or conclusion, one sentence]

        Conversation:
        {old_text}
        """

    init(
        tailBudgetFraction: Double = 0.50,
        summarizerResponseBuffer: Int = DefaultCompressionPolicy.defaultReservedTokens,
        summarizerInputWindow: Int? = nil,
        minSummaryBudget: Int = 256,
        summaryTemplate: String? = nil
    ) {
        self.tailBudgetFraction = tailBudgetFraction
        self.summarizerInputWindow = summarizerInputWindow
        self.minSummaryBudget = minSummaryBudget
        self.summarizerResponseBuffer = summarizerResponseBuffer
        self.summaryTemplate = summaryTemplate ?? Self.defaultSummaryTemplate
    }

    func compress(
        history: [ChatMessage],
        contextSize: Int,
        reservedTokens: Int,
        tokenizer: (any TokenizerProvider)?,
        isPinned: @Sendable (ChatMessage) -> Bool,
        generate: @Sendable ([ChatMessage]) async throws -> String
    ) async throws -> StrategyCompressionResult {
        guard !history.isEmpty else {
            return StrategyCompressionResult(messages: [], outcome: .notNeeded)
        }

        let budget = historyBudget(contextSize: contextSize, reservedTokens: reservedTokens)
        let tokens = history.map { estimateTokens($0, tokenizer: tokenizer) }
        let originalTokens = tokens.reduce(0, +)
        if originalTokens <= budget {
            return StrategyCompressionResult(messages: history, outcome: .notNeeded)
        }

        let sessionID = history.first?.sessionID ?? UUID()
        let count = history.count

        // --- Verbatim tail: load-bearing records + newest within tailBudget ---
        let tailBudget = Int(Double(budget) * tailBudgetFraction)
        var tailIndices = Set<Int>()
        var tailTokens = 0
        for i in 0..<count where isLoadBearing(history[i], isPinned: isPinned) {
            tailIndices.insert(i)
            tailTokens += tokens[i]
        }
        for i in stride(from: count - 1, through: 0, by: -1) {
            if tailIndices.contains(i) { continue }
            if tailTokens + tokens[i] <= tailBudget {
                tailIndices.insert(i)
                tailTokens += tokens[i]
            } else if tailIndices.isEmpty {
                tailIndices.insert(i)
                tailTokens += tokens[i]
                break
            }
        }
        // Invariant: never drop the newest message.
        if !tailIndices.contains(count - 1) {
            tailIndices.insert(count - 1)
            tailTokens += tokens[count - 1]
        }

        let tailMessages = tailIndices.sorted().map { history[$0] }
        let oldMessages = (0..<count).filter { !tailIndices.contains($0) }.map { history[$0] }

        if oldMessages.isEmpty {
            // Every message was load-bearing/pinned — nothing eligible to
            // summarize. Not a failure (#2203): the tail IS the full input.
            return StrategyCompressionResult(messages: tailMessages, outcome: .nothingToSummarize)
        }

        // --- Build summary prompt, sizing input against the REAL window ---
        let oldText = oldMessages.map(\.content).joined(separator: "\n\n")
        let oldTextTokens = ContextWindowManager.estimateTokenCount(oldText, tokenizer: tokenizer)
        let inputWindow = max(summarizerInputWindow ?? contextSize, contextSize)
        let usableInputBudget = max(0, inputWindow - summarizerResponseBuffer)

        // Chunk-and-fold only when a REAL window was set AND the input genuinely
        // exceeds it; otherwise a single summarisation call (step-9 truncation
        // handles output overflow).
        let canChunkAndFold = summarizerInputWindow != nil
        let prompt: String
        if canChunkAndFold && oldTextTokens > usableInputBudget && usableInputBudget > 0 {
            Log.inference.warning(
                "[AnchoredCompression] input \(oldTextTokens) tok exceeds usable window \(usableInputBudget); chunk-and-folding \(oldMessages.count) old messages"
            )
            prompt = await foldedSummaryPrompt(
                oldMessages: oldMessages, chunkBudget: usableInputBudget,
                sessionID: sessionID, generate: generate, tokenizer: tokenizer
            )
        } else {
            prompt = summaryTemplate.replacingOccurrences(of: "{old_text}", with: oldText)
        }

        // --- Summarise (cancellation returns a minimal tail-only result) ---
        let summaryText: String
        do {
            try Task.checkCancellation()
            summaryText = try await generate([summaryMessage(prompt, sessionID: sessionID)])
        } catch is CancellationError {
            // Covers BOTH ambient Task cancellation (the checkCancellation()
            // above) and generate-thrown CancellationError (#2203 acceptance
            // criterion) — both land in this catch clause and must NOT be
            // misreported as a summarizer failure.
            return StrategyCompressionResult(messages: tailMessages, outcome: .cancelled)
        } catch {
            Log.inference.debug("[AnchoredCompression] summarisation failed: \(error); falling back to extractive")
            let fallbackResult = try await fallback.compress(
                history: history, contextSize: contextSize,
                reservedTokens: reservedTokens, tokenizer: tokenizer, isPinned: isPinned, generate: generate
            )
            return StrategyCompressionResult(
                messages: fallbackResult.messages,
                outcome: .fallbackUsed(reason: .summarizerThrew)
            )
        }

        guard !summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let fallbackResult = try await fallback.compress(
                history: history, contextSize: contextSize,
                reservedTokens: reservedTokens, tokenizer: tokenizer, isPinned: isPinned, generate: generate
            )
            return StrategyCompressionResult(
                messages: fallbackResult.messages,
                outcome: .fallbackUsed(reason: .emptySummary)
            )
        }

        // --- Assemble: summary record + verbatim tail ---
        let parsed = parseSummaryResponse(summaryText)
        let summaryTokens = ContextWindowManager.estimateTokenCount(parsed, tokenizer: tokenizer)

        var finalSummary = parsed
        if summaryTokens + tailTokens > budget {
            let rawSummaryBudget = budget - tailTokens
            let summaryBudget = rawSummaryBudget > 0 ? rawSummaryBudget : min(minSummaryBudget, budget)
            if rawSummaryBudget <= 0 {
                Log.inference.warning(
                    "[AnchoredCompression] tail consumes the whole budget (tail=\(tailTokens) >= budget=\(budget)); emitting floored \(summaryBudget)-tok brief"
                )
            }
            let truncated = truncateToFit(parsed, budget: summaryBudget, tokenizer: tokenizer)
            finalSummary = truncated.isEmpty ? String(parsed.prefix(200)) : truncated
        }

        var output: [ChatMessage] = [summaryRecord(finalSummary, sessionID: sessionID)]
        output.append(contentsOf: tailMessages)
        let finalSummaryTokens = ContextWindowManager.estimateTokenCount(finalSummary, tokenizer: tokenizer)
        return StrategyCompressionResult(messages: output, outcome: .summarized(estimatedTokens: finalSummaryTokens))
    }

    // MARK: - Helpers

    private func summaryMessage(_ prompt: String, sessionID: UUID) -> ChatMessage {
        ChatMessage(role: .user, content: prompt, sessionID: sessionID)
    }

    private func summaryRecord(_ text: String, sessionID: UUID) -> ChatMessage {
        ChatMessage(role: .system, content: text, sessionID: sessionID, kind: .memory("summary"))
    }

    /// Strips leaked chain-of-thought (`<think>…</think>`, `<thinking>…`)
    /// before parsing, reusing MK's ``ThinkingTransform`` rather than
    /// hand-rolling marker logic. A reasoning model can emit its scratchpad
    /// ahead of the brief; left in, that scratchpad would be parsed as the
    /// "summary" and injected verbatim into the compressed history. We run the
    /// two common marker families (Qwen/DeepSeek `<think>`, Mistral/Sky-T1
    /// `<thinking>`) in sequence and keep only the visible `.token` text.
    private func stripThinking(_ text: String) -> String {
        var result = text
        // Copy the struct templates — ThinkingTransform is a value type, so each
        // `var` assignment gives us a fresh instance with depth=0 and buffer="".
        for template in [Self.qwen3ThinkingTemplate, Self.mistralThinkingTemplate] {
            var transform = template
            var events = transform.process([.token(result)])
            events += transform.finalize()
            let visible = events.compactMap { event -> String? in
                if case .token(let t) = event { return t }
                return nil
            }.joined()
            result = visible
        }
        return result
    }

    /// Extracts `FIELD: value` lines and reassembles them; falls back to a
    /// trimmed raw response when fewer than two fields are present. Strips
    /// leaked reasoning first so chain-of-thought can't masquerade as a summary.
    private func parseSummaryResponse(_ rawResponse: String) -> String {
        let response = stripThinking(rawResponse)
        let regex = Self.summaryFieldRegex
        let ns = response as NSString
        var fields: [String] = []
        for match in regex.matches(in: response, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges >= 3 {
            let name = ns.substring(with: match.range(at: 1))
            let value = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { fields.append("\(name): \(value)") }
        }
        if fields.count >= 2 { return fields.joined(separator: "\n") }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "[Summary unavailable]" : String(trimmed.prefix(400))
    }

    /// Summarises over-window input in chunks, then folds the chunk summaries
    /// into one prompt so the WHOLE old text is covered rather than truncated.
    private func foldedSummaryPrompt(
        oldMessages: [ChatMessage],
        chunkBudget: Int,
        sessionID: UUID,
        generate: @Sendable ([ChatMessage]) async throws -> String,
        tokenizer: (any TokenizerProvider)?
    ) async -> String {
        let templateOverhead = ContextWindowManager.estimateTokenCount(
            summaryTemplate.replacingOccurrences(of: "{old_text}", with: ""),
            tokenizer: tokenizer
        )
        let perChunkBudget = max(64, chunkBudget - templateOverhead)

        var chunks: [[ChatMessage]] = []
        var current: [ChatMessage] = []
        var currentTokens = 0
        for message in oldMessages {
            let cost = estimateTokens(message, tokenizer: tokenizer)
            if !current.isEmpty && currentTokens + cost > perChunkBudget {
                chunks.append(current)
                current = []
                currentTokens = 0
            }
            current.append(message)
            currentTokens += cost
        }
        if !current.isEmpty { chunks.append(current) }

        var summaries: [String] = []
        for chunk in chunks {
            let chunkText = chunk.map(\.content).joined(separator: "\n\n")
            let chunkPrompt = summaryTemplate.replacingOccurrences(of: "{old_text}", with: chunkText)
            do {
                let summary = try await generate([summaryMessage(chunkPrompt, sessionID: sessionID)])
                if summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    summaries.append(truncateToFit(chunkText, budget: perChunkBudget, tokenizer: tokenizer))
                } else {
                    summaries.append(parseSummaryResponse(summary))
                }
            } catch {
                // Preserve content even when a chunk's summarisation fails.
                Log.inference.debug("[AnchoredCompression] chunk summarisation failed: \(error); keeping raw chunk")
                summaries.append(truncateToFit(chunkText, budget: perChunkBudget, tokenizer: tokenizer))
            }
        }
        return summaryTemplate.replacingOccurrences(of: "{old_text}", with: summaries.joined(separator: "\n\n"))
    }

    /// Drops trailing words until the text fits the budget.
    private func truncateToFit(_ text: String, budget: Int, tokenizer: (any TokenizerProvider)?) -> String {
        if ContextWindowManager.estimateTokenCount(text, tokenizer: tokenizer) <= budget {
            return text
        }
        var words = text.split(separator: " ", omittingEmptySubsequences: true)
        while !words.isEmpty {
            words.removeLast()
            let candidate = words.joined(separator: " ")
            if ContextWindowManager.estimateTokenCount(candidate, tokenizer: tokenizer) <= budget {
                return candidate
            }
        }
        return ""
    }
}
