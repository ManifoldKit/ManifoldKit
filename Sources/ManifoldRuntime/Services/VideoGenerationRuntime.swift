import Foundation
import ManifoldInference

// MARK: - VideoGenerationRuntime
//
// Sibling to `ImageGenerationRuntime` for the video-generation path. Owns a
// `VideoGenerationService`, drives `generate(prompt:config:)`, and persists
// the resulting `.generatedVideo` part via the `MessageStore` port.
//
// Per umbrella #1002:
//   - Video-side runtime is a sibling type, not a new method on
//     `ImageGenerationRuntime` or `ConversationRuntime`. Video lifecycle has
//     a different shape (cloud-only, no model loading, `async throws` submit
//     before the stream) and squeezing it into another runtime would distort
//     both surfaces.
//   - Events ride `VideoRuntimeEvent` — distinct from `ImageRuntimeEvent` and
//     `ConversationEvent` so exhaustive switches in those consumers stay closed.
//   - Persistence uses the existing `MessageStore` port. The runtime inserts
//     an empty placeholder on `generate` and updates it in place with the
//     `.generatedVideo` part when the backend completes.
//
// Concurrency: `@MainActor` because both `MessageStore` and
// `VideoGenerationService` are `@MainActor`-isolated. The backend's stream is
// consumed on a `Task` per generation so `cancel(messageID:)` can locate and
// tear it down by ID without blocking the actor.

/// Drives video-generation lifecycle through ``VideoGenerationService`` and
/// persists results via ``MessageStore``.
///
/// Sibling to ``ImageGenerationRuntime``. Hosts call ``generate(prompt:config:in:)``
/// to start a generation, observe progress on ``events`` (an
/// ``AsyncStream`` of ``VideoRuntimeEvent``), and call ``cancel(messageID:)``
/// to tear down an in-flight job.
///
/// ## Persistence
///
/// On ``generate(prompt:config:in:)`` the runtime inserts a placeholder
/// ``ChatMessage`` (role `.assistant`, empty `contentParts`) into the
/// message store. Backend progress events are forwarded as
/// ``VideoRuntimeEvent/progress(messageID:fractionComplete:)`` *without*
/// touching the store — UI subscribes to events for the in-flight indicator;
/// persistence stays minimal until the terminal step.
///
/// On backend completion the runtime builds a ``VideoMessagePayload`` and
/// updates the placeholder message via
/// ``MessageStore/updateMessage(_:)`` so its `contentParts` becomes a single
/// ``MessagePart/generatedVideo(_:)`` carrying the payload, then emits
/// ``VideoRuntimeEvent/completed(messageID:payload:)``.
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
/// ``cancel(messageID:)`` cancels the task and stops the backend via
/// ``VideoGenerationService``'s `AsyncThrowingStream` cancellation hook
/// (which calls `backend.cancel()` per the service contract).
@MainActor
public final class VideoGenerationRuntime {

    // MARK: Ports

    private let service: VideoGenerationService
    private let messageStore: any MessageStore
    private let modelIdentifierProvider: @MainActor () -> String

    // MARK: Event stream

    /// Lifecycle event stream. Single-consumer by design — adapters either
    /// iterate it directly or install an observable wrapper.
    public let events: AsyncStream<VideoRuntimeEvent>
    private let continuation: AsyncStream<VideoRuntimeEvent>.Continuation

    /// Fan-out registry for secondary observers installed via
    /// ``addEventTap(bufferingPolicy:)``. Separate from the primary
    /// ``events`` stream so a developer inspector (the Architect timeline) can
    /// observe the same event flow the host adapter already drains, without
    /// competing for the single-consumer ``events`` stream.
    private let eventTaps = EventTapRegistry<VideoRuntimeEvent>()

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
    ///   - service: The ``VideoGenerationService`` the runtime drives.
    ///   - messageStore: Required. Persists the placeholder and final
    ///     `.generatedVideo` part across the generation.
    ///   - modelIdentifier: Closure returning the identifier embedded in
    ///     ``VideoMessagePayload/modelIdentifier``. Defaults to `"cloud"`.
    ///     Tests inject this when they want a deterministic identifier.
    public init(
        service: VideoGenerationService,
        messageStore: any MessageStore,
        modelIdentifier: (@MainActor () -> String)? = nil
    ) {
        self.service = service
        self.messageStore = messageStore
        self.modelIdentifierProvider = modelIdentifier ?? { "cloud" }
        var cap: AsyncStream<VideoRuntimeEvent>.Continuation!
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
    /// The returned stream receives every ``VideoRuntimeEvent`` the primary
    /// ``events`` stream sees. The tap is independent of the primary consumer —
    /// installing one does not starve ``events``, and a slow tap does not stall
    /// generation. Mirrors ``ConversationRuntime/addEventTap(bufferingPolicy:)``
    /// so a developer inspector can fold video-generation events into the same
    /// timeline as conversation events.
    ///
    /// - Parameter bufferingPolicy: Controls what happens when the tap consumer
    ///   falls behind. Defaults to `.unbounded` so no events are dropped; pass a
    ///   bounded policy if you need backpressure semantics.
    /// - Returns: An `AsyncStream` that delivers events until the runtime
    ///   terminates, at which point the stream finishes normally.
    public func addEventTap(
        bufferingPolicy: AsyncStream<VideoRuntimeEvent>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<VideoRuntimeEvent> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { [eventTaps] continuation in
            let id = eventTaps.register(continuation)
            continuation.onTermination = { _ in
                eventTaps.deregister(id)
            }
        }
    }

    // MARK: Commands

    /// Begins a video generation in the supplied session.
    ///
    /// Persists a placeholder ``ChatMessage`` (role `.assistant`,
    /// empty `contentParts`) before returning, then submits the generation
    /// request to the backend (which may involve a network round-trip) and
    /// starts a detached task that forwards backend events through ``events``.
    /// The returned message ID is stable for the lifetime of the generation —
    /// pass it to ``cancel(messageID:)`` to tear down the job, and observe
    /// the terminal event (`completed` / `failed` / `cancelled`) on
    /// ``events`` to know when the placeholder has been finalised.
    ///
    /// - Parameters:
    ///   - prompt: User-supplied prompt.
    ///   - config: Video generation parameters.
    ///   - sessionID: The session the placeholder message belongs to.
    /// - Returns: The placeholder ``ChatMessage/ID`` so the host can
    ///   pair UI state with the in-flight generation.
    /// - Throws: Persistence errors from the placeholder insert, or backend
    ///   submission errors (auth, rate limit, network).
    @discardableResult
    public func generate(
        prompt: String,
        config: VideoGenerationConfig,
        in sessionID: UUID
    ) async throws -> ChatMessage.ID {
        // Insert placeholder synchronously so the caller observes the
        // message ID before any event fires. Empty `contentParts` because
        // we don't have a `.generatedVideo` payload yet — the placeholder
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
        let snapshot = VideoGenerationConfigSnapshot(from: config)

        // `VideoGenerationService.generate` is `async throws` — the backend
        // submits the cloud job here (may do a network round-trip). If the
        // submit fails we emit `.failed` and rethrow so the caller can react.
        let stream: AsyncThrowingStream<VideoGenerationEvent, Error>
        do {
            stream = try await service.generate(prompt: prompt, config: config)
        } catch {
            emit(.failed(messageID: messageID, error: error))
            throw error
        }

        // Strong capture: the consumer task owns this generation's logical
        // unit of work and must complete (emit terminal event, clean up
        // `inFlight`) even if the host releases its last reference to the
        // runtime mid-flight.
        let task = Task { @MainActor [self] in
            await self.consume(
                stream: stream,
                messageID: messageID,
                prompt: prompt,
                placeholder: placeholder,
                snapshot: snapshot
            )
        }
        inFlight[messageID] = task
        return messageID
    }

    /// Cancels an in-flight generation by its placeholder message ID.
    ///
    /// Idempotent — cancelling an unknown or already-finished message is a
    /// no-op. The terminal ``VideoRuntimeEvent/cancelled(messageID:)`` event
    /// fires once the underlying stream observes the cancellation.
    public func cancel(messageID: ChatMessage.ID) async {
        guard let task = inFlight[messageID] else { return }
        task.cancel()
        // Don't await `task.value` — the consumer task itself emits the
        // terminal event and removes itself from `inFlight`. Awaiting here
        // would serialise callers behind a cloud poll loop's cancellation
        // latency.
    }

    // MARK: - Stream consumer

    private func consume(
        stream: AsyncThrowingStream<VideoGenerationEvent, Error>,
        messageID: ChatMessage.ID,
        prompt: String,
        placeholder: ChatMessage,
        snapshot: VideoGenerationConfigSnapshot
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
                case .queued:
                    // No dedicated `VideoRuntimeEvent` for queued — forward
                    // as zero-progress so adapters can show an initial indicator.
                    emit(.progress(messageID: messageID, fractionComplete: 0.0))

                case .generating(let fraction):
                    emit(.progress(messageID: messageID, fractionComplete: fraction))

                case .completed(let url):
                    let identifier = modelIdentifierProvider()
                    let payload = VideoMessagePayload(
                        prompt: prompt,
                        videoURL: url,
                        modelIdentifier: identifier,
                        generationConfig: snapshot
                    )
                    var finalised = placeholder
                    finalised.contentParts = [.generatedMedia(GeneratedMediaPayload(video: payload))]
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
            // when the task is cancelled, otherwise report as failure.
            if Task.isCancelled {
                emit(.cancelled(messageID: messageID))
            } else {
                emit(.failed(
                    messageID: messageID,
                    error: VideoGenerationServiceError.alreadyGenerating
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

    private func emit(_ event: VideoRuntimeEvent) {
        continuation.yield(event)
        eventTaps.broadcast(event)
    }
}

// MARK: - AsyncSequence Conformance

extension VideoGenerationRuntime: AsyncSequence {
    public typealias Element = VideoRuntimeEvent
    public typealias AsyncIterator = AsyncStream<VideoRuntimeEvent>.AsyncIterator

    /// Returns an iterator over the video runtime events in this stream.
    ///
    /// Allows idiomatic iteration with `for await event in runtime { … }`
    /// instead of `for await event in runtime.events { … }`.
    public nonisolated func makeAsyncIterator() -> AsyncStream<VideoRuntimeEvent>.AsyncIterator {
        events.makeAsyncIterator()
    }
}
