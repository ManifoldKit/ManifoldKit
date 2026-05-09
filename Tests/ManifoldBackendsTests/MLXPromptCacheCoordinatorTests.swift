#if MLX
import XCTest
@testable import ManifoldMLX

/// Unit tests for prompt-cache coordination helpers that do not touch MLX/Metal runtime state.
final class MLXPromptCacheCoordinatorTests: XCTestCase {
    func test_longestCommonPrefixLength_countsSharedHeadOnly() {
        XCTAssertEqual(
            MLXPromptCacheCoordinator.longestCommonPrefixLength([1, 2, 3, 4], [1, 2, 9, 4]),
            2
        )
        XCTAssertEqual(
            MLXPromptCacheCoordinator.longestCommonPrefixLength([7, 8], [7, 8, 9]),
            2
        )
        XCTAssertEqual(
            MLXPromptCacheCoordinator.longestCommonPrefixLength([1], [2]),
            0
        )
    }

    func test_stateInvalidateClearsSnapshotAndPendingTask() {
        var state = MLXPromptCacheCoordinator.State()
        let task = Task<Void, Never> { }
        state.pendingSnapshotTask = task
        state.snapshot = MLXPromptCacheCoordinator.Snapshot(promptTokens: [1, 2], layers: [])
        let originalToken = state.writeToken

        state.invalidate()

        XCTAssertNil(state.snapshot)
        XCTAssertNil(state.pendingSnapshotTask)
        XCTAssertEqual(state.writeToken, originalToken + 1)
        XCTAssertFalse(state.hasSnapshotOrPending)
        XCTAssertFalse(state.isSnapshotReady)
    }
}
#endif
