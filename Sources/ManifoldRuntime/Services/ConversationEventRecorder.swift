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
    /// Returns a `Task` that drains the tap until the runtime terminates or the
    /// task is cancelled. Await `task.value` after a turn completes to ensure
    /// the final `streamFinished` event is captured before reading ``trace``.
    @discardableResult
    public func start(on runtime: ConversationRuntime) -> Task<Void, Never> {
        let tap = runtime.addEventTap()
        return Task { [weak self] in
            for await event in tap {
                await self?.append(event)
            }
        }
    }

    private func append(_ event: ConversationEvent) {
        trace.append(event)
    }
}
