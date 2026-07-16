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

            let operationTask = Task {
                do {
                    let value = try await operation()
                    if claimResume() { continuation.resume(returning: value) }
                } catch {
                    if claimResume() { continuation.resume(throwing: error) }
                }
            }

            Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    // Sleep was cancelled because the operation already won the
                    // race (its own Task doesn't cancel this watchdog, but the
                    // continuation only resumes once — claimResume below is the
                    // real guard). Nothing to do.
                    return
                }
                guard claimResume() else { return }
                operationTask.cancel()
                onTimeout()
                continuation.resume(throwing: ServerError.generationTimedOut(
                    "Generation exceeded the configured timeout of \(timeout)."
                ))
            }
        }
    }
}

/// Merges a chunk stream with an idle watchdog: the clock re-arms after
/// every element the source produces, so a slow-but-continuously-emitting
/// stream is never killed — only a source that stops producing entirely for
/// `idleTimeout` trips it. This is the streaming counterpart to
/// ``ServerGenerationTimeout``, which bounds a single opaque non-streaming
/// await instead.
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

            continuation.onTermination = { _ in
                producer.cancel()
                watchdog.cancel()
            }
        }
    }
}

#endif
