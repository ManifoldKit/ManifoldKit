import XCTest
import Foundation
@testable import ManifoldInference
@testable import ManifoldRuntime

/// Unit tests for the late-cancel tombstone in ``InFlightStreamRegistry``
/// (issue #1986, Race 2).
///
/// A late `cancel(_:)` can lose the actor-ordering race against the turn
/// executor's `unregister(handle:)`. Before the tombstone, that meant
/// `markCancelled` returned `nil` and the late cancel was silently dropped —
/// `ConversationRuntime.cancel` bails at `guard let token else { return }`, so
/// `cancelAsync` never fires and the backend keeps generating into a stream the
/// runtime has stopped consuming. The tombstone keeps a recently-unregistered
/// handle resolvable so the late cancel still tears the backend down.
///
/// `InFlightStreamRegistry` is an `actor` reached via `@testable import`. A
/// driving clock is injected so the retention-window bound is deterministic
/// (no real sleeps, no `Task.yield()` fragility).
final class InFlightStreamRegistryTombstoneTests: XCTestCase {

    private func makeToken(_ raw: UInt64) -> InferenceService.GenerationRequestToken {
        InferenceService.GenerationRequestToken(rawValue: raw)
    }

    // MARK: - Race 2: late cancel after unregister still resolves a token

    /// The core fix. After `unregister`, a late `markCancelled` must still
    /// resolve the token so the caller can issue `cancelAsync` and tear the
    /// backend down.
    ///
    /// Sabotage: drop the tombstone (make `unregister` forget the token and
    /// `markCancelled` resolve only against `entries`) → `late` is `nil` → the
    /// `XCTUnwrap` fails. The "generations continuing past cancel" count is
    /// modelled directly: a resolved token means exactly one `cancelAsync`
    /// would fire, so zero backend work continues; a `nil` means the late
    /// cancel is a no-op and the backend keeps running.
    func test_lateCancelAfterUnregister_stillResolvesToken() async throws {
        let registry = InFlightStreamRegistry()
        let handle = ConversationStreamHandle()
        let token = makeToken(7)

        await registry.register(handle: handle, token: token)

        // Turn drains and unregisters — the boundary the late cancel races.
        await registry.unregister(handle: handle)

        // Late cancel arrives after the entry is gone.
        let late = await registry.markCancelled(handle)

        let resolved = try XCTUnwrap(
            late,
            "Late cancel after unregister must resolve the token via the tombstone so the backend is torn down; a nil here is the silent no-op the fix closes."
        )
        XCTAssertEqual(resolved, token)

        // Model the deliverable assertion: count of generations that would
        // continue past the cancel. A resolved token => one cancelAsync fires
        // => zero continue. (With the bug, late == nil => one continues.)
        let generationsContinuingPastCancel = (late == nil) ? 1 : 0
        XCTAssertEqual(
            generationsContinuingPastCancel, 0,
            "A late cancel must tear the backend down — no generation may continue past cancel."
        )
    }

    // MARK: - Live entry still wins (no behavioural regression)

    /// When the handle is still registered, `markCancelled` resolves against the
    /// live entry exactly as before the tombstone existed.
    func test_cancelWhileRegistered_resolvesLiveEntry() async throws {
        let registry = InFlightStreamRegistry()
        let handle = ConversationStreamHandle()
        let token = makeToken(11)

        await registry.register(handle: handle, token: token)
        let live = await registry.markCancelled(handle)
        let resolved = try XCTUnwrap(live)
        XCTAssertEqual(resolved, token)
        let cancelled = await registry.isCancelled(handle)
        XCTAssertTrue(cancelled)
    }

    // MARK: - Never-registered handle resolves nil

    func test_cancelUnknownHandle_resolvesNil() async {
        let registry = InFlightStreamRegistry()
        let resolved = await registry.markCancelled(ConversationStreamHandle())
        XCTAssertNil(resolved, "A handle that was never registered has no token to resolve.")
    }

    // MARK: - Bound: retention window prunes stale tombstones

    /// The tombstone is time-bounded: once the retention window elapses a late
    /// cancel no longer resolves. Driven by an injected clock so the bound is
    /// deterministic.
    func test_tombstoneExpiresAfterRetentionWindow() async throws {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_000))
        let registry = InFlightStreamRegistry(now: clock.now)
        let handle = ConversationStreamHandle()
        await registry.register(handle: handle, token: makeToken(3))
        await registry.unregister(handle: handle)

        // Just inside the window: still resolvable.
        clock.advance(by: 4)
        let stillThere = await registry.markCancelled(handle)
        XCTAssertNotNil(stillThere, "Within the retention window the tombstone must still resolve.")

        // Past the window: pruned.
        clock.advance(by: 10)
        let expired = await registry.markCancelled(ConversationStreamHandle(id: handle.id))
        XCTAssertNil(expired, "Past the retention window the tombstone must be pruned.")
    }

    // MARK: - Bound: ring capacity caps the tombstone map

    /// The tombstone can't grow unbounded even if the clock never advances: a
    /// fixed ring capacity evicts the oldest. Bury well past capacity within the
    /// retention window, then confirm the oldest is gone while a recent one
    /// survives.
    func test_tombstoneRingEvictsOldestPastCapacity() async throws {
        let clock = TestClock(start: Date(timeIntervalSince1970: 2_000))
        let registry = InFlightStreamRegistry(now: clock.now)

        // Capacity is 32; bury 40 distinct handles, all within the window.
        var handles: [ConversationStreamHandle] = []
        for i in 0..<40 {
            let h = ConversationStreamHandle()
            handles.append(h)
            await registry.register(handle: h, token: makeToken(UInt64(i)))
            await registry.unregister(handle: h)
        }

        // The very first buried handle is well past the 32-deep ring → evicted.
        let oldest = await registry.markCancelled(handles[0])
        XCTAssertNil(oldest, "The oldest tombstone must be evicted once capacity (32) is exceeded.")

        // A recent one (within the last 32) survives.
        let recent = await registry.markCancelled(handles[39])
        XCTAssertNotNil(recent, "A recently-buried tombstone within ring capacity must survive.")
    }

    // MARK: - markAllCancelled returns live tokens only

    func test_markAllCancelled_returnsLiveTokens() async {
        let registry = InFlightStreamRegistry()
        let h1 = ConversationStreamHandle()
        let h2 = ConversationStreamHandle()
        await registry.register(handle: h1, token: makeToken(1))
        await registry.register(handle: h2, token: makeToken(2))

        let tokens = await registry.markAllCancelled()
        XCTAssertEqual(Set(tokens), [makeToken(1), makeToken(2)])
    }
}

/// A deterministic, monotonic clock for driving the registry's retention
/// window. Mutated only from the test thread before each `await` hop, so a
/// plain lock-free box is sufficient.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date) { self.current = start }

    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }

    var now: @Sendable () -> Date {
        { [weak self] in
            guard let self else { return Date() }
            self.lock.lock(); defer { self.lock.unlock() }
            return self.current
        }
    }
}
