import Foundation

// MARK: - CompactionTrigger

/// Why a transcript compaction happened. Used by trigger-aware compressors
/// (notably ``BudgetTurnHistoryCompressor``) to append a context-appropriate
/// continuation prompt so the model resumes naturally instead of acknowledging
/// the summary out loud.
///
/// Mirrors Goose AI's three triggers (`crates/goose/src/context_mgmt/mod.rs`):
/// automatic budget overflow, in-loop tool compaction, and explicit user
/// request.
package enum CompactionTrigger: Sendable {
    /// Budget exceeded mid-conversation. The compaction was not user-driven
    /// and is not happening inside an active tool-calling loop.
    case automatic
    /// Compaction fired during a tool-calling loop. The continuation prompt
    /// asks the model to keep calling tools as needed rather than narrating.
    case toolLoop
    /// User explicitly requested compaction. The continuation acknowledges
    /// the user's request without asking the model to mention it.
    case manual
}

// MARK: - TurnHistoryRecord

/// One round of an agent loop captured for potential compression.
///
/// An agent-loop driver builds one of these per generate → tool-call →
/// result round and hands the running list to a ``TurnHistoryCompressor``
/// before each new generate round.
///
/// The record preserves the structural payloads (calls + results + any
/// intermediate visible text the model produced before issuing a call) so
/// that summarisers can quote arguments or excerpt outputs verbatim and so
/// that round-trip tests can verify older facts are still recoverable from
/// a compressed transcript.
package struct TurnHistoryRecord: Sendable, Equatable {

    /// 1-indexed step number in the orchestrator's loop. Stable across
    /// compression — a record's `step` does not change when it is folded
    /// into a summary, so consumers can reliably reference "step 3" in
    /// summary text without worrying about renumbering.
    package let step: Int

    /// Visible text fragments the model produced during this round before
    /// (or in addition to) any tool calls. Empty when the round consisted
    /// solely of tool calls.
    package let intermediateTokens: [String]

    /// Tool calls emitted by the model in this round, in batch-emission
    /// order (matches the orchestrator's deterministic next-prompt layout).
    package let toolCalls: [ToolCall]

    /// Tool results in the same order as ``toolCalls``. Always one-to-one
    /// with ``toolCalls`` — the orchestrator pairs them before recording.
    package let toolResults: [ToolResult]

    package init(
        step: Int,
        intermediateTokens: [String] = [],
        toolCalls: [ToolCall] = [],
        toolResults: [ToolResult] = []
    ) {
        self.step = step
        self.intermediateTokens = intermediateTokens
        self.toolCalls = toolCalls
        self.toolResults = toolResults
    }

    /// Concatenated visible text for this round. Used by compressors and
    /// for `approximateSize` accounting.
    package var visibleText: String {
        intermediateTokens.joined()
    }

    /// Rough character-count proxy for "context cost" of this record.
    ///
    /// Sums the visible text plus every tool call's argument string and
    /// every result's content string. Compressors compare this against
    /// their byte-budget to decide what to fold.
    package var approximateSize: Int {
        var n = visibleText.count
        for call in toolCalls {
            n += call.toolName.count + call.arguments.count
        }
        for result in toolResults {
            n += result.content.count
        }
        return n
    }
}

// MARK: - CompressedTranscript

/// The output of a ``TurnHistoryCompressor`` — a (possibly empty) summary
/// string for older rounds plus the records that should be kept verbatim.
///
/// Agent-loop drivers rebuild the next-turn prompt as
/// `initialPrompt + summary + verbatim record appendix`, so an empty summary
/// with all records preserved is a no-op.
package struct CompressedTranscript: Sendable, Equatable {

    /// Summary text covering folded rounds. Inserted into the next prompt
    /// before the preserved records' appendix.
    ///
    /// Empty when nothing was folded.
    package let summary: String

    /// Records that were folded into ``summary``. Surfaced for tests and
    /// for compressors that chain (e.g. summarise-then-resummarise).
    package let foldedRecords: [TurnHistoryRecord]

    /// Records that must be re-appended verbatim to the next-turn prompt.
    /// Order is preserved — compressors must not reorder.
    package let preservedRecords: [TurnHistoryRecord]

    package init(
        summary: String,
        foldedRecords: [TurnHistoryRecord],
        preservedRecords: [TurnHistoryRecord]
    ) {
        self.summary = summary
        self.foldedRecords = foldedRecords
        self.preservedRecords = preservedRecords
    }

    /// A pass-through compression — the input records are preserved unchanged.
    package static func unchanged(_ records: [TurnHistoryRecord]) -> CompressedTranscript {
        CompressedTranscript(summary: "", foldedRecords: [], preservedRecords: records)
    }
}

// MARK: - TurnHistoryCompressor

/// Compresses an agent-loop transcript when it grows past a budget.
///
/// Distinct from user-visible dialogue compression: the dialogue compressor
/// summarises chat turns the user can see; this one summarises *internal*
/// scratch — tool calls and tool results — that need to remain structurally
/// referenceable but do not need verbatim preservation.
///
/// Implementations are ``Sendable`` so an agent-loop driver can hold one
/// across async boundaries. The default in-tree implementation is
/// ``BudgetTurnHistoryCompressor``; drivers default to
/// ``NoOpTurnHistoryCompressor()`` for no compression so existing callers
/// see no behaviour change.
package protocol TurnHistoryCompressor: Sendable {

    /// Decides whether (and how) to fold older rounds.
    ///
    /// Implementations must:
    /// - Preserve order. ``CompressedTranscript/preservedRecords`` is the
    ///   suffix of `records` and ``CompressedTranscript/foldedRecords`` is
    ///   the prefix.
    /// - Be idempotent. Calling `compress` on an already-compressed input
    ///   (i.e. when the budget is satisfied) returns
    ///   ``CompressedTranscript/unchanged(_:)``.
    /// - Be deterministic. The same input must always produce the same
    ///   output — KV-cache prefix reuse depends on stable prompt prefixes.
    func compress(records: [TurnHistoryRecord]) -> CompressedTranscript

    /// Trigger-aware variant. Implementations may use the trigger to tailor
    /// the produced summary (e.g. append a continuation prompt that nudges
    /// the model to resume in the right register).
    ///
    /// Has a default implementation that ignores `trigger` and calls
    /// ``compress(records:)`` — existing conformers compile unchanged.
    func compress(records: [TurnHistoryRecord], trigger: CompactionTrigger) -> CompressedTranscript
}

package extension TurnHistoryCompressor {
    /// Default implementation forwards to the trigger-agnostic method so
    /// that adopters which were written before ``CompactionTrigger`` keep
    /// working. New implementations should override this to consume the
    /// trigger.
    func compress(records: [TurnHistoryRecord], trigger: CompactionTrigger) -> CompressedTranscript {
        compress(records: records)
    }
}

// MARK: - BudgetTurnHistoryCompressor

/// Default ``TurnHistoryCompressor`` that folds older rounds once a
/// character-count budget is exceeded.
///
/// Trigger heuristic:
/// - Sum each record's ``TurnHistoryRecord/approximateSize``.
/// - If the total fits within ``characterBudget``, return unchanged.
/// - Otherwise, peel records off the *front* (oldest first) until either
///   the remaining suffix fits the budget *or* only ``preserveRecentTurns``
///   records are left. Whichever fires first.
///
/// The peeled records are summarised into a single ``CompressedTranscript/summary``
/// block of the form:
///
/// ```text
/// [Earlier turns summarised: N rounds, M tool calls. Notable results:
///   step 2: weather(city=Rome) → "18°C"
///   step 4: search(q=swift) → "21 hits"
/// ]
/// ```
///
/// The format is plain text by design — every backend's prompt
/// concatenation path accepts strings, so the summary travels with the
/// next-turn prompt without needing a structured-message channel.
package struct BudgetTurnHistoryCompressor: TurnHistoryCompressor {

    /// Approximate character budget across the whole transcript. Once the
    /// running total exceeds this, the compressor begins folding from the
    /// front. Defaults to 8_000 — a conservative choice that keeps a
    /// 4k-token model well within window after system + initial prompt.
    package let characterBudget: Int

    /// Lower bound on how many of the most recent records must remain
    /// verbatim, regardless of budget. Defaults to 2 — enough that the
    /// model sees the immediately preceding round's call/result pair so
    /// it can continue reasoning about it without needing the summary.
    package let preserveRecentTurns: Int

    /// Maximum number of "notable results" to inline in the summary.
    /// Defaults to 5. Older folded rounds beyond this collapse to a count.
    package let maxResultExcerpts: Int

    /// Maximum length of each excerpted result value before truncation.
    /// Defaults to 80 characters.
    package let maxResultExcerptLength: Int

    package init(
        characterBudget: Int = 8_000,
        preserveRecentTurns: Int = 2,
        maxResultExcerpts: Int = 5,
        maxResultExcerptLength: Int = 80
    ) {
        // Clamp to safe minimums — a budget of 0 or negative preserve count
        // would degenerate to "fold everything" which is never the intent.
        self.characterBudget = max(1, characterBudget)
        self.preserveRecentTurns = max(1, preserveRecentTurns)
        self.maxResultExcerpts = max(0, maxResultExcerpts)
        self.maxResultExcerptLength = max(8, maxResultExcerptLength)
    }

    package func compress(records: [TurnHistoryRecord]) -> CompressedTranscript {
        compress(records: records, trigger: .automatic)
    }

    package func compress(
        records: [TurnHistoryRecord],
        trigger: CompactionTrigger
    ) -> CompressedTranscript {
        if records.isEmpty {
            return .unchanged(records)
        }

        let totalSize = records.reduce(0) { $0 + $1.approximateSize }
        if totalSize <= characterBudget {
            return .unchanged(records)
        }

        // Peel oldest records until either (a) the remaining suffix fits or
        // (b) we are down to `preserveRecentTurns`. The minimum we keep is
        // `min(preserveRecentTurns, records.count)` — never fold every
        // record, because the model needs at least the most recent round
        // verbatim to continue.
        let minimumPreserved = min(preserveRecentTurns, records.count)
        var foldedCount = 0
        var remaining = totalSize

        while foldedCount < records.count - minimumPreserved {
            remaining -= records[foldedCount].approximateSize
            foldedCount += 1
            if remaining <= characterBudget {
                break
            }
        }

        if foldedCount == 0 {
            return .unchanged(records)
        }

        let folded = Array(records.prefix(foldedCount))
        let preserved = Array(records.suffix(records.count - foldedCount))
        let summary = renderSummary(for: folded) + "\n\n" + Self.continuationText(for: trigger)
        return CompressedTranscript(
            summary: summary,
            foldedRecords: folded,
            preservedRecords: preserved
        )
    }

    // MARK: - Continuation prompts (ported from Goose AI)
    //
    // Goose appends one of these strings to the summary block before handing
    // it back to the model. The intent is to keep the model from breaking
    // immersion ("based on the earlier turns I see…") while making sure it
    // resumes in the right register: prose chat, in-loop tool calling, or
    // a user-initiated reset. Source: `crates/goose/src/context_mgmt/mod.rs`.

    static let conversationContinuationText: String =
        "Your context was compacted. The previous message contains a summary of the conversation so far.\nDo not mention that you read a summary or that conversation summarization occurred.\nJust continue the conversation naturally based on the summarized context."

    static let toolLoopContinuationText: String =
        "Your context was compacted. The previous message contains a summary of the conversation so far.\nDo not mention that you read a summary or that conversation summarization occurred.\nContinue calling tools as necessary to complete the task."

    static let manualCompactContinuationText: String =
        "Your context was compacted at the user's request. The previous message contains a summary of the conversation so far.\nDo not mention that you read a summary or that conversation summarization occurred.\nJust continue the conversation naturally based on the summarized context."

    private static func continuationText(for trigger: CompactionTrigger) -> String {
        switch trigger {
        case .automatic: return conversationContinuationText
        case .toolLoop: return toolLoopContinuationText
        case .manual: return manualCompactContinuationText
        }
    }

    private func renderSummary(for folded: [TurnHistoryRecord]) -> String {
        let totalCalls = folded.reduce(0) { $0 + $1.toolCalls.count }
        var lines: [String] = []
        lines.append("[Earlier turns summarised: \(folded.count) rounds, \(totalCalls) tool calls.")

        let excerpts = collectExcerpts(folded)
        if !excerpts.isEmpty {
            lines.append("Notable results:")
            for excerpt in excerpts {
                lines.append("  \(excerpt)")
            }
            let leftover = totalCalls - excerpts.count
            if leftover > 0 {
                lines.append("  …and \(leftover) more.")
            }
        }
        lines.append("]")
        return lines.joined(separator: "\n")
    }

    private func collectExcerpts(_ folded: [TurnHistoryRecord]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(maxResultExcerpts)
        outer: for record in folded {
            for (call, result) in zip(record.toolCalls, record.toolResults) {
                if out.count >= maxResultExcerpts { break outer }
                let truncated = truncate(result.content, to: maxResultExcerptLength)
                let args = truncate(call.arguments, to: maxResultExcerptLength)
                let kindSuffix: String
                if let kind = result.errorKind {
                    kindSuffix = " (error: \(kind.rawValue))"
                } else {
                    kindSuffix = ""
                }
                out.append("step \(record.step): \(call.toolName)(\(args)) → \(truncated)\(kindSuffix)")
            }
        }
        return out
    }

    private func truncate(_ s: String, to limit: Int) -> String {
        if s.count <= limit { return s }
        let prefix = s.prefix(max(0, limit - 1))
        return "\(prefix)…"
    }
}

// MARK: - NoOpTurnHistoryCompressor

/// A compressor that never folds anything. Useful as a sentinel and as the
/// implicit default when an agent-loop driver is constructed without a
/// `compressor` argument — existing callers see no behaviour change.
package struct NoOpTurnHistoryCompressor: TurnHistoryCompressor {
    package init() {}
    package func compress(records: [TurnHistoryRecord]) -> CompressedTranscript {
        .unchanged(records)
    }
}
