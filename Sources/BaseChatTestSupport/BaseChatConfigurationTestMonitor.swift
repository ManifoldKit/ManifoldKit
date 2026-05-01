import Foundation
import BaseChatInference

/// Serialises ``BaseChatConfiguration/shared`` mutations in parallel tests.
///
/// `swift test --parallel` runs `XCTestCase` subclasses concurrently. Code that
/// mutates the process-global ``BaseChatConfiguration/shared`` races across
/// classes. All test code in this project is `@MainActor`, so the async variants
/// are also `@MainActor` — they serialise via a FIFO actor queue without blocking
/// any threads. The sync variants use `NSLock` for non-async call sites.
///
/// Usage (async `@MainActor` test, explicit config):
/// ```swift
/// await BaseChatConfigurationTestMonitor.shared.withConfiguration(myConfig) {
///     // test body — may contain await points
/// }
/// ```
///
/// Usage (async `@MainActor` test, no config change — just serialise):
/// ```swift
/// try await BaseChatConfigurationTestMonitor.shared.withCurrentConfiguration {
///     // code that sets BaseChatConfiguration.shared internally (e.g. BaseChatBootstrap)
/// }
/// ```
///
/// Usage (sync test):
/// ```swift
/// try BaseChatConfigurationTestMonitor.shared.withConfiguration(myConfig) {
///     // synchronous test body
/// }
/// ```
public final class BaseChatConfigurationTestMonitor: @unchecked Sendable {
    public static let shared = BaseChatConfigurationTestMonitor()
    private let queue = _ConfigQueue()
    private let syncLock = NSLock()
    private init() {}

    // MARK: - Async API (all @MainActor — matches all test classes in this project)

    /// Runs `body` with ``BaseChatConfiguration/shared`` set to `config`,
    /// serialised against every other caller across the process.
    ///
    /// The serialisation lock is held for the full duration of `body`, including
    /// across `await` suspension points. The original value is restored
    /// after `body` returns (or throws).
    @MainActor
    public func withConfiguration<T>(
        _ config: BaseChatConfiguration,
        body: () async throws -> T
    ) async rethrows -> T {
        await queue.enter()
        let original = BaseChatConfiguration.shared
        BaseChatConfiguration.shared = config
        do {
            let result = try await body()
            BaseChatConfiguration.shared = original
            await queue.leave()
            return result
        } catch {
            BaseChatConfiguration.shared = original
            await queue.leave()
            throw error
        }
    }

    /// Serialises without changing ``BaseChatConfiguration/shared``.
    ///
    /// Use this when the code under test (e.g. `BaseChatBootstrap`) sets
    /// ``BaseChatConfiguration/shared`` internally and you just need to prevent
    /// concurrent changes from other test classes.
    ///
    /// The original value is captured **after** the lock is acquired, so `body`
    /// always sees a consistent config even if another test held the lock just before.
    @MainActor
    public func withCurrentConfiguration<T>(
        body: () async throws -> T
    ) async rethrows -> T {
        await queue.enter()
        let original = BaseChatConfiguration.shared
        do {
            let result = try await body()
            BaseChatConfiguration.shared = original
            await queue.leave()
            return result
        } catch {
            BaseChatConfiguration.shared = original
            await queue.leave()
            throw error
        }
    }

    // MARK: - Sync API (for non-async test functions)

    /// Synchronous overload — for use in non-async test functions.
    public func withConfiguration<T>(
        _ config: BaseChatConfiguration,
        body: () throws -> T
    ) rethrows -> T {
        syncLock.lock()
        let original = BaseChatConfiguration.shared
        BaseChatConfiguration.shared = config
        defer {
            BaseChatConfiguration.shared = original
            syncLock.unlock()
        }
        return try body()
    }

    /// Synchronous variant of ``withCurrentConfiguration(body:)``.
    public func withCurrentConfiguration<T>(
        body: () throws -> T
    ) rethrows -> T {
        syncLock.lock()
        let original = BaseChatConfiguration.shared
        defer {
            BaseChatConfiguration.shared = original
            syncLock.unlock()
        }
        return try body()
    }
}

// MARK: - Private actor queue

/// FIFO serialiser: grants exclusive access to one `withConfiguration` body at a time
/// using cooperative suspension — no threads are blocked.
private actor _ConfigQueue {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        guard occupied else { occupied = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func leave() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
            // `occupied` stays true — the next owner is now queued to run.
        } else {
            occupied = false
        }
    }
}
