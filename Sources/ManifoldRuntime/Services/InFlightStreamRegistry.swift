import Foundation
import ManifoldInference

// MARK: - In-flight stream registry
//
// Holds the mutable state ConversationRuntime needs across actor hops: the
// set of in-flight stream handles and their underlying inference tokens, so
// `cancel(_:)` can target the right backend call and the send loop can
// detect cancellation.
//
// An actor (rather than a lock) because cancel is `async` already (it has
// to hop to @MainActor to call `cancelAsync`) and the bookkeeping reads
// cleanly with structured concurrency. Performance is a non-issue — this
// state is touched twice per turn.

actor InFlightStreamRegistry {
    private var entries: [UUID: InferenceService.GenerationRequestToken] = [:]
    private var cancelled: Set<UUID> = []

    func register(handle: ConversationStreamHandle, token: InferenceService.GenerationRequestToken) {
        entries[handle.id] = token
    }

    func unregister(handle: ConversationStreamHandle) {
        entries.removeValue(forKey: handle.id)
        cancelled.remove(handle.id)
    }

    /// Marks a handle cancelled and returns its inference token (if any) so
    /// the caller can issue ``InferenceService/cancelAsync(_:)`` against it.
    /// Returns `nil` when the handle has already been unregistered or was
    /// never registered (cancel races with stream completion are normal).
    func markCancelled(_ handle: ConversationStreamHandle) -> InferenceService.GenerationRequestToken? {
        cancelled.insert(handle.id)
        return entries[handle.id]
    }

    /// Marks every active handle cancelled and returns the tokens that should
    /// be forwarded to ``InferenceService/cancelAsync(_:)`` during teardown.
    func markAllCancelled() -> [InferenceService.GenerationRequestToken] {
        cancelled.formUnion(entries.keys)
        return Array(entries.values)
    }

    func isCancelled(_ handle: ConversationStreamHandle) -> Bool {
        cancelled.contains(handle.id)
    }
}
