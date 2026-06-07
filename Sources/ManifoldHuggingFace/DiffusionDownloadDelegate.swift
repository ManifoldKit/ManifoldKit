#if HuggingFace
import ManifoldInference
import Foundation
import os

// MARK: - DiffusionDownloadDelegate

/// Per-task continuation and progress state used by ``DiffusionDownloadDelegate``.
struct DiffusionTaskEntry {
    let continuation: CheckedContinuation<URL, Error>
    let onChunk: (@Sendable (_ received: Int64, _ expected: Int64) -> Void)?
}

/// `URLSessionDownloadDelegate` that converts per-task callbacks into
/// `async/await` continuations for ``HuggingFaceService.downloadDiffusionModel``.
///
/// Each file download registers a continuation plus an optional progress closure
/// via ``register(taskID:continuation:onChunk:)``. The delegate fires the chunk
/// closure on every ``urlSession(_:downloadTask:didWriteData:...)`` call and
/// resumes the continuation (with the temp URL) when
/// ``urlSession(_:downloadTask:didFinishDownloadingTo:)`` fires, or resumes
/// with an error on ``urlSession(_:task:didCompleteWithError:)``.
///
/// The delegate is held strongly by the ``URLSession`` it is passed to — it
/// must outlive any individual download task.
///
/// ## Sendability
///
/// `@unchecked Sendable` is safe here because all mutable state is protected by
/// `lock`. URLSession delivers callbacks on its own serial delegate queue so
/// concurrent mutation is the only risk; the lock covers that.
final class DiffusionDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    // MARK: - State

    private let lock = NSLock()
    private var taskEntries: [Int: DiffusionTaskEntry] = [:]

    // MARK: - Registration

    /// Associates `continuation` and an optional `onChunk` progress closure
    /// with `taskID` before `task.resume()` is called.
    func register(
        taskID: Int,
        continuation: CheckedContinuation<URL, Error>,
        onChunk: (@Sendable (_ received: Int64, _ expected: Int64) -> Void)?
    ) {
        lock.lock()
        taskEntries[taskID] = DiffusionTaskEntry(continuation: continuation, onChunk: onChunk)
        lock.unlock()
    }

    // MARK: - URLSessionDownloadDelegate

    /// Per-chunk progress — fires `onChunk` so the caller can aggregate bytes
    /// across all files and emit ``DiffusionDownloadProgress`` events.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let entry = taskEntries[downloadTask.taskIdentifier]
        lock.unlock()
        // totalBytesExpectedToWrite is NSURLSessionTransferSizeUnknown (-1) when
        // the server omits Content-Length. Surface 0 so callers treat it as
        // indeterminate rather than spuriously near 1.0.
        let safeExpected: Int64 = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0
        entry?.onChunk?(totalBytesWritten, safeExpected)
    }

    /// Download complete — copy the temp file to a stable path and resume the
    /// continuation with the copied URL.
    ///
    /// The system deletes `location` as soon as this method returns, so the
    /// file must be moved synchronously (on the delegate queue) before the
    /// continuation resumes asynchronously on the Swift concurrency thread pool.
    /// This mirrors the copy-before-return strategy in
    /// ``BackgroundDownloadManager+URLSessionDelegate``.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let entry = taskEntries.removeValue(forKey: downloadTask.taskIdentifier)
        lock.unlock()
        guard let entry else { return }

        let stableTempURL: URL
        do {
            let dir = FileManager.default.temporaryDirectory
            let name = "manifoldkit-diffusion-\(UUID().uuidString).download"
            stableTempURL = dir.appendingPathComponent(name)
            try FileManager.default.moveItem(at: location, to: stableTempURL)
        } catch {
            Log.download.error("DiffusionDownloadDelegate: failed to copy temp file: \(error.localizedDescription, privacy: .public)")
            entry.continuation.resume(throwing: HuggingFaceError.downloadFailed(underlying: error))
            return
        }
        entry.continuation.resume(returning: stableTempURL)
    }

    /// Transport error — resume the continuation with the error so the caller
    /// can surface it as ``HuggingFaceError.downloadFailed``.
    ///
    /// When `error` is nil the task succeeded — ``didFinishDownloadingTo``
    /// already handled the resume, so we ignore the nil case.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        lock.lock()
        let entry = taskEntries.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        entry?.continuation.resume(throwing: HuggingFaceError.downloadFailed(underlying: error))
    }
}

#endif
