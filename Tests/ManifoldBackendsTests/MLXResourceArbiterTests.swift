#if MLX
import XCTest
@testable import ManifoldBackends
@testable import ManifoldMLX

/// Unit tests for ``MLXResourceArbiter`` — the per-instance cache-claim
/// accounting that prevents multi-MLX hosts from trampling each other's
/// `MLX.Memory.cacheLimit` and prematurely evicting KV-cache residue.
///
/// The arbiter exposes a test-only init that injects recorder closures in
/// place of the real `MLX.Memory.cacheLimit` setter and `clearCache()`
/// invocation. This is required because plain `swift test` doesn't compile
/// the metallib — calling into `MLX.Memory` outside a real model load aborts
/// the process with "Failed to load default metallib" (per CLAUDE.md
/// hardware constraints).
///
/// Real-MLX integration coverage of the arbiter→runtime path lives with
/// `ManifoldMLXIntegrationTests` (Xcode-only).
final class MLXResourceArbiterTests: XCTestCase {

    /// Thread-safe recorder for the closures the arbiter invokes — actor
    /// isolation in the arbiter means writes happen serialized, but the
    /// reads from the test body need cross-actor safety too.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _setCalls: [Int] = []
        private var _clearCount: Int = 0

        var setCalls: [Int] {
            lock.lock(); defer { lock.unlock() }
            return _setCalls
        }

        var clearCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _clearCount
        }

        func recordSet(_ bytes: Int) {
            lock.lock(); defer { lock.unlock() }
            _setCalls.append(bytes)
        }

        func recordClear() {
            lock.lock(); defer { lock.unlock() }
            _clearCount += 1
        }
    }

    /// Builds a fresh arbiter wired to a recorder. Returning the recorder
    /// strongly so the test can inspect it after the arbiter awaits.
    private func makeArbiter() -> (MLXResourceArbiter, Recorder) {
        let recorder = Recorder()
        let arbiter = MLXResourceArbiter(
            setCacheLimit: { [recorder] bytes in recorder.recordSet(bytes) },
            clearCache: { [recorder] in recorder.recordClear() }
        )
        return (arbiter, recorder)
    }

    // MARK: - Single-backend lifecycle

    func test_singleBackend_claimSetsCacheLimit_releaseClearsCache() async {
        let (arbiter, recorder) = makeArbiter()
        let id = UUID()

        await arbiter.claim(backendID: id, requestedCacheBytes: 256 * 1024 * 1024)
        XCTAssertEqual(recorder.setCalls, [256 * 1024 * 1024])
        XCTAssertEqual(recorder.clearCount, 0)
        let activeAfterClaim = await arbiter._activeClaimCountForTesting()
        XCTAssertEqual(activeAfterClaim, 1)

        await arbiter.release(backendID: id)
        XCTAssertEqual(recorder.clearCount, 1, "last release must invoke clearCache")
        // cacheLimit setter must NOT fire on the last release — clearCache
        // is the terminal call.
        XCTAssertEqual(recorder.setCalls.count, 1)
        let activeAfterRelease = await arbiter._activeClaimCountForTesting()
        XCTAssertEqual(activeAfterRelease, 0)
    }

    // MARK: - Two-backend overlap (the I3 motivating bug)

    /// The bug: backend A claims 200 MB, backend B claims 300 MB; the naive
    /// implementation overwrites A's limit with B's value. The arbiter
    /// instead programs the sum (500 MB).
    func test_twoBackends_claimSetsLimitToSum() async {
        let (arbiter, recorder) = makeArbiter()
        let a = UUID()
        let b = UUID()

        await arbiter.claim(backendID: a, requestedCacheBytes: 200)
        await arbiter.claim(backendID: b, requestedCacheBytes: 300)

        XCTAssertEqual(recorder.setCalls, [200, 500],
                       "second claim must reflect sum of A+B, not just B")
        let totalBytes = await arbiter._totalClaimedBytesForTesting()
        XCTAssertEqual(totalBytes, 500)
    }

    /// Releasing one backend out of two: cacheLimit drops to the survivor's
    /// claim; clearCache must NOT fire (the surviving backend's pooled
    /// buffers are still in use).
    func test_twoBackends_releaseOneKeepsOtherBacked() async {
        let (arbiter, recorder) = makeArbiter()
        let a = UUID()
        let b = UUID()
        await arbiter.claim(backendID: a, requestedCacheBytes: 200)
        await arbiter.claim(backendID: b, requestedCacheBytes: 300)

        await arbiter.release(backendID: a)

        XCTAssertEqual(recorder.setCalls, [200, 500, 300],
                       "release of A must reduce limit to B's claim, not clear")
        XCTAssertEqual(recorder.clearCount, 0,
                       "clearCache must not fire while B still holds a claim")
    }

    /// Two-backend full lifecycle: A and B claim, A releases (cache stays),
    /// B releases (cache clears).
    func test_twoBackends_fullLifecycleClearsOnLastRelease() async {
        let (arbiter, recorder) = makeArbiter()
        let a = UUID()
        let b = UUID()

        await arbiter.claim(backendID: a, requestedCacheBytes: 200)
        await arbiter.claim(backendID: b, requestedCacheBytes: 300)
        await arbiter.release(backendID: a)
        await arbiter.release(backendID: b)

        XCTAssertEqual(recorder.clearCount, 1, "clearCache fires exactly once on last release")
        XCTAssertEqual(recorder.setCalls, [200, 500, 300])
    }

    // MARK: - Three-backend stress

    /// Three backends claim, then release in arbitrary order. The cacheLimit
    /// must always reflect the sum of survivors; clearCache must fire only
    /// once and only on the last release.
    func test_threeBackends_releaseInArbitraryOrder() async {
        let (arbiter, recorder) = makeArbiter()
        let a = UUID()
        let b = UUID()
        let c = UUID()

        await arbiter.claim(backendID: a, requestedCacheBytes: 100)
        await arbiter.claim(backendID: b, requestedCacheBytes: 200)
        await arbiter.claim(backendID: c, requestedCacheBytes: 400)
        // Cumulative claim totals: 100, 300, 700
        XCTAssertEqual(recorder.setCalls, [100, 300, 700])

        // Release B first: 100 + 400 = 500
        await arbiter.release(backendID: b)
        // Release A next: 0 + 400 = 400
        await arbiter.release(backendID: a)
        // Release C last: clearCache.
        await arbiter.release(backendID: c)

        XCTAssertEqual(recorder.setCalls, [100, 300, 700, 500, 400],
                       "every non-final release reprograms limit to surviving sum")
        XCTAssertEqual(recorder.clearCount, 1, "clearCache fires exactly once")
    }

    // MARK: - Idempotence + replacement

    /// Re-claiming with the same backend ID replaces the previous value
    /// rather than double-counting.
    func test_reclaim_replacesPreviousValue() async {
        let (arbiter, recorder) = makeArbiter()
        let id = UUID()

        await arbiter.claim(backendID: id, requestedCacheBytes: 100)
        await arbiter.claim(backendID: id, requestedCacheBytes: 250)

        XCTAssertEqual(recorder.setCalls, [100, 250],
                       "second claim from same backend replaces, not adds")
        let total = await arbiter._totalClaimedBytesForTesting()
        XCTAssertEqual(total, 250)
    }

    /// Releasing a backend that holds no claim is a no-op — neither setter
    /// nor clear fires, and any active claims survive.
    func test_releaseUnknownID_isNoOp() async {
        let (arbiter, recorder) = makeArbiter()
        let real = UUID()
        await arbiter.claim(backendID: real, requestedCacheBytes: 100)

        await arbiter.release(backendID: UUID())

        XCTAssertEqual(recorder.setCalls, [100], "no extra setCacheLimit on unknown release")
        XCTAssertEqual(recorder.clearCount, 0, "clearCache must not fire if real claim still active")
        let total = await arbiter._totalClaimedBytesForTesting()
        XCTAssertEqual(total, 100)
    }

    /// Negative requested bytes clamp to zero (defence-in-depth — the real
    /// `MLX.Memory.cacheLimit` setter accepts an `Int` but a negative value
    /// is meaningless).
    func test_negativeBytes_clampToZero() async {
        let (arbiter, recorder) = makeArbiter()
        let id = UUID()

        await arbiter.claim(backendID: id, requestedCacheBytes: -100)

        XCTAssertEqual(recorder.setCalls, [0])
    }

    // MARK: - clearAll

    func test_clearAll_dropsAllClaimsAndInvokesClear() async {
        let (arbiter, recorder) = makeArbiter()
        let a = UUID()
        let b = UUID()
        await arbiter.claim(backendID: a, requestedCacheBytes: 100)
        await arbiter.claim(backendID: b, requestedCacheBytes: 200)

        await arbiter.clearAll()

        XCTAssertEqual(recorder.clearCount, 1)
        let active = await arbiter._activeClaimCountForTesting()
        XCTAssertEqual(active, 0)
        // Subsequent release of a or b must be a no-op.
        await arbiter.release(backendID: a)
        XCTAssertEqual(recorder.clearCount, 1, "release after clearAll must not double-clear")
    }
}
#endif
