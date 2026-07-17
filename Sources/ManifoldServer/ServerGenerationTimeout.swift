#if Server
import Foundation
import ManifoldInference
import os

/// Races an async operation against a wall-clock timeout, cancelling the
/// backend's in-flight generation on expiry.
///
/// Mirrors `ManifoldMCP`'s `InternalMCPSession.withTimeout` and
/// `ManifoldFuzz`'s `GenerationTimeout` (#2268): an unstructured-task race,
/// not `withThrowingTaskGroup`. The group variant blocks on ALL child tasks
/// at scope exit, so if `operation` is a genuinely hung backend call that
/// never yields and never observes cancellation, that wait would itself
/// never return.
///
/// `onTimeout` is synchronous here (unlike MCP's `async` cleanup) because the
/// only cleanup this call site needs — `InferenceBackend.stopGeneration()` —
/// is itself synchronous (see its doc comment: "Calling `stopGeneration()`
/// when no generation is in progress is a no-op"). Cancelling `operationTask`
/// alone does not stop a backend's in-flight generation — the adapter's
/// event stream isn't guaranteed to observe `Task.isCancelled` promptly —
/// so callers MUST call `stopGeneration()` from `onTimeout` for the timeout
/// to actually terminate work, not just abandon the awaiting task.
internal enum ServerGenerationTimeout {
    static func run<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T,
        onTimeout: @escaping @Sendable () -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)

            func claimResume() -> Bool {
                resumed.withLock { flag -> Bool in
                    guard !flag else { return false }
                    flag = true
                    return true
                }
            }

            // Holds the watchdog `Task` once created, so `operationTask` can
            // cancel it the moment the operation finishes on its own — without
            // this, the watchdog is an unstructured task nobody retains, so it
            // always sleeps out its FULL `timeout` duration even after the
            // operation already returned (review finding on #2265: at server
            // request volume this is ~1 sleeping task + continuation per
            // request for the life of `timeout`, not just untidy).
            let watchdogBox = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

            let operationTask = Task {
                do {
                    let value = try await operation()
                    if claimResume() {
                        watchdogBox.withLock { $0?.cancel() }
                        continuation.resume(returning: value)
                    }
                } catch {
                    if claimResume() {
                        watchdogBox.withLock { $0?.cancel() }
                        continuation.resume(throwing: error)
                    }
                }
            }

            let watchdogTask = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    // Cancelled by `operationTask` above (or by the
                    // already-resumed check just below) — the operation won
                    // the race. Nothing to do.
                    return
                }
                guard claimResume() else { return }
                operationTask.cancel()
                onTimeout()
                continuation.resume(throwing: ServerError.generationTimedOut(
                    "Generation exceeded the configured timeout of \(timeout)."
                ))
            }

            // Publish the watchdog, then re-check: if `operationTask` already
            // claimed `resumed` in the window between its own creation and
            // this publish, its `watchdogBox.withLock { $0?.cancel() }` call
            // above found the box still empty and could not cancel us — catch
            // that here so the watchdog is never left sleeping out its full
            // duration after the operation already finished.
            let alreadyResumed = watchdogBox.withLock { box -> Bool in
                box = watchdogTask
                return resumed.withLock { $0 }
            }
            if alreadyResumed {
                watchdogTask.cancel()
            }
        }
    }
}

/// Merges a chunk stream with an idle watchdog: the clock re-arms every time
/// the producer task reads a new element **from `source`** (i.e. from the
/// backend/adapter) — NOT when that element is subsequently written to the
/// HTTP client. This bounds a backend/adapter that stops producing chunks;
/// it does NOT bound a client that stops reading them (a slow or stalled
/// *reader* on a healthy stream is not covered by this timeout — that would
/// need a write-side deadline against the `ResponseBodyWriter`, which is out
/// of scope here). A slow-but-continuously-emitting *source* is never
/// killed — only a source that stops producing entirely for `idleTimeout`
/// trips it. This is the streaming counterpart to ``ServerGenerationTimeout``,
/// which bounds a single opaque non-streaming await instead.
///
/// Deliberately does NOT hold the source's `AsyncIteratorProtocol` iterator
/// behind an actor and race per-element `next()` calls against a sleep: that
/// shape requires sending the (non-`Sendable`, mutating-`next()`) iterator
/// across the actor-isolation boundary on every pull, which Swift 6's region
/// checker rejects (`#SendingRisksDataRace`) — and the alternative,
/// `@unchecked Sendable`-boxing the iterator, is exactly the race-fix
/// AGENTS.md's Swift 6 gotcha #2 forbids. Instead a single producer `Task`
/// drains `source` with an ordinary `for try await` loop (no isolation
/// crossing — the loop owns the iterator outright) and forwards each element
/// into a plain `AsyncStream`, touching a shared actor-isolated deadline as
/// it goes; an independent watchdog `Task` emits `.timedOut` if that deadline
/// ever lapses. The merged `AsyncStream` is safe for `writeSSEChunks` to
/// drive with an ordinary `for await` loop.
internal enum ServerIdleTimeoutPuller {
    internal enum Outcome<Element: Sendable>: Sendable {
        case element(Element)
        case finished
        case failure(Error)
        case timedOut
    }

    private actor IdleDeadline {
        private var deadline: ContinuousClock.Instant
        private let idleTimeout: Duration

        init(idleTimeout: Duration) {
            self.idleTimeout = idleTimeout
            self.deadline = ContinuousClock.now.advanced(by: idleTimeout)
        }

        func touch() {
            deadline = ContinuousClock.now.advanced(by: idleTimeout)
        }

        /// Time remaining until the deadline, clamped to zero (never
        /// negative — `Task.sleep(for:)` rejects a negative duration).
        func remaining() -> Duration {
            let now = ContinuousClock.now
            return now < deadline ? now.duration(to: deadline) : .zero
        }
    }

    static func make<Element: Sendable>(
        _ source: AsyncThrowingStream<Element, Error>,
        idleTimeout: Duration
    ) -> AsyncStream<Outcome<Element>> {
        AsyncStream { continuation in
            let finished = OSAllocatedUnfairLock(initialState: false)

            /// At most one terminal `Outcome` (`.finished`/`.failure`/
            /// `.timedOut`) is ever yielded — whichever of the producer or
            /// watchdog task claims the flag first.
            func finishOnce(_ outcome: Outcome<Element>) {
                let shouldFinish = finished.withLock { flag -> Bool in
                    guard !flag else { return false }
                    flag = true
                    return true
                }
                guard shouldFinish else { return }
                continuation.yield(outcome)
                continuation.finish()
            }

            let deadline = IdleDeadline(idleTimeout: idleTimeout)

            // Publish `onTermination` against a box BEFORE creating either
            // task, so a consumer that cancels immediately (before this
            // closure finishes running) can never observe an empty handler —
            // narrows the same "unstructured task nobody could reach to
            // cancel" gap `ServerGenerationTimeout.run` closes above.
            let taskBox = OSAllocatedUnfairLock<(producer: Task<Void, Never>?, watchdog: Task<Void, Never>?)>(
                initialState: (nil, nil)
            )
            continuation.onTermination = { _ in
                taskBox.withLock { pair in
                    pair.producer?.cancel()
                    pair.watchdog?.cancel()
                }
            }

            let producer = Task {
                do {
                    for try await element in source {
                        await deadline.touch()
                        guard !finished.withLock({ $0 }) else { return }
                        continuation.yield(.element(element))
                    }
                    finishOnce(.finished)
                } catch {
                    finishOnce(.failure(error))
                }
            }

            let watchdog = Task {
                while true {
                    let remaining = await deadline.remaining()
                    if remaining <= .zero {
                        finishOnce(.timedOut)
                        return
                    }
                    do {
                        try await Task.sleep(for: remaining)
                    } catch {
                        return
                    }
                }
            }

            taskBox.withLock { $0 = (producer, watchdog) }
        }
    }
}

#endif
