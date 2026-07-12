import Foundation

/// Classification of what a ``CompressionStrategy`` actually did on a given
/// `compress` call — the missing signal #2203 was filed against.
///
/// Consumers previously reconstructed this from record-shape heuristics
/// (presence of a `kind: .memory("summary")` first record, cancellation
/// flags layered around the injected `generateFn`, counting non-load-bearing
/// inputs). That reconstruction shipped real classification bugs in
/// Fireside's `DefaultCompressionPolicy` adoption (roryford/fireside#910):
/// ambient `Task` cancellation misreported as fallback, a budget-skip
/// misreported as fallback, and an all-load-bearing pass misreported as
/// failure. `CompressionOutcome` is populated at the point each strategy
/// (or ``DefaultCompressionPolicy``, for the budget-skip case) actually
/// knows the answer, so no consumer-side reconstruction is needed.
///
/// Delivered via ``DefaultCompressionPolicy``'s `onOutcome` callback — the
/// public `CompressionPolicy`/`PreTurnCompressionPolicy` protocol `compress`
/// signatures are unchanged (still `[ChatMessage]`), so this is additive:
/// existing conformances and callers are unaffected. Register the callback
/// on the factory (`.anchored(..., onOutcome:)` etc.) to observe it.
public enum CompressionOutcome: Sendable, Equatable {
    /// The old-message segment was summarized via inference and prepended to
    /// the verbatim tail (the anchored strategy's success path).
    case summarized(estimatedTokens: Int)

    /// Summarization was attempted but degraded to the extractive fallback —
    /// either the summarizer call threw, or it returned an empty/blank
    /// summary. Distinguishes "we tried and it failed" from every other
    /// reduced-history outcome.
    case fallbackUsed(reason: FallbackReason)

    /// Cooperative cancellation — either the ambient `Task` was already
    /// cancelled before summarization started, or the injected `generate`
    /// closure threw `CancellationError` — cut summarization short. The
    /// strategy returned a tail-only result with no injected summary record.
    case cancelled

    /// ``DefaultCompressionPolicy`` skipped compression entirely because
    /// `contextSize <= reservedTokens` leaves no usable history budget. The
    /// strategy never ran; history is returned unchanged.
    case skippedInsufficientBudget

    /// Every input message was load-bearing (`.system` role, `.memory` kind,
    /// or pinned per the `isPinned` predicate) — there was nothing eligible
    /// to summarize or evict. The strategy returned the load-bearing set
    /// unchanged (not a failure).
    case nothingToSummarize

    /// A zero-inference strategy (`truncating` or `extractive`) reduced the
    /// history by selection rather than summarization. `strategyName` is the
    /// strategy's ``CompressionStrategy/name`` (`"truncating"` /
    /// `"extractive"`) so a consumer observing only the callback can tell
    /// which selection algorithm ran.
    case reduced(strategyName: String)

    /// The input already fit the budget (or was too small to usefully
    /// reduce, e.g. a single over-budget message) — the strategy made no
    /// change.
    case notNeeded

    /// Why ``CompressionOutcome/fallbackUsed(reason:)`` fired.
    public enum FallbackReason: Sendable, Equatable {
        /// The `generate` closure threw a non-cancellation error.
        case summarizerThrew
        /// `generate` returned successfully but the summary was empty/blank
        /// after trimming — including the "no usable summariser" no-op case.
        case emptySummary
    }
}
