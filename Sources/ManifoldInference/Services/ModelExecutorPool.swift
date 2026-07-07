import Foundation
import Observation
import ManifoldContract

/// A point-in-time, value-typed snapshot of one pooled executor. The pool
/// publishes these for observation so SwiftUI / telemetry can render the live
/// roster without `await`-ing into each executor actor on the render path.
public struct ExecutorSnapshot: Sendable, Equatable, Identifiable {
    public var id: ModelExecutorKey { key }
    public let key: ModelExecutorKey
    public let backendName: String
    public let state: ExecutorState
    public let isActive: Bool
}

/// Holds N concurrently-live ``ModelExecutor``s keyed by model identity and
/// coordinates hot-swap of the active model plus wedge recovery.
///
/// ## Relationship to the single-model path
///
/// This is **additive**. The legacy ``InferenceService`` single-FIFO,
/// one-backend-at-a-time path is untouched — apps that never construct a pool
/// see no behavioural change. The pool is an opt-in multiplexer for the
/// router/hot-swap use cases (#1936, paired with the residency policy seam):
/// a pool of one executor is behaviourally the single-model path.
///
/// ## Hot-swap ordering (load-before-evict)
///
/// ``hotSwap(to:)`` loads the *new* executor to `.ready` **before** evicting
/// the old active one. This guarantees there is never a window in which zero
/// executors serve the active model — a model picker can switch without a
/// runtime restart and without a visible "no model loaded" gap. (Removing this
/// ordering is the sabotage check in the test suite.) KV-cache is *not*
/// preserved across a swap — different weights mean a cold load by definition.
///
/// ## Admission / capacity
///
/// Capacity is bounded by `maxResidentExecutors` (a safety cap) as the in-tree
/// stand-in for the unified residency policy that admits/evicts by RAM. When at
/// capacity, loading a new executor first evicts the least-recently-active
/// non-active executor. The active executor is never evicted to make room for a
/// non-active one.
@Observable
@MainActor
public final class ModelExecutorPool {

    /// Builds a loader closure for a given model key. The closure, when called,
    /// loads and returns a ready backend. Injected so the pool stays agnostic
    /// to on-disk vs endpoint vs mock loading.
    public typealias LoaderProvider = @MainActor (ModelExecutorKey) -> (backendName: String, loader: @Sendable () async throws -> any InferenceBackend)?

    @ObservationIgnored
    private let loaderProvider: LoaderProvider

    @ObservationIgnored
    private let makeWatchdog: @Sendable () -> any WedgeWatchdog

    @ObservationIgnored
    private var executors: [ModelExecutorKey: ModelExecutor] = [:]

    /// Hard safety cap on concurrently-resident executors. The residency
    /// policy (RAM-driven admission) is the eventual owner of this number;
    /// today it's a static cap.
    public let maxResidentExecutors: Int

    /// The model the pool currently treats as active (the one user-facing chat
    /// routes to). Hot-swap moves this pointer. `nil` until the first load.
    public private(set) var activeKey: ModelExecutorKey?

    /// Observable roster of live executors. Kept in sync after every lifecycle
    /// transition so observers never need to touch the actors.
    public private(set) var snapshots: [ExecutorSnapshot] = []

    public init(
        maxResidentExecutors: Int = 4,
        makeWatchdog: @escaping @Sendable () -> any WedgeWatchdog = { RealWedgeWatchdog(budget: .seconds(120)) },
        loaderProvider: @escaping LoaderProvider
    ) {
        self.maxResidentExecutors = max(1, maxResidentExecutors)
        self.makeWatchdog = makeWatchdog
        self.loaderProvider = loaderProvider
    }

    // MARK: - Executor lifecycle

    /// Returns the ready executor for `key`, loading and admitting it on first
    /// use. Does **not** change ``activeKey`` — concurrent (router) callers can
    /// hold ready executors for several models at once.
    @discardableResult
    public func executor(for key: ModelExecutorKey) async throws -> ModelExecutor {
        if let existing = executors[key] {
            // Recover transparently if a prior turn wedged it.
            if await existing.state == .wedged {
                try await existing.recover()
                await refreshSnapshots()
            }
            return existing
        }
        try await admit(key)
        guard let created = executors[key] else {
            throw InferenceError.inferenceFailure("Executor admission for \(key.rawValue) produced no executor")
        }
        return created
    }

    /// Loads `key` into the pool (evicting to make room if needed) and returns
    /// once it is `.ready`.
    private func admit(_ key: ModelExecutorKey) async throws {
        guard let resolved = loaderProvider(key) else {
            throw InferenceError.modelNotFound(path: key.rawValue)
        }
        try await evictForCapacity(excluding: key)

        let executor = ModelExecutor(
            key: key,
            backendName: resolved.backendName,
            loader: resolved.loader,
            makeWatchdog: makeWatchdog
        )
        executors[key] = executor
        do {
            try await executor.load()
        } catch {
            // Failed load must not leave a half-admitted ghost in the registry.
            executors[key] = nil
            throw error
        }
        await refreshSnapshots()
    }

    /// Evicts least-recently-active non-active executors until there is room
    /// for one more. Never evicts the active executor or `keepKey`.
    private func evictForCapacity(excluding keepKey: ModelExecutorKey?) async throws {
        while executors.count >= maxResidentExecutors {
            guard let victim = await leastRecentlyActiveEvictable(excluding: keepKey) else {
                // Nothing evictable (everything is active/kept) — let the load
                // proceed and exceed the soft cap rather than deadlock. A hard
                // RAM ceiling would throw here; the static cap degrades gracefully.
                Log.inference.warning(
                    "executor pool at capacity \(self.maxResidentExecutors) with no evictable executor — exceeding soft cap"
                )
                return
            }
            await evict(victim)
        }
    }

    private func leastRecentlyActiveEvictable(excluding keepKey: ModelExecutorKey?) async -> ModelExecutorKey? {
        var best: (key: ModelExecutorKey, at: Date)?
        for (key, exec) in executors {
            if key == activeKey || key == keepKey { continue }
            let at = await exec.lastActivityAtSnapshot
            if let current = best {
                if at < current.at { best = (key, at) }
            } else {
                best = (key, at)
            }
        }
        return best?.key
    }

    /// Unloads and removes one executor from the registry.
    public func evict(_ key: ModelExecutorKey) async {
        guard let exec = executors[key] else { return }
        await exec.unload()
        executors[key] = nil
        if activeKey == key { activeKey = nil }
        await refreshSnapshots()
    }

    // MARK: - Hot-swap

    /// Switches the active model to `key` with zero runtime restart.
    ///
    /// Load-before-evict: the new executor is brought to `.ready` *first*, then
    /// ``activeKey`` flips, then the previously-active executor is unloaded per
    /// the keep-alive policy. There is never a window with zero executors
    /// serving the active model.
    ///
    /// - Parameter unloadPrevious: when `true` (the default) the previously
    ///   active executor is evicted after the swap, honouring single-active
    ///   keep-alive. Pass `false` to keep it resident (router warm-standby).
    public func hotSwap(to key: ModelExecutorKey, unloadPrevious: Bool = true) async throws {
        let previous = activeKey
        if previous == key { return }   // already active — nothing to do

        // 1. Load the NEW executor to ready BEFORE touching the old one. If this
        //    throws, the previously-active executor is still resident and active
        //    — there is never a zero-executor window for the active model.
        try await executor(for: key)

        // 2. Atomically switch the active pointer.
        activeKey = key

        // 3. Evict the old active executor (after the new one is serving).
        if unloadPrevious, let previous {
            await evict(previous)
        }
        await refreshSnapshots()
    }

    // MARK: - Generation

    /// Routes a generation to the executor for `key` (defaulting to the active
    /// one). Loads/recovers the executor as needed, then returns its stream.
    public func generate(
        on key: ModelExecutorKey? = nil,
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig,
        hints: GenerationRuntimeHints = GenerationRuntimeHints()
    ) async throws -> GenerationStream {
        guard let target = key ?? activeKey else {
            throw InferenceError.inferenceFailure("No active model and no explicit executor key")
        }
        // First load also establishes the active model if none is set.
        let exec = try await executor(for: target)
        if activeKey == nil { activeKey = target }
        let stream = try await exec.generate(prompt: prompt, systemPrompt: systemPrompt, config: config, hints: hints)
        await refreshSnapshots()
        return stream
    }

    /// Recovers a wedged executor out-of-band (e.g. a watchdog observer calls
    /// this on detection). Safe to call on a healthy executor — it no-ops.
    public func recover(_ key: ModelExecutorKey) async throws {
        guard let exec = executors[key] else { return }
        if await exec.state == .wedged {
            try await exec.recover()
            await refreshSnapshots()
        }
    }

    // MARK: - Snapshots

    /// Refreshes the observable roster from the live executors.
    private func refreshSnapshots() async {
        var result: [ExecutorSnapshot] = []
        for (key, exec) in executors {
            let state = await exec.state
            result.append(ExecutorSnapshot(
                key: key,
                backendName: exec.backendName,
                state: state,
                isActive: key == activeKey
            ))
        }
        snapshots = result.sorted { $0.key.rawValue < $1.key.rawValue }
    }

    /// Current state of an executor, or `nil` if it isn't pooled. Convenience
    /// for tests and observers that want a single executor's state.
    public func state(of key: ModelExecutorKey) async -> ExecutorState? {
        guard let exec = executors[key] else { return nil }
        return await exec.state
    }

    /// Number of currently-resident executors.
    public var residentCount: Int { executors.count }
}

// MARK: - Executor activity snapshot

extension ModelExecutor {
    /// Non-mutating read of last-activity for LRU eviction. Separate from the
    /// stored `lastActivityAt` to keep that property's setter actor-private.
    var lastActivityAtSnapshot: Date { lastActivityAt }
}
