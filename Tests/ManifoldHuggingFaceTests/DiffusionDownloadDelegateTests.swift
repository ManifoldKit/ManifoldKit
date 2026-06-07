@preconcurrency import XCTest
@testable import ManifoldInference
#if HuggingFace
@testable import ManifoldHuggingFace

/// Unit tests for `DiffusionDownloadDelegate`.
///
/// The delegate is exercised directly — no real URLSession is created.
/// Each test drives the public delegate callbacks manually to verify:
/// - `didWriteData` fires `onChunk` and normalises `NSURLSessionTransferSizeUnknown` to 0.
/// - `didFinishDownloadingTo` moves the file to a stable temp path and resumes the
///   continuation with that URL.
/// - `didCompleteWithError` (non-nil) resumes the continuation with
///   `HuggingFaceError.downloadFailed`.
@MainActor
final class DiffusionDownloadDelegateTests: XCTestCase {

    private var tempDir: URL!
    private var delegate: DiffusionDownloadDelegate!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffusionDelegateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        delegate = DiffusionDownloadDelegate()
    }

    override func tearDown() async throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        delegate = nil
        try await super.tearDown()
    }

    // MARK: - Progress normalisation

    /// `totalBytesExpectedToWrite == -1` (NSURLSessionTransferSizeUnknown) must
    /// be surfaced as `0` so callers treat progress as indeterminate.
    func test_didWriteData_normalisesUnknownExpectedBytesToZero() {
        // Create a real download task just to obtain a stable taskIdentifier.
        let fakeTask = URLSession.shared.downloadTask(with: URL(string: "https://example.com/normalise")!)

        // Capture box: `onChunk` is `@Sendable` so Swift 6 disallows mutation of a
        // captured `var`. A final class box with NSLock satisfies the compiler while
        // providing real thread safety (CLAUDE.md Swift-6 gotcha #2 — for a truly
        // synchronous same-callback read like this, the lock is safety insurance).
        final class Box<T>: @unchecked Sendable {
            private let lock = NSLock()
            private var _value: T
            init(_ value: T) { _value = value }
            func set(_ v: T) { lock.lock(); _value = v; lock.unlock() }
            func get() -> T { lock.lock(); defer { lock.unlock() }; return _value }
        }
        let captured = Box<Int64>(999)
        let expectation = expectation(description: "chunk fires")

        // Register synchronously on @MainActor.
        Task { @MainActor [delegate] in
            _ = try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                delegate?.register(
                    taskID: fakeTask.taskIdentifier,
                    continuation: cont,
                    onChunk: { _, expected in
                        captured.set(expected)
                        expectation.fulfill()
                    }
                )
            }
        }

        // Fire the delegate callback with NSURLSessionTransferSizeUnknown (-1).
        delegate.urlSession(
            URLSession.shared,
            downloadTask: fakeTask,
            didWriteData: 500,
            totalBytesWritten: 500,
            totalBytesExpectedToWrite: -1
        )

        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(captured.get(), 0, "totalBytesExpected == -1 must be normalised to 0")
    }

    /// Positive `totalBytesExpectedToWrite` must pass through unchanged.
    func test_didWriteData_passesPositiveExpectedBytesThrough() {
        let fakeTask = URLSession.shared.downloadTask(with: URL(string: "https://example.com/positive")!)

        final class Box<T>: @unchecked Sendable {
            private let lock = NSLock()
            private var _value: T
            init(_ value: T) { _value = value }
            func set(_ v: T) { lock.lock(); _value = v; lock.unlock() }
            func get() -> T { lock.lock(); defer { lock.unlock() }; return _value }
        }
        let captured = Box<Int64>(0)
        let expectation = expectation(description: "chunk fires with positive expected")

        Task { @MainActor [delegate] in
            _ = try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                delegate?.register(
                    taskID: fakeTask.taskIdentifier,
                    continuation: cont,
                    onChunk: { _, expected in
                        captured.set(expected)
                        expectation.fulfill()
                    }
                )
            }
        }

        delegate.urlSession(
            URLSession.shared,
            downloadTask: fakeTask,
            didWriteData: 200,
            totalBytesWritten: 200,
            totalBytesExpectedToWrite: 1_000
        )

        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(captured.get(), 1_000, "Positive totalBytesExpected should pass through unchanged")
    }

    // MARK: - Error path

    func test_didCompleteWithError_resumesContinuationWithDownloadFailed() async {
        let fakeTask = URLSession.shared.downloadTask(with: URL(string: "https://example.com/fail")!)

        let downloadExpectation = expectation(description: "continuation throws")
        var capturedError: Error?

        Task { @MainActor [delegate] in
            do {
                _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                    delegate?.register(taskID: fakeTask.taskIdentifier, continuation: cont, onChunk: nil)
                }
                XCTFail("Expected continuation to throw")
            } catch {
                capturedError = error
            }
            downloadExpectation.fulfill()
        }

        // Give the inner Task a chance to reach the continuation suspension point.
        await Task.yield()

        delegate.urlSession(
            URLSession.shared,
            task: fakeTask,
            didCompleteWithError: URLError(.networkConnectionLost)
        )

        await fulfillment(of: [downloadExpectation], timeout: 2.0)

        guard let hfError = capturedError as? HuggingFaceError,
              case HuggingFaceError.downloadFailed = hfError else {
            return XCTFail("Expected HuggingFaceError.downloadFailed, got: \(String(describing: capturedError))")
        }
    }

    /// `didCompleteWithError(nil)` must be ignored — success is handled by
    /// `didFinishDownloadingTo` and calling resume twice crashes CheckedContinuation.
    func test_didCompleteWithNilError_doesNotResumeOrCrash() async {
        let fakeTask = URLSession.shared.downloadTask(with: URL(string: "https://example.com/nil-err")!)

        // Register a continuation but never signal it. We only verify no crash occurs.
        Task { @MainActor [delegate] in
            _ = try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                delegate?.register(taskID: fakeTask.taskIdentifier, continuation: cont, onChunk: nil)
            }
        }

        await Task.yield()

        // Firing with nil error must be a no-op — no crash, no double-resume.
        delegate.urlSession(URLSession.shared, task: fakeTask, didCompleteWithError: nil)

        await Task.yield()
        // If the test reaches here without crashing, the nil-error guard works.
    }

    // MARK: - Success path

    func test_didFinishDownloadingTo_movesFileAndResumesWithStableURL() async throws {
        // Write a real file to simulate URLSession's ephemeral temp location.
        let sourceFile = tempDir.appendingPathComponent("fake-dl-\(UUID().uuidString).bin")
        let payload = Data("hello world".utf8)
        try payload.write(to: sourceFile)

        let fakeTask = URLSession.shared.downloadTask(with: URL(string: "https://example.com/file.bin")!)

        let downloadExpectation = expectation(description: "continuation resumes with URL")
        var capturedURL: URL?

        Task { @MainActor [delegate] in
            do {
                let url = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                    delegate?.register(taskID: fakeTask.taskIdentifier, continuation: cont, onChunk: nil)
                }
                capturedURL = url
            } catch {
                XCTFail("Expected success, got: \(error)")
            }
            downloadExpectation.fulfill()
        }

        await Task.yield()

        // Simulate URLSession calling didFinishDownloadingTo.
        delegate.urlSession(URLSession.shared, downloadTask: fakeTask, didFinishDownloadingTo: sourceFile)

        await fulfillment(of: [downloadExpectation], timeout: 2.0)

        let stableURL = try XCTUnwrap(capturedURL, "Continuation should resume with a stable temp URL")

        // Verify the stable file contains the original bytes.
        let contents = try Data(contentsOf: stableURL)
        XCTAssertEqual(contents, payload, "Stable temp file should contain the original download bytes")

        // Clean up the stable temp file the delegate created.
        try? FileManager.default.removeItem(at: stableURL)

        // Sabotage: the delegate uses moveItem, so sourceFile should no longer exist.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sourceFile.path),
            "Delegate must move (not copy) the temp file — source should be gone after didFinishDownloadingTo"
        )
    }
}
#endif
