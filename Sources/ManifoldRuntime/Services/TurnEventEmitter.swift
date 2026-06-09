import Foundation
import ManifoldInference

/// Narrow, typed seam over the runtime's `@Sendable (ConversationEvent) -> Void`
/// event sink. The turn executor emits ~50 events across the four flows; routing
/// them through this value type gives the emission path a single named owner
/// without changing observable ordering — `emit` forwards straight to the sink.
///
/// Sendability discipline (invariant 5): this holds only the
/// `@Sendable (ConversationEvent) -> Void` closure and MUST NOT capture
/// `InferenceService` or any `@MainActor` state. Adapters that need the raw
/// closure shape (e.g. ``PreToolUseHookAdapter``) read ``sink`` rather than a
/// main-actor-capturing wrapper.
struct TurnEventEmitter: Sendable {
    /// The underlying `@Sendable` sink. Exposed for collaborators that require
    /// the bare closure shape; it is the same value `emit` forwards to.
    let sink: @Sendable (ConversationEvent) -> Void

    init(_ sink: @escaping @Sendable (ConversationEvent) -> Void) {
        self.sink = sink
    }

    func emit(_ event: ConversationEvent) {
        sink(event)
    }
}
