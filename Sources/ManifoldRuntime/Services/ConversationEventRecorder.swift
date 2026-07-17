import Foundation

// MARK: - ConversationEventRecorder

/// Records the full ``ConversationEvent`` trace from a ``ConversationRuntime``
/// tap into an in-memory array.
///
/// Use `ConversationEventRecorder` in tests and diagnostic tooling to capture
/// and inspect the structured trace of a turn without writing a custom drain loop.
///
/// ```swift,no-build
/// let recorder = ConversationEventRecorder()
/// let drainTask = await recorder.start(on: runtime)
///
/// let turn = try await runtime.processTurnWithOutcome(input)
/// await turn?.outcome   // wait for turn to complete
///
/// await drainTask.value // let recorder observe the streamFinished event
/// let trace = await recorder.trace
/// ```
public actor ConversationEventRecorder {

    /// The events recorded so far, in delivery order.
    public private(set) var trace: [ConversationEvent] = []

    public init() {}

    /// Installs a tap on `runtime` and begins recording events into ``trace``.
    ///
    /// Returns a `Task` that drains the tap until this recorder deallocates
    /// or the task is cancelled. Dropping the last strong reference to the
    /// recorder breaks the drain loop, which ends iteration on `tap` and, via
    /// its `onTermination`, deregisters the underlying event-tap
    /// registration — so the returned task always terminates rather than
    /// draining (and discarding) events forever. Await `task.value` after a
    /// turn completes to ensure the final `streamFinished` event is captured
    /// before reading ``trace``.
    @discardableResult
    public func start(on runtime: ConversationRuntime) -> Task<Void, Never> {
        let tap = runtime.addEventTap()
        return Task { [weak self] in
            for await event in tap {
                guard let self else { break }
                await self.append(event)
            }
        }
    }

    private func append(_ event: ConversationEvent) {
        trace.append(event)
    }
}
