import Foundation
import NaturalLanguage

/// Coalesces a token/fragment stream into completed sentence-granularity
/// segments for opt-in, consumer-side accessibility use (TTS readback, paced
/// VoiceOver / live-region announcements).
///
/// ## Why this is a standalone utility and *not* a `GenerationEvent` case
///
/// The `GenerationEvent` vocabulary is **frozen for 1.0** (see the doc comment
/// at the top of ``GenerationEvent``). Sentence segmentation is a *derived*,
/// *opt-in*, consumer-side concern: it is a function of the existing
/// ``GenerationEvent/token(_:)`` deltas and adds no information a backend
/// produces. Surfacing it as a new primary event case would pollute the cross-
/// module backend vocabulary every consumer must switch over, for a feature only
/// readback layers need. So this lives *out of band* as a composable utility:
/// nothing in the default generation path constructs or calls it.
///
/// ## Placement
///
/// This sits in `ManifoldContract` alongside the other generation streaming
/// types (``GenerationEvent``, `GenerationStream`, `StreamTransform`,
/// `ThinkingTransform`) because it operates purely on the token-delta stream
/// those types define. `NaturalLanguage` is an Apple *system* framework, so
/// importing it adds no third-party weight to this leaf-adjacent module — the
/// same idiom already ships in `ManifoldRuntime`'s `DocumentChunker`.
///
/// ## Boundary detection
///
/// Detection uses `NLTokenizer(unit: .sentence)`, which handles English, CJK,
/// and the other languages Apple's NLP stack supports. Because tokens arrive
/// incrementally and a sentence boundary may not yet be decidable from the
/// fragments seen so far, the coalescer is *conservative*: it only emits a
/// segment once at least one *subsequent* sentence has started, i.e. the
/// tokenizer reports more than one sentence in the buffer. Everything up to the
/// final detected sentence start is emitted and removed from the buffer; the
/// trailing (possibly-incomplete) sentence stays buffered until either more
/// fragments confirm a later boundary or ``flush()`` drains it at end-of-stream.
///
/// ```swift
/// var coalescer = SentenceCoalescer()
/// for fragment in ["Hello", " wor", "ld. How", " are you?", " I'm fine"] {
///     for sentence in coalescer.push(fragment) {
///         speak(sentence)   // "Hello world. ", then "How are you? "
///     }
/// }
/// if let tail = coalescer.flush() { speak(tail) }  // "I'm fine"
/// ```
///
/// For an `AsyncSequence` ergonomic entry point see
/// ``Swift/AsyncSequence/coalescedSentences()`` and
/// ``Swift/AsyncSequence/coalescedSentences()-(GenerationEvent)``.
package struct SentenceCoalescer: Sendable {

    /// Fragments accumulated since the last emitted segment.
    private var buffer: String = ""

    package init() {}

    /// Accumulates `tokenFragment` and returns zero or more newly-completed
    /// sentence segments.
    ///
    /// A segment is emitted only once a *later* sentence has started in the
    /// buffer, which is how we know the earlier sentence's boundary is final.
    /// The trailing incomplete sentence remains buffered. Emitted segments
    /// retain their original whitespace (so they re-join losslessly).
    package mutating func push(_ tokenFragment: String) -> [String] {
        guard !tokenFragment.isEmpty else { return [] }
        buffer += tokenFragment
        return drainCompletedSentences()
    }

    /// Returns any buffered remainder at end-of-stream so the final partial
    /// sentence is not lost, or `nil` if the buffer is empty.
    ///
    /// After this call the buffer is empty; the coalescer can be reused.
    package mutating func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        let remainder = buffer
        buffer = ""
        return remainder
    }

    // MARK: - Boundary detection

    /// Splits the buffer at every confirmed sentence boundary, returning the
    /// completed sentences and leaving the trailing (final) sentence buffered.
    private mutating func drainCompletedSentences() -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = buffer

        // Collect sentence ranges. The *last* range is treated as possibly
        // incomplete and stays buffered; everything before it is confirmed.
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: buffer.startIndex..<buffer.endIndex) { range, _ in
            ranges.append(range)
            return true
        }

        // Fewer than two sentences: nothing is confirmed complete yet.
        guard ranges.count > 1 else { return [] }

        var completed: [String] = []
        // The split point is the start of the final (still-open) sentence. We
        // emit substrings of the buffer up to that index so inter-sentence
        // whitespace is preserved on the *earlier* sentence, matching how a
        // reader pauses after a sentence.
        let lastStart = ranges[ranges.count - 1].lowerBound

        for range in ranges.dropLast() {
            completed.append(String(buffer[range]))
        }

        buffer = String(buffer[lastStart...])
        return completed
    }
}

// MARK: - AsyncSequence ergonomics

extension AsyncSequence where Element == String, Self: Sendable {
    /// Wraps a stream of token fragments, yielding completed sentence segments
    /// and the trailing remainder when the upstream stream ends.
    ///
    /// Input element type is `String` (raw token fragments) — chosen as the
    /// cleanest, most general entry point; callers driving a `GenerationEvent`
    /// stream use ``Swift/AsyncSequence/coalescedSentences()-(GenerationEvent)``
    /// which extracts `.token` payloads.
    ///
    /// Cancellation propagates naturally: the underlying `for await` loop throws
    /// `CancellationError` out of the producing `Task` and the stream finishes
    /// without emitting a flushed remainder.
    public func coalescedSentences() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var coalescer = SentenceCoalescer()
                do {
                    for try await fragment in self {
                        try Task.checkCancellation()
                        for sentence in coalescer.push(fragment) {
                            continuation.yield(sentence)
                        }
                    }
                    if let tail = coalescer.flush() {
                        continuation.yield(tail)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension AsyncSequence where Element == GenerationEvent, Self: Sendable {
    /// Wraps a `GenerationEvent` stream, extracting ``GenerationEvent/token(_:)``
    /// payloads into the coalescer and yielding completed sentence segments.
    ///
    /// Non-`.token` events (usage, tool calls, thinking tokens, …) are ignored —
    /// only the visible content stream feeds the readback segmenter. The trailing
    /// remainder is flushed when the upstream stream ends (its terminal event,
    /// whatever it is, simply ends the sequence).
    public func coalescedSentences() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var coalescer = SentenceCoalescer()
                do {
                    for try await event in self {
                        try Task.checkCancellation()
                        guard case .token(let fragment) = event else { continue }
                        for sentence in coalescer.push(fragment) {
                            continuation.yield(sentence)
                        }
                    }
                    if let tail = coalescer.flush() {
                        continuation.yield(tail)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
