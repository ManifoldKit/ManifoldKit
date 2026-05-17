#if Llama && DEBUG
import XCTest
@testable import ManifoldLlama

/// Regression coverage for the process-scoped latch in
/// ``LlamaBackendProcessLifecycle`` (#1319 / #1115).
///
/// Earlier revisions refcounted retain/release pairs and called
/// `llama_backend_free()` when the count hit zero, then re-entered
/// `llama_backend_init()` on the next retain. That cycle is the documented
/// llama.cpp UB (see `docs/LLAMA_CONTRACT.md` "Global Backend Lifecycle")
/// and was the source of the cross-test flakes that the previously-existing
/// `scripts/test-llama-isolated.sh` worked around per-class.
///
/// The fix is a high-watermark latch: init exactly once per process; never
/// free. This suite pins the invariant so a future refactor that re-adds
/// the `llama_backend_free()` call (or otherwise lets the latch flip back
/// to `false`) is caught by CI rather than by intermittent flakes in
/// unrelated suites.
///
/// Sabotage check: re-enable the `if refCount == 0 { llama_backend_free() }`
/// branch in `release()` — the second retain/release pair below will flip
/// `_isInitializedForTesting` between calls and the assertions fail.
final class LlamaBackendProcessLifecycleTests: XCTestCase {

    func test_retainRelease_latchInitializesExactlyOnceAcrossCycles() {
        // First cycle: retain initialises the backend if it wasn't already
        // (a prior test in this process may have done so — we don't depend
        // on the absolute starting state, only on the invariant that the
        // latch stays `true` from the first retain onward).
        LlamaBackendProcessLifecycle.retain()
        XCTAssertTrue(
            LlamaBackendProcessLifecycle._isInitializedForTesting,
            "First retain must leave the latch initialized"
        )
        let countAfterFirstRetain = LlamaBackendProcessLifecycle._refCountForTesting
        XCTAssertGreaterThanOrEqual(countAfterFirstRetain, 1)

        LlamaBackendProcessLifecycle.release()
        XCTAssertTrue(
            LlamaBackendProcessLifecycle._isInitializedForTesting,
            "release() must NOT call llama_backend_free — the latch stays true to prevent the documented init/free cycle UB"
        )

        // Second cycle: if `release()` had freed the backend, this `retain()`
        // would re-enter `llama_backend_init()` (the UB). The latch must
        // already report initialized so retain skips the init call.
        let wasInitializedBeforeSecondRetain = LlamaBackendProcessLifecycle._isInitializedForTesting
        LlamaBackendProcessLifecycle.retain()
        XCTAssertTrue(
            wasInitializedBeforeSecondRetain,
            "Latch must remain true between retain/release cycles"
        )
        XCTAssertTrue(
            LlamaBackendProcessLifecycle._isInitializedForTesting,
            "Second retain must leave the latch initialized"
        )
        LlamaBackendProcessLifecycle.release()
    }

    func test_refCount_dipsToZero_withoutFlippingLatch() {
        // Drive the refcount to a known delta-from-baseline and back, then
        // assert the latch is still `true`. This is the exact pattern that
        // the test suite hits naturally — each test allocates a backend
        // (retain) and releases it on deinit, so the count routinely returns
        // to its baseline between tests.
        let baseline = LlamaBackendProcessLifecycle._refCountForTesting
        LlamaBackendProcessLifecycle.retain()
        LlamaBackendProcessLifecycle.retain()
        LlamaBackendProcessLifecycle.release()
        LlamaBackendProcessLifecycle.release()
        XCTAssertEqual(
            LlamaBackendProcessLifecycle._refCountForTesting,
            baseline,
            "retain/release must be balanced"
        )
        XCTAssertTrue(
            LlamaBackendProcessLifecycle._isInitializedForTesting,
            "Latch must stay true even when refcount returns to baseline — this is the #1319 invariant"
        )
    }
}
#endif
