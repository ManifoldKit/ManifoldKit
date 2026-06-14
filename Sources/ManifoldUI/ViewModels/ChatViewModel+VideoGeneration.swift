import Foundation
import ManifoldRuntime
import ManifoldInference

// MARK: - ChatViewModel + VideoGeneration
//
// Host-facing entry surface for `VideoGenerationRuntime`. Mirrors the role
// `ChatViewModel+ImageGeneration` plays for `ImageGenerationRuntime`: forwards
// commands to the runtime and maps `VideoRuntimeEvent` back to `@Observable`
// state on `@MainActor`.
//
// The runtime is **optional** — chat-only hosts never call
// `configure(videoRuntime:)` and the video methods throw `.notConfigured`.
// The text and image paths on `ChatViewModel` are unchanged.

/// Per-message progress snapshot for in-flight or completed video generations.
///
/// Populated by ``ChatViewModel/videoGenerationProgress`` from
/// ``VideoRuntimeEvent`` values. Hosts subscribe via `@Observable` to render
/// progress UIs keyed off the placeholder message ID returned by
/// ``ChatViewModel/generateVideo(prompt:config:)``.
public struct VideoGenerationProgress: Sendable, Equatable {

    /// The placeholder ``ChatMessage/ID`` the generation is writing to.
    public let messageID: UUID

    /// User-supplied prompt the generation was started with.
    public let prompt: String

    /// Backend-estimated fraction complete, 0.0–1.0. `0` while queued or
    /// waiting for the first progress event.
    public let fractionComplete: Double

    /// `true` once a terminal event (completed / failed / cancelled) has been
    /// observed. UI can stop animating progress affordances at this point.
    public let isComplete: Bool

    /// Localized error description if the generation failed; `nil` otherwise.
    /// Set independently of ``isComplete`` so cancellation surfaces as
    /// `isComplete = true, error = nil`.
    public let error: String?

    public init(
        messageID: UUID,
        prompt: String,
        fractionComplete: Double,
        isComplete: Bool,
        error: String?
    ) {
        self.messageID = messageID
        self.prompt = prompt
        self.fractionComplete = fractionComplete
        self.isComplete = isComplete
        self.error = error
    }
}

/// Errors thrown by ``ChatViewModel`` video-generation entry methods.
public enum ChatViewModelVideoError: Error, LocalizedError, Equatable {

    /// ``ChatViewModel/configure(videoRuntime:)`` was never called.
    case notConfigured

    /// ``ChatViewModel/activeSession`` is `nil` — there is no conversation
    /// to insert the placeholder video message into.
    case noActiveConversation

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Video generation is not configured. Install a VideoGenerationRuntime via configure(videoRuntime:)."
        case .noActiveConversation:
            return "No active conversation. Create or select a session before generating a video."
        }
    }
}

@MainActor
extension ChatViewModel {

    // MARK: - Runtime install

    /// The video-generation runtime, if the host wired one up. `nil` for
    /// chat-only hosts; video methods throw ``ChatViewModelVideoError/notConfigured``
    /// in that case.
    public var videoRuntime: VideoGenerationRuntime? {
        _videoRuntime
    }

    /// Install a ``VideoGenerationRuntime``. Typically called by
    /// ``ManifoldBootstrap`` when the host opts in to video generation;
    /// app code can also call it directly.
    ///
    /// Latest-wins: a prior runtime's event-drain task is cancelled before
    /// the new one starts, so reconfiguring at runtime is safe. The view
    /// model holds the runtime strongly for the rest of its lifetime — same
    /// ownership model as ``imageRuntime``.
    public func configure(videoRuntime: VideoGenerationRuntime) {
        _videoRuntime = videoRuntime
        startVideoRuntimeEventDrain(runtime: videoRuntime)
    }

    /// Cancels the existing video-runtime drain task (if any) and starts a
    /// fresh one for `runtime`.
    ///
    /// Weak capture mirrors the image-runtime drain: the host owns the view
    /// model, and the drain task must not keep old test or preview instances
    /// alive after their bootstrap and SwiftData container tear down.
    private func startVideoRuntimeEventDrain(runtime: VideoGenerationRuntime) {
        videoRuntimeEventDrainTask?.cancel()
        videoRuntimeEventDrainTask = Task { [weak self] in
            for await event in runtime.events {
                if Task.isCancelled { return }
                guard let self else { return }
                self.handle(videoRuntimeEvent: event)
            }
        }
    }

    // MARK: - Commands

    /// Begin a video generation in the active conversation.
    ///
    /// Inserts a placeholder ``ChatMessage`` immediately (via the
    /// runtime's `MessageStore` port) and dispatches a consumer task that
    /// updates ``videoGenerationProgress`` from runtime events. Returns the
    /// placeholder message ID synchronously so the caller can pair UI state
    /// with the in-flight generation.
    ///
    /// - Parameters:
    ///   - prompt: User-supplied prompt.
    ///   - config: Video generation parameters.
    /// - Returns: The placeholder ``ChatMessage/ID``.
    /// - Throws: ``ChatViewModelVideoError/notConfigured`` if no runtime is
    ///   installed, ``ChatViewModelVideoError/noActiveConversation`` if
    ///   there is no active session, or any persistence / backend error from
    ///   the generation submit.
    @discardableResult
    public func generateVideo(
        prompt: String,
        config: VideoGenerationConfig
    ) async throws -> UUID {
        guard let runtime = _videoRuntime else {
            throw ChatViewModelVideoError.notConfigured
        }
        guard let sessionID = activeSessionID else {
            throw ChatViewModelVideoError.noActiveConversation
        }
        return try await runtime.generate(
            prompt: prompt,
            config: config,
            in: sessionID
        )
    }

    /// Cancel an in-flight video generation by its placeholder message ID.
    ///
    /// Idempotent — cancelling an unknown or already-finished generation is
    /// a no-op. The terminal ``VideoRuntimeEvent/cancelled(messageID:)``
    /// event flips ``VideoGenerationProgress/isComplete`` to `true` once the
    /// underlying stream observes the cancellation.
    public func cancelVideoGeneration(messageID: UUID) async {
        guard let runtime = _videoRuntime else { return }
        await runtime.cancel(messageID: messageID)
    }

    // MARK: - Event drain

    /// Maps an incoming ``VideoRuntimeEvent`` to mutations on
    /// ``videoGenerationProgress``. Sibling to
    /// ``handle(imageRuntimeEvent:)`` for ``VideoRuntimeEvent``.
    func handle(videoRuntimeEvent event: VideoRuntimeEvent) {
        switch event {
        case .started(let messageID, let prompt):
            videoGenerationProgress[messageID] = VideoGenerationProgress(
                messageID: messageID,
                prompt: prompt,
                fractionComplete: 0.0,
                isComplete: false,
                error: nil
            )
            if let sessionID = activeSessionID {
                let placeholder = ChatMessage(
                    id: messageID,
                    role: .assistant,
                    contentParts: [],
                    sessionID: sessionID
                )
                messages.append(placeholder)
            }

        case .progress(let messageID, let fractionComplete):
            // A `progress` for an unknown ID would mean we missed `started`;
            // create the entry with what we know rather than dropping the
            // event silently.
            let prompt = videoGenerationProgress[messageID]?.prompt ?? ""
            videoGenerationProgress[messageID] = VideoGenerationProgress(
                messageID: messageID,
                prompt: prompt,
                fractionComplete: fractionComplete,
                isComplete: false,
                error: nil
            )

        case .completed(let messageID, let payload):
            let existing = videoGenerationProgress[messageID]
            videoGenerationProgress[messageID] = VideoGenerationProgress(
                messageID: messageID,
                prompt: existing?.prompt ?? payload.prompt,
                fractionComplete: 1.0,
                isComplete: true,
                error: nil
            )
            if let idx = messages.firstIndex(where: { $0.id == messageID }) {
                messages[idx].contentParts = [.generatedMedia(GeneratedMediaPayload(video: payload))]
            }

        case .failed(let messageID, let error):
            let existing = videoGenerationProgress[messageID]
            videoGenerationProgress[messageID] = VideoGenerationProgress(
                messageID: messageID,
                prompt: existing?.prompt ?? "",
                fractionComplete: existing?.fractionComplete ?? 0.0,
                isComplete: true,
                error: error.localizedDescription
            )

        case .cancelled(let messageID):
            let existing = videoGenerationProgress[messageID]
            videoGenerationProgress[messageID] = VideoGenerationProgress(
                messageID: messageID,
                prompt: existing?.prompt ?? "",
                fractionComplete: existing?.fractionComplete ?? 0.0,
                isComplete: true,
                error: nil
            )
        }
    }
}
