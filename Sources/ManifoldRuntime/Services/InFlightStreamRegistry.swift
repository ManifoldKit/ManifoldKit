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

    // MARK: Tombstones (issue #1986)
    //
    // A late `cancel(_:)` can race the turn executor's `unregister(handle:)`.
    // If unregister wins the actor-ordering race, the entry is already gone,
    // so `markCancelled` used to return `nil` and the late cancel was silently
    // dropped — leaving the backend generating into a stream the runtime has
    // stopped consuming. To close that window, `unregister` parks the handle's
    // token in a short-lived tombstone instead of forgetting it outright, so a
    // late `markCancelled` still resolves a token and the caller can issue
    // `cancelAsync` to tear the backend down.
    //
    // The tombstone is bounded two ways so it can't grow unbounded: a fixed
    // ring capacity (oldest evicted first) and a wall-clock retention window
    // (stale entries pruned on access). Both are small — the race window the
    // tombstone covers is the few-millisecond gap between unregister and a
    // concurrent cancel hop, not a durable cache.
    private struct Tombstone {
        let token: InferenceService.GenerationRequestToken
        let buriedAt: Date
    }
    private var tombstones: [UUID: Tombstone] = [:]
    private var tombstoneOrder: [UUID] = []

    /// Maximum number of recently-unregistered handles to retain. Bounds the
    /// tombstone map regardless of clock behaviour.
    private let tombstoneCapacity = 32

    /// How long a tombstone stays resolvable after `unregister`. Comfortably
    /// covers the unregister↔cancel actor-hop race without retaining state for
    /// long-finished turns.
    private let tombstoneRetention: TimeInterval = 5

    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func register(handle: ConversationStreamHandle, token: InferenceService.GenerationRequestToken) {
        entries[handle.id] = token
        // A handle id is never reused, but clear any stale tombstone defensively
        // so a re-registered id resolves against the live entry.
        removeTombstone(handle.id)
    }

    func unregister(handle: ConversationStreamHandle) {
        if let token = entries.removeValue(forKey: handle.id) {
            buryTombstone(handle.id, token: token)
        }
        cancelled.remove(handle.id)
    }

    /// Marks a handle cancelled and returns its inference token (if any) so
    /// the caller can issue ``InferenceService/cancelAsync(_:)`` against it.
    ///
    /// Resolves against the live entry first and, failing that, against a
    /// recently-buried tombstone (issue #1986) — so a `cancel(_:)` that loses
    /// the actor race against `unregister(handle:)` still tears the backend
    /// down instead of becoming a silent no-op. Returns `nil` only when the
    /// handle was never registered or its tombstone has already expired.
    func markCancelled(_ handle: ConversationStreamHandle) -> InferenceService.GenerationRequestToken? {
        cancelled.insert(handle.id)
        if let token = entries[handle.id] {
            return token
        }
        pruneExpiredTombstones()
        return tombstones[handle.id]?.token
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

    // MARK: - Tombstone bookkeeping

    private func buryTombstone(_ id: UUID, token: InferenceService.GenerationRequestToken) {
        pruneExpiredTombstones()
        if tombstones[id] == nil {
            tombstoneOrder.append(id)
        }
        tombstones[id] = Tombstone(token: token, buriedAt: now())
        // Ring eviction: drop the oldest while over capacity.
        while tombstoneOrder.count > tombstoneCapacity {
            let oldest = tombstoneOrder.removeFirst()
            tombstones.removeValue(forKey: oldest)
        }
    }

    private func removeTombstone(_ id: UUID) {
        guard tombstones.removeValue(forKey: id) != nil else { return }
        if let idx = tombstoneOrder.firstIndex(of: id) {
            tombstoneOrder.remove(at: idx)
        }
    }

    private func pruneExpiredTombstones() {
        let cutoff = now().addingTimeInterval(-tombstoneRetention)
        guard !tombstones.isEmpty else { return }
        tombstoneOrder.removeAll { id in
            if let stone = tombstones[id], stone.buriedAt < cutoff {
                tombstones.removeValue(forKey: id)
                return true
            }
            return false
        }
    }
}
