#if MLX
import XCTest
import MLXLMCommon
@testable import ManifoldMLX

/// Unit tests for prompt-cache coordination helpers that do not touch MLX/Metal
/// runtime state (no `eval`, no tensor materialisation).
final class MLXPromptCacheCoordinatorTests: XCTestCase {

    private typealias Coordinator = MLXPromptCacheCoordinator
    private typealias PlanInput = MLXPromptCacheCoordinator.LayerReusePlanInput
    private typealias Reason = MLXPromptCacheCoordinator.PromptCacheReuseReason

    // MARK: - longest common prefix (unchanged)

    func test_longestCommonPrefixLength_countsSharedHeadOnly() {
        XCTAssertEqual(
            Coordinator.longestCommonPrefixLength([1, 2, 3, 4], [1, 2, 9, 4]),
            2
        )
        XCTAssertEqual(
            Coordinator.longestCommonPrefixLength([7, 8], [7, 8, 9]),
            2
        )
        XCTAssertEqual(
            Coordinator.longestCommonPrefixLength([1], [2]),
            0
        )
    }

    func test_stateInvalidateClearsSnapshotAndPendingTask() {
        var state = Coordinator.State()
        let task = Task<Void, Never> { }
        state.pendingSnapshotTask = task
        state.snapshot = Coordinator.Snapshot(promptTokens: [1, 2], layers: [])
        let originalToken = state.writeToken

        state.invalidate()

        XCTAssertNil(state.snapshot)
        XCTAssertNil(state.pendingSnapshotTask)
        XCTAssertEqual(state.writeToken, originalToken + 1)
        XCTAssertFalse(state.hasSnapshotOrPending)
        XCTAssertFalse(state.isSnapshotReady)
    }

    // MARK: - layerCanReduce: the shared trim/continuation rule

    func test_layerCanReduce_verbatimContinuationAllowedForAnyType() {
        // excess == 0 (offset already equals target) is valid even when the
        // cache is NOT trimmable — this is the safe path for recurrent layers.
        XCTAssertTrue(
            Coordinator.layerCanReduce(currentOffset: 10, targetOffset: 10, isTrimmable: false)
        )
    }

    func test_layerCanReduce_trimNeededRequiresTrimmable() {
        XCTAssertTrue(
            Coordinator.layerCanReduce(currentOffset: 10, targetOffset: 6, isTrimmable: true)
        )
        XCTAssertFalse(
            Coordinator.layerCanReduce(currentOffset: 10, targetOffset: 6, isTrimmable: false)
        )
        // Cannot grow a cache to a longer prefix than it holds.
        XCTAssertFalse(
            Coordinator.layerCanReduce(currentOffset: 4, targetOffset: 6, isTrimmable: true)
        )
    }

    // MARK: - planReuse: type-aware, per-layer eligibility

    private func simpleLayer(offset: Int) -> PlanInput {
        PlanInput(
            snapshotTypeName: "KVCacheSimple",
            snapshotOffset: offset,
            snapshotStateIsEmpty: false,
            liveTypeName: "KVCacheSimple",
            liveIsTrimmable: true,
            liveIsKVCacheSimple: true
        )
    }

    /// A non-`KVCacheSimple` but trimmable layer (e.g. a sliding-window cache).
    private func trimmableNonSimpleLayer(typeName: String, offset: Int) -> PlanInput {
        PlanInput(
            snapshotTypeName: typeName,
            snapshotOffset: offset,
            snapshotStateIsEmpty: false,
            liveTypeName: typeName,
            liveIsTrimmable: true,
            liveIsKVCacheSimple: false
        )
    }

    /// A non-trimmable recurrent layer (e.g. `MambaCache`).
    private func recurrentLayer(typeName: String, offset: Int) -> PlanInput {
        PlanInput(
            snapshotTypeName: typeName,
            snapshotOffset: offset,
            snapshotStateIsEmpty: false,
            liveTypeName: typeName,
            liveIsTrimmable: false,
            liveIsKVCacheSimple: false
        )
    }

    func test_planReuse_homogeneousSimple_reuses() {
        let reason = Coordinator.planReuse(
            layers: [simpleLayer(offset: 8), simpleLayer(offset: 8)],
            liveLayerCount: 2,
            reusedCount: 5
        )
        XCTAssertEqual(reason, .reused(promptTokensReused: 5))
    }

    func test_planReuse_mixedTrimmableTypes_reuses_acceptance1() {
        // Acceptance #1: a hybrid composition (KVCacheSimple + a different
        // trimmable type) is NO LONGER disqualified by the old
        // `allSatisfy { $0 is KVCacheSimple }` homogeneity gate. The reused
        // token count is the byte-exact common-prefix length (> 0), proving the
        // sliceable layers are reused rather than re-prefilled.
        let reason = Coordinator.planReuse(
            layers: [
                simpleLayer(offset: 12),
                trimmableNonSimpleLayer(typeName: "RotatingKVCache", offset: 12),
                simpleLayer(offset: 12),
            ],
            liveLayerCount: 3,
            reusedCount: 7
        )
        XCTAssertEqual(reason, .reused(promptTokensReused: 7))
        // Sabotage guard documentation: had the old all-or-nothing gate
        // survived, a single non-Simple layer would force a full miss here.
        XCTAssertTrue(reason.didReuse)
    }

    func test_planReuse_recurrentLayerAtCleanContinuation_reuses() {
        // A recurrent (non-trimmable) layer is reusable when the reuse length
        // exactly equals its cached prefix (no trim needed) — the byte-exact
        // continuation case. The trimmable neighbours are happy to trim.
        let reason = Coordinator.planReuse(
            layers: [
                simpleLayer(offset: 9),
                recurrentLayer(typeName: "MambaCache", offset: 9),
            ],
            liveLayerCount: 2,
            reusedCount: 9
        )
        XCTAssertEqual(reason, .reused(promptTokensReused: 9))
    }

    func test_planReuse_recurrentLayerNeedingTrim_declinesWithDiagnostic_acceptance3() {
        // Acceptance #3: a genuinely non-reusable cache type (recurrent layer
        // that would need to be trimmed below its cached prefix) yields a
        // diagnostic reason naming the layer + type — not a silent full prefill.
        let reason = Coordinator.planReuse(
            layers: [
                simpleLayer(offset: 9),
                recurrentLayer(typeName: "MambaCache", offset: 9),
            ],
            liveLayerCount: 2,
            reusedCount: 4
        )
        XCTAssertEqual(reason, .layerNotReusable(layerIndex: 1, cacheTypeName: "MambaCache"))
        XCTAssertFalse(reason.didReuse)
    }

    func test_planReuse_layerCountMismatch_declines() {
        let reason = Coordinator.planReuse(
            layers: [simpleLayer(offset: 8)],
            liveLayerCount: 2,
            reusedCount: 4
        )
        XCTAssertEqual(reason, .layerCountMismatch(snapshot: 1, live: 2))
    }

    func test_planReuse_typeMismatch_declines() {
        let drifted = PlanInput(
            snapshotTypeName: "KVCacheSimple",
            snapshotOffset: 8,
            snapshotStateIsEmpty: false,
            liveTypeName: "RotatingKVCache",
            liveIsTrimmable: true,
            liveIsKVCacheSimple: false
        )
        let reason = Coordinator.planReuse(
            layers: [drifted],
            liveLayerCount: 1,
            reusedCount: 4
        )
        XCTAssertEqual(
            reason,
            .layerTypeMismatch(layerIndex: 0, expected: "KVCacheSimple", found: "RotatingKVCache")
        )
    }

    func test_planReuse_zeroReuse_declinesNoCommonPrefix() {
        let reason = Coordinator.planReuse(
            layers: [simpleLayer(offset: 8)],
            liveLayerCount: 1,
            reusedCount: 0
        )
        XCTAssertEqual(reason, .noCommonPrefix)
    }

    func test_planReuse_emptyStateNonSimpleLayer_declines() {
        let emptyRecurrent = PlanInput(
            snapshotTypeName: "MambaCache",
            snapshotOffset: 6,
            snapshotStateIsEmpty: true,
            liveTypeName: "MambaCache",
            liveIsTrimmable: false,
            liveIsKVCacheSimple: false
        )
        let reason = Coordinator.planReuse(
            layers: [emptyRecurrent],
            liveLayerCount: 1,
            reusedCount: 6
        )
        XCTAssertEqual(reason, .layerNotReusable(layerIndex: 0, cacheTypeName: "MambaCache"))
    }

    // MARK: - planInputs wiring with real MLX cache objects (no eval / Metal)

    /// `KVCacheSimple()` / `MambaCache()` allocate plain Swift/CPU state in their
    /// initialisers — constructing them and reading `offset` / `isTrimmable` /
    /// type identity touches no Metal device, so this runs in CI.
    func test_planInputs_readsTypeAndTrimmability_fromLiveCaches() {
        let snapshot = Coordinator.Snapshot(
            promptTokens: [1, 2, 3, 4, 5],
            layers: [
                Coordinator.CachedLayerState(
                    cacheTypeName: "KVCacheSimple", offset: 5, state: [], metaState: [""]),
                Coordinator.CachedLayerState(
                    cacheTypeName: "MambaCache", offset: 5, state: [], metaState: [""]),
            ]
        )
        let live: [any KVCache] = [KVCacheSimple(), MambaCache()]

        let inputs = Coordinator.planInputs(live: live, snapshot: snapshot)

        XCTAssertEqual(inputs.count, 2)
        XCTAssertEqual(inputs[0].liveTypeName, "KVCacheSimple")
        XCTAssertTrue(inputs[0].liveIsKVCacheSimple)
        XCTAssertTrue(inputs[0].liveIsTrimmable)
        XCTAssertEqual(inputs[1].liveTypeName, "MambaCache")
        XCTAssertFalse(inputs[1].liveIsKVCacheSimple)
        XCTAssertFalse(inputs[1].liveIsTrimmable, "MambaCache is a non-trimmable recurrent cache")
    }
}
#endif
