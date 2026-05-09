import Foundation
import os
import Darwin
import SwiftData
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldInference

/// Creates an in-memory `ModelContainer` suitable for unit and integration tests.
///
/// Delegates to ``ModelContainerFactory/makeInMemoryContainer()`` so the
/// container is configured with the current schema — the same setup used
/// in production. All SwiftData models (ChatMessage, ChatSession, SamplerPreset,
/// APIEndpoint, ModelBenchmarkCache) are registered. The container is ephemeral — nothing touches disk.
///
/// - Returns: A configured `ModelContainer` with in-memory storage.
/// - Throws: If `ModelContainer` initialisation fails (should not happen with
///   an in-memory configuration).
public func makeInMemoryContainer() throws -> ModelContainer {
    try ModelContainerFactory.makeInMemoryContainer()
}

// MARK: - E2E Temp Directory & GGUF Helpers

/// GGUF magic bytes: "GGUF" in ASCII.
public let ggufMagic: [UInt8] = [0x47, 0x47, 0x55, 0x46]

/// Creates a unique temporary directory for one test.
public func makeE2ETempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ManifoldE2E-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Removes a file or directory, ignoring errors.
public func cleanupE2ETempDir(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

// MARK: - Isolated Models Directory

/// Returns a fresh per-test temporary directory suitable for use as a
/// `ModelStorageService` base directory.
///
/// Every test that writes fake model files (GGUF placeholders, MLX folders,
/// non-model garbage) must route those writes through an isolated directory
/// — never the real `<Documents>/Models` path. Writing to the production
/// path pollutes the developer's demo app and can cause the model scanner
/// to surface stub files as if they were real models (see #379).
///
/// Use the returned URL when constructing `ModelStorageService(baseDirectory:)`
/// or `makeIsolatedModelStorage()` — the caller is responsible for passing the
/// same URL when cleanup needs to remove the directory in `tearDown`.
public func makeIsolatedModelsDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ManifoldModelsScratch-\(UUID().uuidString)", isDirectory: true)
}

/// Builds a `ModelStorageService` rooted at a fresh isolated temp directory
/// and returns both so the test can clean up the directory in `tearDown`.
///
/// This is the canonical way for tests to exercise the storage service
/// without touching the user's real `<Documents>/Models` path.
public func makeIsolatedModelStorage(
    fileManager: FileManager = .default
) -> (service: ModelStorageService, directory: URL) {
    let dir = makeIsolatedModelsDirectory()
    let service = ModelStorageService(fileManager: fileManager, baseDirectory: dir)
    return (service, dir)
}

/// Extracts a `CloudBackendError` from an error that may be wrapped in `RetryExhaustedError`.
///
/// Retryable errors that exhaust all retry attempts arrive wrapped in
/// `RetryExhaustedError`. Non-retryable errors pass through raw. This helper
/// handles both cases so tests can assert on the underlying `CloudBackendError`.
public func extractCloudError(_ error: any Error) -> CloudBackendError? {
    if let cloud = error as? CloudBackendError {
        return cloud
    }
    if let exhausted = error as? RetryExhaustedError,
       let cloud = exhausted.lastError as? CloudBackendError {
        return cloud
    }
    return nil
}

/// Collects all token text from a generation event stream into a single string.
public func collectTokens(_ stream: GenerationStream) async throws -> String {
    var tokens: [String] = []
    for try await event in stream.events {
        if case .token(let text) = event {
            tokens.append(text)
        }
    }
    return tokens.joined()
}

// MARK: - Resident memory measurement

/// Returns the current process's resident set size in bytes.
///
/// Returns RSS in bytes; 0 on failure. Used in perf tests for
/// memory-delta measurement (vision-session resident-memory baselines).
/// Values are noisy — callers should sample several times and take the
/// median, and assert sanity floors rather than tight upper bounds.
public func currentResidentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}

// MARK: - Bounded async timeout

/// Error thrown by ``withTimeout(_:file:line:_:)`` when the wrapped operation
/// exceeds its deadline.
enum TimeoutError: Error, CustomStringConvertible, Equatable {
    case timedOut(Duration)

    var description: String {
        switch self {
        case .timedOut(let duration):
            return "Operation timed out after \(duration)"
        }
    }
}

/// Runs `operation` with a bounded deadline. Throws ``TimeoutError/timedOut(_:)`` if
/// `timeout` elapses, even when `operation` is blocked inside a `withCheckedContinuation`
/// that does not check cancellation (e.g. a gate awaiting user input).
///
/// - Parameters:
///   - timeout: Maximum duration the operation may run before failing.
///   - operation: The async operation to run.
/// - Returns: The operation's result when it completes within `timeout`.
/// - Throws: ``TimeoutError/timedOut(_:)`` if the deadline elapses first;
///   otherwise rethrows any error from `operation`.
@discardableResult
public func withTimeout<T: Sendable>(
    _ timeout: Duration,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { cont in
        let resumed = OSAllocatedUnfairLock(initialState: false)
        func tryResume(_ body: @Sendable () -> Void) {
            let shouldResume = resumed.withLock { r -> Bool in
                guard !r else { return false }
                r = true
                return true
            }
            if shouldResume { body() }
        }

        Task {
            do {
                let value = try await operation()
                tryResume { cont.resume(returning: value) }
            } catch {
                tryResume { cont.resume(throwing: error) }
            }
        }

        Task {
            try? await Task.sleep(for: timeout)
            tryResume { cont.resume(throwing: TimeoutError.timedOut(timeout)) }
        }
    }
}
