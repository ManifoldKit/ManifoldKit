import Foundation
import ManifoldInference

/// Stateful per-stream consumer that maps SSE / NDJSON frame payloads to
/// ``GenerationEvent`` sequences.
///
/// The stateless ``SSEPayloadHandler`` surface can only emit events whose
/// decision is local to a single frame (`.token`, `.thinkingToken`, raw
/// `.usage`). Real provider streams also carry events whose extraction
/// requires cross-frame state — index-keyed tool-call delta buffers, the
/// open-thinking flag, the once-only tool-call finalisation guard,
/// `finish_reason`-triggered drains. `CloudStreamEventConsumer` is the
/// envelope-facing surface for that state.
///
/// ### Lifecycle
///
/// `CloudRoutedStreamParser` obtains a fresh consumer at
/// stream open by invoking ``CloudAdapterRouting/streamConsumerFactory``
/// (when non-nil), drives ``consume(payload:)`` for each frame, and calls
/// ``finish(cancelled:)`` exactly once at stream end. Implementations must
/// keep all per-stream state internal so a second generation gets a clean
/// instance — the factory pattern enforces this at the type system level.
public protocol CloudStreamEventConsumer: AnyObject, Sendable {
    /// Returns the event sequence to emit for one frame's decoded payload.
    /// May emit zero events for non-content frames (heartbeats, role-only
    /// chunks).
    func consume(payload: String) -> [GenerationEvent]

    /// Returns the event sequence to emit for one already-parsed frame.
    ///
    /// Real extractors override this to read off `frame.json` /
    /// `frame.namedEvent` instead of re-parsing the payload string 8–12×.
    /// The default delegates to ``consume(payload:)`` so conformers that
    /// haven't migrated keep working.
    func consume(frame: ParsedFrame) -> [GenerationEvent]

    /// Flushes pending state at stream end. Implementations yield any
    /// open-thinking close (`.thinkingCompleted`) and any buffered tool
    /// calls the upstream never accompanied with an explicit
    /// `finish_reason`. Pass `cancelled: true` to suppress phantom tool
    /// emissions when the consumer is being dropped mid-stream.
    func finish(cancelled: Bool) -> [GenerationEvent]
}

public extension CloudStreamEventConsumer {
    /// Default: delegate to the string surface so un-migrated consumers
    /// keep compiling. The three real cloud extractors override this.
    func consume(frame: ParsedFrame) -> [GenerationEvent] {
        consume(payload: frame.raw)
    }
}
