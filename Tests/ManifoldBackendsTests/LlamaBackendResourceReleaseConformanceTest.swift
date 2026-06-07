#if Llama && DEBUG
import XCTest
@testable import ManifoldLlama

/// Behavioral proof that dropping a `LlamaBackend` releases its process-lifecycle
/// claim (#1623 class C — "asymmetric sibling").
///
/// This is the runtime counterpart to `BackendDeinitSymmetryAuditTest`, which only
/// *source-scans* `LlamaBackend.deinit` for the release token. The audit proves the
/// release call is present in the text; this proves it actually fires when the
/// instance is dropped. The two together close the gap the footgun audit flagged:
/// a deinit that *looks* symmetric but never runs would pass the scan and leak the
/// claim — only an end-to-end retain/release delta catches that.
///
/// Fast-lane: `LlamaBackend.init()` calls `LlamaBackendProcessLifecycle.retain()`
/// synchronously and `deinit` calls `.release()` — both are pure refcounting (no
/// model load, no Metal), so this runs in the standard `swift test` lane without a
/// GPU or weights. The refcount accessor is `DEBUG`-only, hence the `&& DEBUG` gate.
///
/// - Important: This asserts a **before/after delta** on a process-global refcount.
///   It must not run under `--parallel` alongside other tests that construct and hold
///   `LlamaBackend` instances, or a concurrently-live backend would perturb the count.
///   The pre-push gate (`scripts/test.sh --profile local`) deliberately omits
///   `--parallel` for exactly this class of process-global accounting test.
final class LlamaBackendResourceReleaseConformanceTest: XCTestCase {

    func test_llamaBackend_releasesProcessClaim_onDrop() {
        let before = LlamaBackendProcessLifecycle._refCountForTesting

        var backend: LlamaBackend? = LlamaBackend()
        XCTAssertEqual(
            LlamaBackendProcessLifecycle._refCountForTesting, before + 1,
            "LlamaBackend.init() must retain the process lifecycle"
        )

        backend = nil // deinit -> release()
        XCTAssertEqual(
            LlamaBackendProcessLifecycle._refCountForTesting, before,
            "Dropping LlamaBackend must release its process-lifecycle claim (#1623 class C)"
        )
    }
}
#endif
