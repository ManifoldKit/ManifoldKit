import Foundation
import BaseChatRuntime
import BaseChatInference

// MARK: - PendingPayload

/// Content handed to ``ChatViewModel/ingestPendingPayload(_:intent:)``
/// from a host-app entry point such as a Share Extension, Action
/// Extension, or App Intent.
///
/// Each case maps onto the message-part shape the chat surface already
/// understands so the ingest path does not need a new wire format. Apps
/// that already vend ``InboundPayload`` to ``ChatViewModel/ingest(_:)``
/// continue to work — this API is the public seam for richer entry
/// points that need to control session lifecycle (new vs. append vs.
/// draft) without poking at internal state.
public enum PendingPayload: Sendable {

    /// Plain text — used as the user message body.
    case text(String)

    /// A URL — serialised into the user message body as its absolute
    /// string. Hosts that want to attach link metadata should resolve
    /// the URL themselves and pass the resulting prose as ``text``.
    case url(URL)

    /// An image, carried verbatim as a ``MessagePart/image`` part.
    ///
    /// `mimeType` defaults to `"image/png"` since most extension
    /// pasteboards expose PNG; pass an explicit value for JPEG, HEIC,
    /// etc.
    case image(
        Data,
        mimeType: String = "image/png",
        placeholderHash: ImagePlaceholderHash? = nil
    )

    /// A file URL pointing at content the host has already staged
    /// inside the app group. Today the file's path is rendered into
    /// the user message body as text — this matches the existing
    /// ``MessagePart`` surface, which has no file case yet. Image
    /// files should use ``image(_:mimeType:)`` so they ride as image
    /// parts.
    case file(URL)
}

// MARK: - IngestionPreset

/// Optional configuration applied when ``IngestionIntent/newSession``
/// creates a fresh session.
///
/// Every field is optional — the view model only mutates the matching
/// state when a value is provided, so partial presets layer cleanly on
/// top of whatever the user already has selected. Hosts that don't
/// need any preset can pass `nil` directly to
/// ``IngestionIntent/newSession(preset:)``.
///
/// ## Model selection
///
/// ``modelID`` matches against ``ChatViewModel/availableModels`` by
/// ``ModelInfo/id`` (UUID string) first, then by ``ModelInfo/name``.
/// If no match is found the current selection is left untouched and a
/// warning is logged — extensions that hand off before model discovery
/// has run still get a usable session, just without a forced switch.
public struct IngestionPreset: Sendable {

    /// Identifier or name of the model to select for the new session.
    public let modelID: String?

    /// System prompt to install on the new session. Empty string is
    /// treated as "clear the prompt".
    public let systemPrompt: String?

    /// Sampling temperature override. `nil` leaves the existing
    /// session default in place.
    public let temperature: Float?

    /// Top-P override. `nil` leaves the existing session default in
    /// place.
    public let topP: Float?

    /// Repeat-penalty override. `nil` leaves the existing session
    /// default in place.
    public let repeatPenalty: Float?

    public init(
        modelID: String? = nil,
        systemPrompt: String? = nil,
        temperature: Float? = nil,
        topP: Float? = nil,
        repeatPenalty: Float? = nil
    ) {
        self.modelID = modelID
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.repeatPenalty = repeatPenalty
    }
}

// MARK: - IngestionIntent

/// How a ``PendingPayload`` should be applied to ``ChatViewModel``.
public enum IngestionIntent: Sendable {

    /// Create a brand-new chat session, apply the optional preset, and
    /// seed the payload as the first user message. When a model is
    /// loaded the message is sent through the same path as the compose
    /// bar; otherwise the message is left in the input draft so the
    /// user can confirm after picking a model.
    case newSession(preset: IngestionPreset?)

    /// Append the payload onto whatever is currently in the input
    /// draft of the active session. No send, no session creation —
    /// this is for "add to current chat" affordances.
    case appendToActive

    /// Set the input draft to the payload's text but do not send it.
    /// Use this for previewing payloads before the user commits.
    case draft
}

// MARK: - ChatViewModel + ingestPendingPayload

extension ChatViewModel {

    /// Hands off content from a Share Extension, Action Extension, App
    /// Intent, or other host-app entry point to BaseChatKit.
    ///
    /// This is the supported public seam for extension-driven session
    /// creation. It composes existing public APIs on
    /// ``ChatViewModel`` — session creation, message seeding,
    /// generation — without exposing ``InferenceService`` to the host.
    ///
    /// The behaviour for each ``IngestionIntent`` is:
    ///
    /// - ``IngestionIntent/newSession(preset:)``: insert a new
    ///   ``ChatSessionRecord`` via the configured persistence
    ///   provider, switch to it, apply the preset (model selection,
    ///   system prompt, sampler params), seed the payload as a user
    ///   message, and run ``sendMessage()`` if a model is loaded.
    ///   When no model is loaded the payload remains as
    ///   ``inputText`` so the user can pick a model and send manually
    ///   — this matches the compose-bar contract and avoids surfacing
    ///   "no model loaded" errors as a launch-time failure.
    /// - ``IngestionIntent/appendToActive``: append the payload onto
    ///   the active session's input draft. No persistence write, no
    ///   send.
    /// - ``IngestionIntent/draft``: replace the input draft with the
    ///   payload. No persistence write, no send.
    ///
    /// ## Requirements
    ///
    /// ``configure(runtime:)`` or ``configure(persistence:)`` must have been
    /// called before ``IngestionIntent/newSession(preset:)`` is used. Without
    /// persistence the call no-ops after logging a warning. The two
    /// non-persisting intents (``IngestionIntent/appendToActive``,
    /// ``IngestionIntent/draft``) work without persistence.
    ///
    /// - Parameters:
    ///   - payload: The content to ingest.
    ///   - intent: How the payload should be applied to the view
    ///     model.
    @MainActor
    public func ingestPendingPayload(
        _ payload: PendingPayload,
        intent: IngestionIntent
    ) async {
        Log.ui.info(
            "ChatViewModel.ingestPendingPayload intent=\(String(describing: intent), privacy: .public) kind=\(payload.kindLabel, privacy: .public)"
        )

        switch intent {
        case .newSession(let preset):
            await ingestAsNewSession(payload, preset: preset)
        case .appendToActive:
            ingestByAppendingToDraft(payload)
        case .draft:
            ingestAsDraft(payload)
        }
    }

    // MARK: - Per-intent helpers

    @MainActor
    private func ingestAsNewSession(
        _ payload: PendingPayload,
        preset: IngestionPreset?
    ) async {
        guard let persistence = persistenceOrLog("ingestPendingPayload(.newSession)") else { return }

        // Pre-resolve the system prompt so the new session is inserted
        // with the preset already applied — avoids a second persistence
        // write when the only change is the system prompt.
        let session = ChatSessionRecord(
            title: "New Chat",
            systemPrompt: preset?.systemPrompt ?? ""
        )
        do {
            try await persistence.insertSession(session)
        } catch {
            Log.persistence.error(
                "ChatViewModel.ingestPendingPayload failed to insert session: \(error.localizedDescription)"
            )
            surfaceError(error, kind: .persistence)
            return
        }
        await switchToSession(session)

        if let preset {
            applyPreset(preset)
            // Persist the preset onto the session record so sampler params,
            // selected model, and system prompt survive a relaunch — without
            // this, only the live VM state has the preset values and they
            // get lost when the session is reloaded.
            do {
                try await saveSettingsToSession()
            } catch {
                Log.persistence.warning(
                    "ingestPendingPayload failed to persist preset to session: \(error.localizedDescription)"
                )
            }
        }

        // Decompose the payload into a text body plus any rich parts
        // that ride alongside as MessagePart attachments.
        let (body, attachments) = payload.intoMessageBody()

        // The input goes through `sendMessage()` so loading checks,
        // auto-title, token accounting, and any post-generation tasks
        // all stay consistent with the compose bar. When no model is
        // loaded `sendMessage()` surfaces a configuration error and
        // bails out — but we keep the draft populated so the user can
        // pick a model and resend without retyping.
        inputText = body
        draftAttachments = attachments

        guard isModelLoaded else {
            Log.ui.info(
                "ingestPendingPayload deferring send — no model loaded; draft seeded"
            )
            return
        }

        await sendMessage()
    }

    @MainActor
    private func ingestByAppendingToDraft(_ payload: PendingPayload) {
        let (body, attachments) = payload.intoMessageBody()

        if inputText.isEmpty {
            inputText = body
        } else if !body.isEmpty {
            // Single newline between the existing draft and the appended
            // payload keeps multi-paragraph drafts readable without
            // collapsing the user's prior whitespace.
            inputText = inputText + "\n" + body
        }
        draftAttachments.append(contentsOf: attachments)
    }

    @MainActor
    private func ingestAsDraft(_ payload: PendingPayload) {
        let (body, attachments) = payload.intoMessageBody()
        inputText = body
        draftAttachments = attachments
    }

    @MainActor
    private func applyPreset(_ preset: IngestionPreset) {
        if let modelID = preset.modelID {
            if let match = availableModels.first(where: { $0.id.uuidString == modelID })
                ?? availableModels.first(where: { $0.name == modelID }) {
                selectedModel = match
            } else {
                Log.ui.warning(
                    "ingestPendingPayload preset.modelID=\(modelID, privacy: .public) not found in availableModels"
                )
            }
        }
        if let systemPrompt = preset.systemPrompt {
            self.systemPrompt = systemPrompt
        }
        if let temperature = preset.temperature {
            self.temperature = temperature
        }
        if let topP = preset.topP {
            self.topP = topP
        }
        if let repeatPenalty = preset.repeatPenalty {
            self.repeatPenalty = repeatPenalty
        }
    }
}

// MARK: - PendingPayload helpers

private extension PendingPayload {

    /// Short label used in logs so payload kind is visible without
    /// leaking the actual content.
    var kindLabel: String {
        switch self {
        case .text: return "text"
        case .url: return "url"
        case .image: return "image"
        case .file: return "file"
        }
    }

    /// Splits the payload into a text body for ``ChatViewModel/inputText``
    /// and any rich ``MessagePart`` attachments that should ride
    /// alongside the user message.
    func intoMessageBody() -> (body: String, attachments: [MessagePart]) {
        switch self {
        case .text(let string):
            return (string, [])
        case .url(let url):
            return (url.absoluteString, [])
        case .image(let data, let mimeType, let placeholderHash):
            return (
                "",
                [
                    .image(
                        data: data,
                        mimeType: mimeType,
                        placeholderHash: placeholderHash ?? ImagePlaceholderHash.generate(from: data)
                    ),
                ]
            )
        case .file(let url):
            // No file part exists in MessagePart yet (issue #441 will
            // add one), so render the path as the message body. This
            // is the same fallback used by the existing extension
            // recipes and keeps the shape stable for callers.
            return (url.path, [])
        }
    }
}
