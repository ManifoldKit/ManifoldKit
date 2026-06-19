import Foundation
import ManifoldInference

// MARK: - AudioGenerationRuntime
//
// Sibling to `ImageGenerationRuntime` / `VideoGenerationRuntime` for the
// audio-generation (TTS) path. Owns an `AudioGenerationService`, drives
// `generate(config:)`, and persists the resulting `.generatedMedia` part (with
// `MediaKind.audio`) via the `MessageStore` port.
//
// Per umbrella #1002:
//   - Audio-side runtime is a sibling type, not a new method on the image/video
//     runtimes or `ConversationRuntime`. Audio lifecycle has its own shape
//     (one-shot synth, no model load, no preview) and squeezing it into another
//     runtime would distort both surfaces.
//   - Events ride `AudioRuntimeEvent` — distinct from `ImageRuntimeEvent`,
//     `VideoRuntimeEvent`, and `ConversationEvent` so exhaustive switches in
//     those consumers stay closed.
//   - Persistence uses the existing `MessageStore` port. The runtime inserts an
//     empty placeholder on `generate` and updates it in place with the
//     `.generatedMedia` part when the backend completes.
//
// Concurrency: `@MainActor` because both `MessageStore` and
// `AudioGenerationService` are `@MainActor`-isolated. The backend's stream is
// consumed on a `Task` per generation so `cancel(messageID:)` can locate and
// tear it down by ID without blocking the actor.

/// Drives audio-generation (TTS) lifecycle through ``AudioGenerationService``
/// and persists results via ``MessageStore``.
///
/// Sibling to ``ImageGenerationRuntime`` / ``VideoGenerationRuntime``. Hosts
/// call ``generate(config:in:)`` to start a generation, observe progress on
/// ``events`` (an ``AsyncStream`` of ``AudioRuntimeEvent``), and call
/// ``cancel(messageID:)`` to tear down an in-flight job.
///
/// ## Persistence
///
/// On ``generate(config:in:)`` the runtime inserts a placeholder
/// ``ChatMessage`` (role `.assistant`, empty `contentParts`) into the message
/// store. Backend progress events are forwarded as
/// ``AudioRuntimeEvent/progress(messageID:step:totalSteps:)`` *without* touching
/// the store — UI subscribes to events for the in-flight indicator; persistence
/// stays minimal until the terminal step.
///
/// On backend completion the runtime builds a ``GeneratedMediaPayload`` of
/// ``MediaKind/audio`` and updates the placeholder via
/// ``MessageStore/updateMessage(_:)`` so its `contentParts` becomes a single
/// ``MessagePart/generatedMedia(_:)`` carrying the payload, then emits
/// ``AudioRuntimeEvent/completed(messageID:payload:)``.
///
/// On error or cancellation the placeholder remains in the store with its
/// original empty `contentParts`; the runtime emits the terminal event and the
/// host decides UX.
///
/// ## Concurrency
///
/// `@MainActor`-isolated for parity with both ports. Each in-flight generation
/// runs on a tracked `Task` keyed to its placeholder message ID;
/// ``cancel(messageID:)`` cancels the task and stops the backend via
/// ``AudioGenerationService``'s `AsyncThrowingStream` cancellation hook (which
/// calls `backend.stopGeneration()` per the service contract).
@MainActor
public final class AudioGenerationRuntime {

    // MARK: Ports

    private let service: AudioGenerationService
    private let messageStore: any MessageStore
    private let modelIdentifierProvider: @MainActor () -> String

    // MARK: Event stream

    /// Lifecycle event stream. Single-consumer by design — adapters either
    /// iterate it directly or install an observable wrapper.
    public let events: AsyncStream<AudioRuntimeEvent>
    private let continuation: AsyncStream<AudioRuntimeEvent>.Continuation

    /// Fan-out registry for secondary observers installed via
    /// ``addEventTap(bufferingPolicy:)``. Separate from the primary ``events``
    /// stream so a developer inspector can observe the same event flow the host
    /// adapter already drains, without competing for the single-consumer
    /// ``events`` stream.
    private let eventTaps = EventTapRegistry<AudioRuntimeEvent>()

    // MARK: In-flight state

    private var inFlight: [ChatMessage.ID: Task<Void, Never>] = [:]

    // MARK: Init

    /// Creates a runtime that composes the supplied service and message store.
    ///
    /// - Parameters:
    ///   - service: The ``AudioGenerationService`` the runtime drives.
    ///   - messageStore: Required. Persists the placeholder and final
    ///     `.generatedMedia` (audio) part across the generation.
    ///   - modelIdentifier: Closure returning the identifier embedded in
    ///     ``GeneratedMediaPayload/modelIdentifier``. Defaults to
    ///     `"apple-tts"` — the in-core reference backend. Tests inject this
    ///     when they want a deterministic identifier.
    public init(
        service: AudioGenerationService,
        messageStore: any MessageStore,
        modelIdentifier: (@MainActor () -> String)? = nil
    ) {
        self.service = service
        self.messageStore = messageStore
        self.modelIdentifierProvider = modelIdentifier ?? { "apple-tts" }
        let (stream, continuation) = AsyncStream<AudioRuntimeEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
        eventTaps.finishAll()
    }

    // MARK: Secondary event taps

    /// Installs a secondary multicast tap on this runtime's event flow.
    ///
    /// The returned stream receives every ``AudioRuntimeEvent`` the primary
    /// ``events`` stream sees. The tap is independent of the primary consumer.
    ///
    /// - Parameter bufferingPolicy: Controls what happens when the tap consumer
    ///   falls behind. Defaults to `.unbounded` so no events are dropped.
    /// - Returns: An `AsyncStream` that delivers events until the runtime
    ///   terminates, at which point the stream finishes normally.
    public func addEventTap(
        bufferingPolicy: AsyncStream<AudioRuntimeEvent>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<AudioRuntimeEvent> {
        AsyncStream(bufferingPolicy: bufferingPolicy) { [eventTaps] continuation in
            let id = eventTaps.register(continuation)
            continuation.onTermination = { _ in
                eventTaps.deregister(id)
            }
        }
    }

    // MARK: Commands

    /// Begins an audio generation in the supplied session.
    ///
    /// Persists a placeholder ``ChatMessage`` (role `.assistant`, empty
    /// `contentParts`) before returning, then starts a detached task that
    /// forwards backend events through ``events``. The returned message ID is
    /// stable for the lifetime of the generation — pass it to
    /// ``cancel(messageID:)`` to tear down the job, and observe the terminal
    /// event (`completed` / `failed` / `cancelled`) on ``events`` to know when
    /// the placeholder has been finalised.
    ///
    /// - Parameters:
    ///   - config: TTS generation parameters (text, voice, rate, pitch,
    ///     output directory).
    ///   - sessionID: The session the placeholder message belongs to.
    /// - Returns: The placeholder ``ChatMessage/ID`` so the host can pair UI
    ///   state with the in-flight generation.
    /// - Throws: Persistence errors from the placeholder insert.
    @discardableResult
    public func generate(
        config: SpeechGenerationConfig,
        in sessionID: UUID
    ) async throws -> ChatMessage.ID {
        let placeholder = ChatMessage(
            role: .assistant,
            contentParts: [],
            sessionID: sessionID
        )
        try await messageStore.insertMessage(placeholder)

        let messageID = placeholder.id
        let prompt = config.text
        emit(.started(messageID: messageID, prompt: prompt))

        let stream = service.generate(config: config)

        // Strong capture: the consumer task owns this generation's logical unit
        // of work and must complete (emit terminal event, clean up `inFlight`)
        // even if the host releases its last reference to the runtime mid-flight.
        let task = Task { @MainActor [self] in
            await self.consume(
                stream: stream,
                messageID: messageID,
                prompt: prompt,
                placeholder: placeholder
            )
        }
        inFlight[messageID] = task
        return messageID
    }

    /// Cancels an in-flight generation by its placeholder message ID.
    ///
    /// Idempotent — cancelling an unknown or already-finished message is a
    /// no-op. The terminal ``AudioRuntimeEvent/cancelled(messageID:)`` event
    /// fires once the underlying stream observes the cancellation.
    public func cancel(messageID: ChatMessage.ID) async {
        guard let task = inFlight[messageID] else { return }
        task.cancel()
        // Don't await `task.value` — the consumer task itself emits the
        // terminal event and removes itself from `inFlight`.
    }

    // MARK: - Stream consumer

    private func consume(
        stream: AsyncThrowingStream<AudioGenerationEvent, Error>,
        messageID: ChatMessage.ID,
        prompt: String,
        placeholder: ChatMessage
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
                    let resolvedTotal = total > 0 ? total : step
                    emit(.progress(messageID: messageID, step: step, totalSteps: resolvedTotal))

                case .completed(let url):
                    let payload = GeneratedMediaPayload(
                        kind: .audio,
                        prompt: prompt,
                        url: url,
                        modelIdentifier: modelIdentifierProvider(),
                        format: Self.audioFormat(for: url)
                    )
                    var finalised = placeholder
                    finalised.contentParts = [.generatedMedia(payload)]
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
            // Stream ended without `.completed` — treat as cancellation when the
            // task is cancelled, otherwise report a failure so adapters surface
            // something rather than silently abandoning the placeholder.
            if Task.isCancelled {
                emit(.cancelled(messageID: messageID))
            } else {
                emit(.failed(
                    messageID: messageID,
                    error: AudioGenerationServiceError.alreadyGenerating
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

    private func emit(_ event: AudioRuntimeEvent) {
        continuation.yield(event)
        eventTaps.broadcast(event)
    }

    /// Best-effort MIME type from the artifact's file extension. Mirrors the
    /// "consumer derives format from URL when nil" convention on
    /// ``GeneratedMediaPayload`` but populates it eagerly for the common
    /// extensions the reference backend writes.
    private static func audioFormat(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "caf": return "audio/x-caf"
        case "wav": return "audio/wav"
        case "m4a", "aac": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        default: return nil
        }
    }
}

// MARK: - AsyncSequence Conformance

extension AudioGenerationRuntime: AsyncSequence {
    public typealias Element = AudioRuntimeEvent
    public typealias AsyncIterator = AsyncStream<AudioRuntimeEvent>.AsyncIterator

    /// Returns an iterator over the audio runtime events in this stream.
    ///
    /// Allows idiomatic iteration with `for await event in runtime { … }`
    /// instead of `for await event in runtime.events { … }`.
    public nonisolated func makeAsyncIterator() -> AsyncStream<AudioRuntimeEvent>.AsyncIterator {
        events.makeAsyncIterator()
    }
}
