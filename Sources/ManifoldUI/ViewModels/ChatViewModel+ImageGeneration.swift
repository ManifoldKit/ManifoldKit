import Foundation
import ManifoldRuntime
import ManifoldInference

// MARK: - ChatViewModel + ImageGeneration
//
// Host-facing entry surface for `ImageGenerationRuntime`. Mirrors the role
// `ChatViewModel+RuntimeAdapter` plays for `ConversationRuntime`: forwards
// commands to the runtime and maps `ImageRuntimeEvent` back to `@Observable`
// state on `@MainActor`.
//
// The runtime is **optional** — chat-only hosts never call
// `configure(imageRuntime:)` and the image methods throw `.notConfigured`.
// The text path on `ChatViewModel` is unchanged.

/// Per-message progress snapshot for in-flight or completed image generations.
///
/// Populated by ``ChatViewModel/imageGenerationProgress`` from
/// ``ImageRuntimeEvent`` values. Hosts subscribe via `@Observable` to render
/// progress UIs keyed off the placeholder message ID returned by
/// ``ChatViewModel/generateImage(prompt:config:)``.
public struct ImageGenerationProgress: Sendable, Equatable {

    /// The placeholder ``ChatMessage/ID`` the generation is writing to.
    public let messageID: UUID

    /// User-supplied prompt the generation was started with.
    public let prompt: String

    /// 1-indexed denoising step. `0` while waiting for the first
    /// ``ImageRuntimeEvent/progress(messageID:step:totalSteps:)`` event.
    public let step: Int

    /// Total denoising steps the runtime is targeting (after backend clamp,
    /// or the backend's own model-preset default when the caller left
    /// ``ImageGenerationConfig/steps`` `nil`). `0` before the first progress
    /// event arrives — and can legitimately stay `0` for the rest of the
    /// run if a non-compliant backend never resolves a real count (see the
    /// "Step-count resolution contract" on
    /// ``ImageGenerationBackend/generate(prompt:config:)``); this is not
    /// exclusively a "waiting for the first tick" state.
    public let totalSteps: Int

    /// `true` once a terminal event (completed / failed / cancelled) has been
    /// observed. UI can stop animating progress affordances at this point.
    public let isComplete: Bool

    /// Localized error description if the generation failed; `nil` otherwise.
    /// Set independently of ``isComplete`` so cancellation surfaces as
    /// `isComplete = true, error = nil`.
    public let error: String?

    /// Latest intermediate denoise preview as encoded image bytes (PNG/JPEG),
    /// or `nil` when previews are disabled (the default — see
    /// ``ImageGenerationConfig/previewStride``) or none has arrived yet.
    /// Each ``ImageRuntimeEvent/preview(messageID:step:totalSteps:image:)``
    /// replaces the prior value so UI renders only the freshest thumbnail.
    public let previewImage: Data?

    /// Original initializer, preserved unchanged for source compatibility with
    /// pre-preview callers. Leaves ``previewImage`` `nil`. The mangled symbol of
    /// this six-argument init must stay identical to its origin/main shape — the
    /// preview parameter lives on the separate initializer below, not as a
    /// defaulted argument here (a defaulted addition still changes the symbol and
    /// trips the public-API source-compatibility gate).
    public init(
        messageID: UUID,
        prompt: String,
        step: Int,
        totalSteps: Int,
        isComplete: Bool,
        error: String?
    ) {
        self.messageID = messageID
        self.prompt = prompt
        self.step = step
        self.totalSteps = totalSteps
        self.isComplete = isComplete
        self.error = error
        self.previewImage = nil
    }

    /// Preview-aware initializer. Use this overload to thread an intermediate
    /// denoise ``previewImage`` through; the six-argument init above remains for
    /// existing callers.
    public init(
        messageID: UUID,
        prompt: String,
        step: Int,
        totalSteps: Int,
        isComplete: Bool,
        error: String?,
        previewImage: Data?
    ) {
        self.messageID = messageID
        self.prompt = prompt
        self.step = step
        self.totalSteps = totalSteps
        self.isComplete = isComplete
        self.error = error
        self.previewImage = previewImage
    }
}

/// Errors thrown by ``ChatViewModel`` image-generation entry methods.
public enum ChatViewModelImageError: Error, LocalizedError, Equatable {

    /// ``ChatViewModel/configure(imageRuntime:)`` was never called.
    case notConfigured

    /// ``ChatViewModel/activeSession`` is `nil` — there is no conversation
    /// to insert the placeholder image message into.
    case noActiveConversation

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Image generation is not configured. Install an ImageGenerationRuntime via configure(imageRuntime:)."
        case .noActiveConversation:
            return "No active conversation. Create or select a session before generating an image."
        }
    }
}

@MainActor
extension ChatViewModel {

    // MARK: - Runtime install

    /// The image-generation runtime, if the host wired one up. `nil` for
    /// chat-only hosts; image methods throw ``ChatViewModelImageError/notConfigured``
    /// in that case.
    public var imageRuntime: ImageGenerationRuntime? {
        _imageRuntime
    }

    /// Install an ``ImageGenerationRuntime``. Typically called by
    /// ``ManifoldBootstrap`` when the host opts in to image generation;
    /// app code can also call it directly.
    ///
    /// Latest-wins: a prior runtime's event-drain task is cancelled before
    /// the new one starts, so reconfiguring at runtime is safe. The view
    /// model holds the runtime strongly for the rest of its lifetime — same
    /// ownership model as ``conversationRuntime``.
    public func configure(imageRuntime: ImageGenerationRuntime) {
        _imageRuntime = imageRuntime
        startImageRuntimeEventDrain(runtime: imageRuntime)
    }

    /// Cancels the existing image-runtime drain task (if any) and starts a
    /// fresh one for `runtime`.
    ///
    /// Weak capture mirrors the chat-runtime drain: the host owns the view
    /// model, and the drain task must not keep old test or preview instances
    /// alive after their bootstrap and SwiftData container tear down.
    private func startImageRuntimeEventDrain(runtime: ImageGenerationRuntime) {
        imageRuntimeEventDrainTask?.cancel()
        imageRuntimeEventDrainTask = Task { [weak self] in
            for await event in runtime.events {
                if Task.isCancelled { return }
                guard let self else { return }
                self.handle(imageRuntimeEvent: event)
            }
        }
    }

    // MARK: - Commands

    /// Begin an image generation in the active conversation.
    ///
    /// Inserts a placeholder ``ChatMessage`` immediately (via the
    /// runtime's `MessageStore` port) and dispatches a consumer task that
    /// updates ``imageGenerationProgress`` from runtime events. Returns the
    /// placeholder message ID synchronously so the caller can pair UI state
    /// with the in-flight generation.
    ///
    /// - Parameters:
    ///   - prompt: User-supplied prompt.
    ///   - config: Sampling and diffusion parameters.
    /// - Returns: The placeholder ``ChatMessage/ID``.
    /// - Throws: ``ChatViewModelImageError/notConfigured`` if no runtime is
    ///   installed, ``ChatViewModelImageError/noActiveConversation`` if
    ///   there is no active session, or any persistence error from the
    ///   placeholder insert.
    @discardableResult
    public func generateImage(
        prompt: String,
        config: ImageGenerationConfig
    ) async throws -> UUID {
        guard let runtime = _imageRuntime else {
            throw ChatViewModelImageError.notConfigured
        }
        guard let sessionID = activeSessionID else {
            throw ChatViewModelImageError.noActiveConversation
        }
        return try await runtime.generate(
            prompt: prompt,
            config: config,
            in: sessionID
        )
    }

    /// Cancel an in-flight image generation by its placeholder message ID.
    ///
    /// Idempotent — cancelling an unknown or already-finished generation is
    /// a no-op. The terminal ``ImageRuntimeEvent/cancelled(messageID:)``
    /// event flips ``ImageGenerationProgress/isComplete`` to `true` once the
    /// underlying stream observes the cancellation.
    public func cancelImageGeneration(messageID: UUID) async {
        guard let runtime = _imageRuntime else { return }
        await runtime.cancel(messageID: messageID)
    }

    // MARK: - Event drain

    /// Maps an incoming ``ImageRuntimeEvent`` to mutations on
    /// ``imageGenerationProgress``. Sibling to
    /// ``handle(runtimeEvent:)`` for ``ConversationEvent``.
    func handle(imageRuntimeEvent event: ImageRuntimeEvent) {
        switch event {
        case .started(let messageID, let prompt):
            imageGenerationProgress[messageID] = ImageGenerationProgress(
                messageID: messageID,
                prompt: prompt,
                step: 0,
                totalSteps: 0,
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

        case .progress(let messageID, let step, let totalSteps):
            // A `progress` for an unknown ID would mean we missed `started`;
            // create the entry with what we know rather than dropping the
            // event silently. The prompt is unrecoverable here, so leave it
            // empty — hosts observing this case can treat it as a recovery
            // path.
            let prompt = imageGenerationProgress[messageID]?.prompt ?? ""
            imageGenerationProgress[messageID] = ImageGenerationProgress(
                messageID: messageID,
                prompt: prompt,
                step: step,
                totalSteps: totalSteps,
                isComplete: false,
                error: nil
            )

        case .preview(let messageID, let step, let totalSteps, let image):
            // Carry the latest preview thumbnail forward, preserving the
            // prompt observed at `started`. Like `progress`, recover a
            // missing entry rather than dropping the event.
            let existing = imageGenerationProgress[messageID]
            imageGenerationProgress[messageID] = ImageGenerationProgress(
                messageID: messageID,
                prompt: existing?.prompt ?? "",
                step: step,
                totalSteps: totalSteps,
                isComplete: false,
                error: nil,
                previewImage: image
            )

        case .completed(let messageID, let payload):
            let existing = imageGenerationProgress[messageID]
            imageGenerationProgress[messageID] = ImageGenerationProgress(
                messageID: messageID,
                prompt: existing?.prompt ?? payload.prompt,
                step: existing?.totalSteps ?? 0,
                totalSteps: existing?.totalSteps ?? 0,
                isComplete: true,
                error: nil
            )
            if let idx = messages.firstIndex(where: { $0.id == messageID }) {
                messages[idx].contentParts = [.generatedMedia(GeneratedMediaPayload(image: payload))]
            }

        case .failed(let messageID, let error):
            let existing = imageGenerationProgress[messageID]
            imageGenerationProgress[messageID] = ImageGenerationProgress(
                messageID: messageID,
                prompt: existing?.prompt ?? "",
                step: existing?.step ?? 0,
                totalSteps: existing?.totalSteps ?? 0,
                isComplete: true,
                error: error.localizedDescription
            )

        case .cancelled(let messageID):
            let existing = imageGenerationProgress[messageID]
            imageGenerationProgress[messageID] = ImageGenerationProgress(
                messageID: messageID,
                prompt: existing?.prompt ?? "",
                step: existing?.step ?? 0,
                totalSteps: existing?.totalSteps ?? 0,
                isComplete: true,
                error: nil
            )
        }
    }
}
