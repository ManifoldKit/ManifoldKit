#if MLX
import XCTest
import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends
@testable import ManifoldMLX

/// Behavioral proof that dropping an `MLXBackend` releases its `MLXResourceArbiter`
/// claim (#1623 class C — "asymmetric sibling").
///
/// This is the Metal companion to `LlamaBackendResourceReleaseConformanceTest`
/// (fast-lane, refcount-only) and the runtime counterpart to
/// `BackendDeinitSymmetryAuditTest`'s source scan. The audit proves the release
/// token is present in `MLXBackend.deinit`; the two behavioral tests prove the
/// release actually fires. The MLX deinit leak the footgun audit flagged would
/// have been caught here: a backend that claims an arbiter slot on `loadModel` but
/// never releases it leaves `MLX.Memory.clearCache()`'s last-release guarantee
/// permanently un-fired, and this test would see the active-claim count never drop.
///
/// Unlike the Llama claim — synchronous in `init` — the MLX claim is only
/// established **after a real model load** (`MLXResourceArbiter.shared.claim(...)`
/// runs once the container loads on Metal). So this proof cannot live in the
/// fast-lane: it requires Apple Silicon + a Metal device + a discoverable on-disk
/// MLX model, and is skipped otherwise. Release is also **asynchronous** —
/// `deinit` schedules `MLXResourceArbiter.shared.release(backendID:)` in a
/// `Task.detached` that first awaits the prior cleanup task — so the test polls the
/// active-claim count against a deadline rather than asserting immediately.
@MainActor
final class MLXBackendResourceReleaseIntegrationTest: XCTestCase {

    func test_mlxBackend_releasesArbiterClaim_onDrop() async throws {
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "Requires Apple Silicon")
        try XCTSkipUnless(HardwareRequirements.hasMetalDevice, "Requires Metal GPU")

        guard let mlxDir = HardwareRequirements.findMLXModelDirectory() else {
            throw XCTSkip(
                "No loadable MLX model found on disk. Install a local MLX snapshot with config.json, tokenizer, and safetensors weights."
            )
        }

        let before = await MLXResourceArbiter.shared._activeClaimCountForTesting()

        var backend: MLXBackend? = MLXBackend()
        try await backend!.loadModel(from: mlxDir, plan: .testStub(effectiveContextSize: 2048))

        let claimed = await MLXResourceArbiter.shared._activeClaimCountForTesting()
        XCTAssertEqual(claimed, before + 1, "loadModel must claim an arbiter slot")

        backend = nil // deinit -> Task.detached -> release (async)

        // Poll until the claim drops back to baseline or a ~5s deadline elapses.
        // Release is async (chained behind the prior cleanup task), so an immediate
        // read after `= nil` would race the detached release.
        var released = false
        for _ in 0..<50 {
            if await MLXResourceArbiter.shared._activeClaimCountForTesting() == before {
                released = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(
            released,
            "Dropping MLXBackend must release its arbiter claim (#1623 class C)"
        )
    }
}
#endif
