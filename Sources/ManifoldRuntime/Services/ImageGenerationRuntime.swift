import Foundation
import ManifoldInference

// MARK: - ImageGenerationRuntime
//
// Sibling to `ConversationRuntime` for the image-generation path. Owns an
// `ImageGenerationService`, drives `generate(prompt:config:)`, and persists
// the resulting `.generatedImage` part via the `MessageStore` port.
//
// Per umbrella #1002:
//   - Image-side runtime is a sibling type, not a new method on
//     `ConversationRuntime`. Image lifecycle has different shape (no
//     turn-loop, no streaming tokens, no thinking blocks) and squeezing
//     it into the text runtime would distort both surfaces.
//   - Events ride `ImageRuntimeEvent` — distinct from `ConversationEvent`
//     so text-side exhaustive switches stay closed.
//   - Persistence uses the existing `MessageStore` port. The runtime
//     inserts an empty placeholder on `generate` and updates it in place
//     with the `.generatedImage` part when the backend completes.
//
// Concurrency: `@MainActor` because both `MessageStore` and
// `ImageGenerationService` are `@MainActor`-isolated. The backend's stream
// is consumed on a `Task` per generation so `cancel(messageID:)` can locate
// and tear it down by ID without blocking the actor.

/// Drives image-generation lifecycle through ``ImageGenerationService`` and
/// persists results via ``MessageStore``.
///
/// Sibling to ``ConversationRuntime``. Hosts call ``generate(prompt:config:in:)``
/// to start a generation, observe progress on ``events`` (an
/// ``AsyncStream`` of ``ImageRuntimeEvent``), and call ``cancel(messageID:)``
/// to tear down an in-flight job.
///
/// ## Persistence
///
/// On ``generate(prompt:config:in:)`` the runtime inserts a placeholder
/// ``ChatMessage`` (role `.assistant`, empty `contentParts`) into the
/// message store. Backend progress events are forwarded as
/// ``ImageRuntimeEvent/progress(messageID:step:totalSteps:)`` *without*
/// touching the store — UI subscribes to events for the in-flight indicator;
/// persistence stays minimal until the terminal step.
///
/// On backend completion the runtime builds an ``ImageMessagePayload`` and
/// updates the placeholder message via
/// ``MessageStore/updateMessage(_:)`` so its `contentParts` becomes a single
/// ``MessagePart/generatedImage(_:)`` carrying the payload, then emits
/// ``ImageRuntimeEvent/completed(messageID:payload:)``.
///
/// On error or cancellation the placeholder remains in the store with its
/// original empty `contentParts`. Hosts that prefer to drop the slot can
/// observe the terminal event and call ``MessageStore/deleteMessage(_:)``
/// from the adapter — the runtime intentionally does not pick a UX policy.
///
/// ## Concurrency
///
/// `@MainActor`-isolated for parity with both ports. Each in-flight
/// generation runs on a tracked `Task` keyed to its placeholder message ID;
/// ``cancel(messageID:)`` cancels the task and unloads the backend's
/// in-flight stream via ``ImageGenerationService``'s
/// `AsyncThrowingStream` cancellation hook (which calls
/// `backend.stopGeneration()` per the service contract).
@MainActor
public final class ImageGenerationRuntime {

    // MARK: Ports

    private let service: ImageGenerationService
    private let messageStore: any MessageStore
    private let modelIdentifierProvider: @MainActor () -> String?

    // MARK: Event stream

    /// Lifecycle event stream. Single-consumer by design — adapters either
    /// iterate it directly or install an observable wrapper.
    public let events: AsyncStream<ImageRuntimeEvent>
    private let continuation: AsyncStream<ImageRuntimeEvent>.Continuation

    /// Fan-out registry for secondary observers installed via
    /// ``addEventTap(bufferingPolicy:)``. Separate from the primary
    /// ``events`` stream so a developer inspector (the Architect timeline) can
    /// observe the same event flow the host adapter already drains, without
    /// competing for the single-consumer ``events`` stream.
    private let eventTaps = EventTapRegistry<ImageRuntimeEvent>()

    // MARK: In-flight state
    //
    // Tracks the consumer task for each in-flight generation by the
    // placeholder message ID. The dict is `@MainActor`-protected — every
    // mutation happens from main-actor methods and the runtime itself is
    // `@MainActor`.

    private var inFlight: [ChatMessage.ID: Task<Void, Never>] = [:]

    // MARK: Init

    /// Creates a runtime that composes the supplied service and message store.
    ///
    /// - Parameters:
    ///   - service: The ``ImageGenerationService`` whose lifecycle the runtime
    ///     drives. The service must already have a backend factory registered
    ///     for the format of any model the host intends to load.
    ///   - messageStore: Required. Persists the placeholder and final
    ///     `.generatedImage` part across the generation.
    ///   - modelIdentifier: Optional override for the identifier embedded in
    ///     ``ImageMessagePayload/modelIdentifier``. When `nil` (the default),
    ///     the runtime reads ``ImageGenerationService/loadedModel`` at the
    ///     moment of completion and uses its `id`. Tests inject this when
    ///     they want a deterministic identifier without driving the service
    ///     through a real `loadModel` call.
    public init(
        service: ImageGenerationService,
        messageStore: any MessageStore,
        modelIdentifier: (@MainActor () -> String?)? = nil
    ) {
        self.service = service
        self.messageStore = messageStore
        // The default closure returns `nil` so `modelIdentifier()` falls
        // through to reading `service.loadedModel?.id` at completion time.
        // Tests inject a non-nil override when they want a deterministic
        // identifier without driving the service through a real load.
        self.modelIdentifierProvider = modelIdentifier ?? { nil }
        var cap: AsyncStream<ImageRuntimeEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { cap = $0 }
        self.continuation = cap
    }

    deinit {
        continuation.finish()
        eventTaps.finishAll()
    }

    // MARK: Secondary event taps

    /// Installs a secondary multicast tap on this runtime's event flow.
    ///
    /// The returned stream receives every ``ImageRuntimeEvent`` the primary
    /// ``events`` stream sees. The tap is independent of the primary consumer —
    /// installing one does not starve ``events``, and a slow tap does not stall
    /// generation. Mirrors ``ConversationRuntime/addEventTap(bufferingPolicy:)``
    /// so a developer inspector can fold image-generation events into the same
    /// timeline as conversation events.
    ///
    /// - Parameter bufferingPolicy: Controls what happens when the tap consumer
    ///   falls behind. Defaults to `.unbounded` so no events are dropped; pass a
    ///   bounded policy if you need backpressure semantics.
    /// - Returns: An `AsyncStream` that delivers events until the runtime
    ///   terminates, at which point the stream finishes normally.
    public func addEventTap(
        bufferingPolicy: AsyncStream<ImageRuntimeEvent>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<ImageRuntimeEvent> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { [eventTaps] continuation in
            let id = eventTaps.register(continuation)
            continuation.onTermination = { _ in
                eventTaps.deregister(id)
            }
        }
    }

    // MARK: Commands

    /// Begins an image generation in the supplied session.
    ///
    /// Persists a placeholder ``ChatMessage`` (role `.assistant`,
    /// empty `contentParts`) before returning, then starts a detached task
    /// that forwards backend events through ``events``. The returned
    /// message ID is stable for the lifetime of the generation — pass it
    /// to ``cancel(messageID:)`` to tear down the job, and observe the
    /// terminal event (`completed` / `failed` / `cancelled`) on
    /// ``events`` to know when the placeholder has been finalised.
    ///
    /// Generation runs asynchronously on a tracked `Task`; this method
    /// returns once the placeholder has been inserted and the consumer
    /// task is dispatched.
    ///
    /// - Parameters:
    ///   - prompt: User-supplied prompt.
    ///   - config: Sampling and diffusion parameters.
    ///   - sessionID: The session the placeholder message belongs to.
    /// - Returns: The placeholder ``ChatMessage/ID`` so the host can
    ///   pair UI state with the in-flight generation.
    /// - Throws: Persistence errors from the placeholder insert.
    @discardableResult
    public func generate(
        prompt: String,
        config: ImageGenerationConfig,
        in sessionID: UUID
    ) async throws -> ChatMessage.ID {
        // Insert placeholder synchronously so the caller observes the
        // message ID before any event fires. Empty `contentParts` because
        // we don't have a `.generatedImage` payload yet — the placeholder
        // is finalised via `updateMessage` when the backend completes.
        let placeholder = ChatMessage(
            role: .assistant,
            contentParts: [],
            sessionID: sessionID
        )
        try await messageStore.insertMessage(placeholder)

        let messageID = placeholder.id
        emit(.started(messageID: messageID, prompt: prompt))

        // Snapshot config for the persisted payload. Take it now so the
        // payload reflects the call-site value even if a future runtime
        // mutates the live `config` mid-flight.
        let snapshot = ImageGenerationConfigSnapshot(from: config)

        let stream = service.generate(prompt: prompt, config: config)

        // Strong capture: the consumer task owns this generation's logical
        // unit of work and must complete (emit terminal event, clean up
        // `inFlight`) even if the host releases its last reference to the
        // runtime mid-flight. Per the `[weak self]`-in-detached-tasks
        // memory note: weak capture would silently drop the work. The
        // task removes itself from `inFlight` on completion so the runtime
        // can still deinit normally.
        let task = Task { @MainActor [self] in
            await self.consume(
                stream: stream,
                messageID: messageID,
                prompt: prompt,
                placeholder: placeholder,
                snapshot: snapshot,
                totalSteps: config.steps
            )
        }
        inFlight[messageID] = task
        return messageID
    }

    /// Cancels an in-flight generation by its placeholder message ID.
    ///
    /// Idempotent — cancelling an unknown or already-finished message is a
    /// no-op. The terminal ``ImageRuntimeEvent/cancelled(messageID:)`` event
    /// fires once the underlying stream observes the cancellation.
    public func cancel(messageID: ChatMessage.ID) async {
        guard let task = inFlight[messageID] else { return }
        task.cancel()
        // Don't await `task.value` — the consumer task itself emits the
        // terminal event and removes itself from `inFlight`. Awaiting here
        // would serialise callers behind a denoising loop's cancellation
        // latency.
    }

    // MARK: - Stream consumer

    private func consume(
        stream: AsyncThrowingStream<ImageGenerationEvent, Error>,
        messageID: ChatMessage.ID,
        prompt: String,
        placeholder: ChatMessage,
        snapshot: ImageGenerationConfigSnapshot,
        totalSteps: Int?
    ) async {
        defer {
            inFlight.removeValue(forKey: messageID)
        }

        do {
            for try await event in stream {
                if Task.isCancelled {
                    emit(.cancelled(messageID: messageID))
                    return
                }
                switch event {
                case .progress(let step, let total):
                    // Per ImageGenerationBackend's "Step-count resolution
                    // contract", a compliant backend always reports the real
                    // resolved count in `total` starting with its first
                    // event — including when `config.steps` was `nil` and it
                    // had to fall back to its own model preset. `total > 0`
                    // is therefore the expected path even for a bare
                    // `ImageGenerationConfig()`. The `totalSteps` (i.e.
                    // `config.steps`) fallback only matters for a
                    // non-compliant backend that yields `total: 0`; the
                    // final `?? 0` is the honest "still unknown" sentinel
                    // for that violation, not a guessed default.
                    let resolvedTotal = total > 0 ? total : (totalSteps ?? 0)
                    emit(.progress(messageID: messageID, step: step, totalSteps: resolvedTotal))

                case .preview(let step, let total, let image):
                    // Forward the in-memory preview without touching the
                    // store — previews are transient UI affordances; only
                    // the terminal `.completed` writes through `MessageStore`.
                    let resolvedTotal = total > 0 ? total : (totalSteps ?? 0)
                    emit(.preview(messageID: messageID, step: step, totalSteps: resolvedTotal, image: image))

                case .completed(let url):
                    let identifier = modelIdentifier()
                    let payload = ImageMessagePayload(
                        prompt: prompt,
                        imageURL: url,
                        modelIdentifier: identifier,
                        generationConfig: snapshot
                    )
                    var finalised = placeholder
                    finalised.contentParts = [.generatedMedia(GeneratedMediaPayload(image: payload))]
                    do {
                        try await messageStore.updateMessage(finalised)
                    } catch {
                        emit(.failed(messageID: messageID, error: error))
                        return
                    }
                    emit(.completed(messageID: messageID, payload: payload))
                    return
                }
            }
            // Stream ended without `.completed` — treat as cancellation
            // when the task is cancelled, otherwise report empty completion
            // as a failure so adapters surface something rather than
            // silently abandoning the placeholder.
            if Task.isCancelled {
                emit(.cancelled(messageID: messageID))
            } else {
                emit(.failed(
                    messageID: messageID,
                    error: ImageGenerationServiceError.notLoaded
                ))
            }
        } catch is CancellationError {
            emit(.cancelled(messageID: messageID))
        } catch {
            if Task.isCancelled {
                emit(.cancelled(messageID: messageID))
            } else {
                emit(.failed(messageID: messageID, error: error))
            }
        }
    }

    // MARK: Helpers

    private func emit(_ event: ImageRuntimeEvent) {
        continuation.yield(event)
        eventTaps.broadcast(event)
    }

    /// Resolves the model identifier for the persisted payload. Reads the
    /// service's `loadedModel` at completion time so a model swap mid-flight
    /// is reflected. Falls back to `"unknown"` when the service has no
    /// loaded model — the alternative (an optional field on the payload)
    /// would force every UI consumer to handle nil for a value that's
    /// always known at this point in practice.
    private func modelIdentifier() -> String {
        if let override = modelIdentifierProvider() {
            return override
        }
        return service.loadedModel?.id ?? "unknown"
    }
}

// MARK: - AsyncSequence Conformance

extension ImageGenerationRuntime: AsyncSequence {
    public typealias Element = ImageRuntimeEvent
    public typealias AsyncIterator = AsyncStream<ImageRuntimeEvent>.AsyncIterator

    /// Returns an iterator over the image runtime events in this stream.
    ///
    /// Allows idiomatic iteration with `for await event in runtime { … }`
    /// instead of `for await event in runtime.events { … }`.
    public nonisolated func makeAsyncIterator() -> AsyncStream<ImageRuntimeEvent>.AsyncIterator {
        events.makeAsyncIterator()
    }
}
