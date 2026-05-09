import XCTest
@testable import ManifoldInference

final class DownloadStateTests: XCTestCase {

    // MARK: - Helpers

    private func makeModel() -> DownloadableModel {
        DownloadableModel(
            repoID: "test/repo",
            fileName: "model.gguf",
            displayName: "Test Model",
            modelType: .gguf,
            sizeBytes: 1_000_000
        )
    }

    // MARK: - Initial State

    func test_initialStatus_isQueued() {
        let state = DownloadState(model: makeModel())

        if case .queued = state.status {
            // expected
        } else {
            XCTFail("Expected .queued, got \(state.status)")
        }
    }

    func test_id_matchesModelID() {
        let model = makeModel()
        let state = DownloadState(model: model)

        XCTAssertEqual(state.id, model.id)
    }

    // MARK: - updateProgress

    func test_updateProgress_calculatesCorrectFraction() {
        let state = DownloadState(model: makeModel())

        state.updateProgress(bytesDownloaded: 500, totalBytes: 1000)

        if case .downloading(let progress, let downloaded, let total) = state.status {
            XCTAssertEqual(progress, 0.5, accuracy: 0.001)
            XCTAssertEqual(downloaded, 500)
            XCTAssertEqual(total, 1000)
        } else {
            XCTFail("Expected .downloading, got \(state.status)")
        }
    }

    func test_updateProgress_totalBytesZero_fractionIsZero() {
        let state = DownloadState(model: makeModel())

        state.updateProgress(bytesDownloaded: 100, totalBytes: 0)

        if case .downloading(let progress, _, _) = state.status {
            XCTAssertEqual(progress, 0.0, accuracy: 0.001,
                           "Division by zero should be avoided; fraction should be 0")
        } else {
            XCTFail("Expected .downloading, got \(state.status)")
        }
    }

    func test_updateProgress_fullDownload_fractionIsOne() {
        let state = DownloadState(model: makeModel())

        state.updateProgress(bytesDownloaded: 2000, totalBytes: 2000)

        if case .downloading(let progress, _, _) = state.status {
            XCTAssertEqual(progress, 1.0, accuracy: 0.001)
        } else {
            XCTFail("Expected .downloading, got \(state.status)")
        }
    }

    func test_updateProgress_bytesExceedTotal_fractionClampedToOne() {
        // Snapshot file sizes sometimes exceed the pre-download estimate, making
        // bytesDownloaded > totalBytes. The fraction must be clamped to 1.0 so
        // ProgressView(value:) does not receive an out-of-range value and log a warning.
        let state = DownloadState(model: makeModel())

        state.updateProgress(bytesDownloaded: 1500, totalBytes: 1000)

        if case .downloading(let progress, let downloaded, let total) = state.status {
            XCTAssertEqual(progress, 1.0, accuracy: 0.001,
                           "Fraction must be clamped to 1.0 when bytes exceed the estimate")
            XCTAssertEqual(downloaded, 1500, "Raw byte count must be preserved for display")
            XCTAssertEqual(total, 1000, "Raw total must be preserved for display")
        } else {
            XCTFail("Expected .downloading, got \(state.status)")
        }

        // Sabotage check: remove the min(1.0, ...) clamp in updateProgress and the
        // fraction assertion above will fail with 1.5 instead of 1.0.
    }

    // MARK: - State Transitions

    func test_markCompleted_setsCompletedStatus() {
        let state = DownloadState(model: makeModel())
        let url = URL(fileURLWithPath: "/tmp/model.gguf")

        state.markCompleted(localURL: url)

        if case .completed(let localURL) = state.status {
            XCTAssertEqual(localURL, url)
        } else {
            XCTFail("Expected .completed, got \(state.status)")
        }
    }

    func test_markFailed_setsFailedStatus() {
        let state = DownloadState(model: makeModel())

        state.markFailed(error: "Network timeout")

        if case .failed(let error) = state.status {
            XCTAssertEqual(error, "Network timeout")
        } else {
            XCTFail("Expected .failed, got \(state.status)")
        }
    }

    func test_markCancelled_setsCancelledStatus() {
        let state = DownloadState(model: makeModel())

        state.markCancelled()

        if case .cancelled = state.status {
            // expected
        } else {
            XCTFail("Expected .cancelled, got \(state.status)")
        }
    }

    // MARK: - Multiple Transitions

    func test_multipleTransitions_lastOneWins() {
        let state = DownloadState(model: makeModel())

        state.updateProgress(bytesDownloaded: 100, totalBytes: 1000)
        state.markFailed(error: "oops")
        state.markCancelled()

        if case .cancelled = state.status {
            // expected — last transition wins
        } else {
            XCTFail("Expected .cancelled after multiple transitions, got \(state.status)")
        }
    }

    func test_progressThenCompleted() {
        let state = DownloadState(model: makeModel())
        let url = URL(fileURLWithPath: "/tmp/model.gguf")

        state.updateProgress(bytesDownloaded: 500, totalBytes: 1000)
        state.updateProgress(bytesDownloaded: 1000, totalBytes: 1000)
        state.markCompleted(localURL: url)

        if case .completed(let localURL) = state.status {
            XCTAssertEqual(localURL, url)
        } else {
            XCTFail("Expected .completed, got \(state.status)")
        }
    }
}
