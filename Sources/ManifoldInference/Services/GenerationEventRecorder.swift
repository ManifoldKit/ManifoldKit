import Foundation

// MARK: - GenerationEventRecorder

/// Records the full ``GenerationEvent`` trace from an ``InferenceService``
/// tap into an in-memory array.
///
/// Direct-`InferenceService` counterpart to `ManifoldRuntime`'s
/// `ConversationEventRecorder` (#2206). Apps that drive `InferenceService` /
/// `enqueue(...)` directly — without adopting `ConversationRuntime` — use
/// `GenerationEventRecorder` to capture and inspect the generation-scoped
/// event trace (prompt rendering, tokens, thinking, tool calls, and the
/// terminal completion/cancellation/error signal) without migrating their
/// turn loop onto the runtime layer, and without taking a dependency on
/// `ManifoldRuntime` to do it.
///
/// ```swift,no-build
/// let recorder = GenerationEventRecorder()
/// let drainTask = await recorder.start(on: service)
///
/// let (_, stream) = try service.enqueue(
///     messages: [.user("hi")],
///     config: GenerationConfig()
/// )
/// for try await _ in stream.events {}   // drive the turn to completion
///
/// drainTask.cancel()
/// await drainTask.value                 // let the recorder observe generationCompleted
/// let trace = await recorder.trace
/// ```
public actor GenerationEventRecorder {

    /// The events recorded so far, in delivery order.
    public private(set) var trace: [GenerationEvent] = []

    public init() {}

    /// Installs a tap on `service` and begins recording events into ``trace``.
    ///
    /// Returns a `Task` that drains the tap until `service` is deallocated
    /// or the task is cancelled. Cancel and await the returned task after a
    /// generation completes to ensure the final `.generationCompleted` event
    /// is captured before reading ``trace``.
    ///
    /// `async` because ``InferenceService/addGenerationEventTap(bufferingPolicy:)``
    /// is `@MainActor`-isolated and this recorder is a plain actor.
    @discardableResult
    public func start(on service: InferenceService) async -> Task<Void, Never> {
        let tap = await service.addGenerationEventTap()
        return Task { [weak self] in
            for await event in tap {
                await self?.append(event)
            }
        }
    }

    private func append(_ event: GenerationEvent) {
        trace.append(event)
    }
}
