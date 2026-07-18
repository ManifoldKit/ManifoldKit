import SwiftUI
import AVKit
import ManifoldRuntime
import ManifoldInference

/// Renders an array of ``MessagePart`` values within a message bubble.
///
/// Text parts are rendered inline (markdown for assistant, plain for user),
/// images are shown as thumbnails, thinking blocks show a collapsible
/// disclosure group (or a streaming label while generation is in progress),
/// and tool calls/results are paired by ``ToolCall/id`` and handed to
/// ``ToolInvocationView``.
struct MessagePartsView: View {
    let parts: [MessagePart]
    let role: MessageRole
    var isStreaming: Bool = false
    /// Identifier of the parent message. When non-nil, used to read whether
    /// the message's reasoning is actively streaming so ``ThinkingBlockView``
    /// can render an inline preview rather than the static "Thinking…" label.
    /// Optional so unit tests that exercise text/tool rendering can omit it.
    var messageID: UUID? = nil
    /// Source citations attached to this (assistant) message. When non-empty and
    /// the answer text contains resolvable inline `[n]` markers, text parts render
    /// via ``InlineCitationTextView`` so the markers become tappable superscripts.
    /// Empty (the default) keeps the historical plain-markdown rendering.
    var citations: [Citation] = []

    @Environment(ChatViewModel.self) private var viewModel
    @Environment(\.manifoldTheme) private var theme
    @Environment(\.chatMessagePartRenderer) private var partRenderer

    /// True while the parent message's reasoning block is still streaming —
    /// computed from the view-model's transient streaming-thinking set keyed
    /// by ``messageID``.
    private var isThinkingStreaming: Bool {
        guard let messageID else { return false }
        return viewModel.messageIDsWithStreamingThinking.contains(messageID)
    }

    /// Set of call IDs whose ``ToolResult`` already appears in `parts`. Used
    /// to decide whether a ``MessagePart/toolCall`` should render as
    /// pendingApproval/running (no result yet) or completed/failed (result
    /// landed).
    private var resolvedResultIDs: Set<String> {
        Set(parts.compactMap { part -> String? in
            if case .toolResult(let r) = part { return r.callId }
            return nil
        })
    }

    /// Set of call IDs currently waiting on user approval. Observed via the
    /// gate's `@Observable` `pending` array so toggling the approval sheet
    /// re-renders this view.
    private var pendingApprovalIDs: Set<String> {
        guard let gate = viewModel.toolApprovalGate else { return [] }
        return Set(gate.pending.map { $0.id })
    }

    /// In-flight image-generation progress for the hosting message, keyed by
    /// ``messageID``. `nil` once the placeholder message's `contentParts`
    /// gain the terminal `.generatedMedia` part — at that point the part
    /// itself is the source of truth and the progress card stops rendering
    /// (see ``ChatViewModel/handle(imageRuntimeEvent:)``, which only ever
    /// writes the completed part, never clears the progress dict entry).
    private var activeImageGenerationProgress: ImageGenerationProgress? {
        Self.activeProgress(in: viewModel.imageGenerationProgress, messageID: messageID)
    }

    /// See ``activeImageGenerationProgress``; video sibling.
    private var activeVideoGenerationProgress: VideoGenerationProgress? {
        Self.activeProgress(in: viewModel.videoGenerationProgress, messageID: messageID)
    }

    /// Terminal (`isComplete == true`) image-generation entry for the hosting
    /// message, when its placeholder never received a `.generatedMedia` part
    /// (`parts.isEmpty` — gated in `body`, same as ``activeImageGenerationProgress``).
    /// That combination only occurs for a **failed or cancelled** generation:
    /// a *successful* completion always writes the `.generatedMedia` part in
    /// the same handler call that flips `isComplete` (see
    /// `ChatViewModel.handle(imageRuntimeEvent:)`'s `.completed` case), so
    /// `parts` is never still empty once this entry exists. Before this
    /// tranche's failure-treatment addition, a failed/cancelled generation
    /// left this permanently blank — `ImageGenerationProgress.error` was
    /// written but never read.
    private var terminalImageFailure: ImageGenerationProgress? {
        Self.terminalFailure(in: viewModel.imageGenerationProgress, messageID: messageID)
    }

    /// See ``terminalImageFailure``; video sibling.
    private var terminalVideoFailure: VideoGenerationProgress? {
        Self.terminalFailure(in: viewModel.videoGenerationProgress, messageID: messageID)
    }

    /// Pure lookup extracted from ``activeImageGenerationProgress``/
    /// ``activeVideoGenerationProgress`` so the progress-card lifecycle
    /// (progress → settled → missing) is unit-testable without a live
    /// `ChatViewModel`/`@Environment` — see `MessagePartsGenerationProgressTests`.
    ///
    /// `nil` when there is no `messageID` to key on, no entry for that id, or
    /// the entry is already terminal (`isComplete == true` — completed,
    /// failed, and cancelled all settle through this same flag, per
    /// ``ChatViewModel/handle(imageRuntimeEvent:)``/`handle(videoRuntimeEvent:)`).
    static func activeProgress<Progress: GenerationProgressLifecycle>(
        in dict: [UUID: Progress],
        messageID: UUID?
    ) -> Progress? {
        guard let messageID else { return nil }
        guard let progress = dict[messageID], !progress.isComplete else { return nil }
        return progress
    }

    /// The inverse of ``activeProgress(in:messageID:)``: the terminal entry,
    /// once one exists. Callers must additionally gate on `parts.isEmpty`
    /// (as `body` does) — that's what distinguishes "the generation failed
    /// or was cancelled, so no `.generatedMedia` part ever arrived" from "the
    /// generation succeeded", since a successful completion's handler writes
    /// the part in the same step that sets `isComplete = true`.
    static func terminalFailure<Progress: GenerationProgressLifecycle>(
        in dict: [UUID: Progress],
        messageID: UUID?
    ) -> Progress? {
        guard let messageID else { return nil }
        guard let progress = dict[messageID], progress.isComplete else { return nil }
        return progress
    }

    var body: some View {
        // A generation in flight for this message has no `.generatedMedia`
        // part yet (the placeholder starts with empty `contentParts` — see
        // `ChatViewModel+ImageGeneration.swift`'s `.started` handler), so the
        // progress card renders ahead of (in practice, instead of) the empty
        // `ForEach` below. It disappears on its own once the terminal event
        // populates `parts` and this view re-renders.
        //
        // Gated on `parts.isEmpty`: this is not just an optimization — it's
        // load-bearing. `viewModel.imageGenerationProgress`/
        // `videoGenerationProgress` reads force `@Environment(ChatViewModel.self)`
        // to resolve. Every other `viewModel`-touching computed property on
        // this view (`isThinkingStreaming`, `pendingApprovalIDs`,
        // `resolvedResultIDs`) is reached only from the `.thinking`/`.toolCall`
        // branches of `partView(for:)`, so a plain text-only message never
        // touches the environment at all. Checking generation progress
        // unconditionally broke that invariant and crashed every
        // environment-less test that renders a non-empty, non-tool message
        // (e.g. `MessageBubbleViewLogicTests` constructs `MessageBubbleView`
        // — and transitively this view — with no `ChatViewModel` in scope).
        // Gating on `parts.isEmpty` restores the invariant and matches the
        // only case a progress entry can actually apply to.
        if parts.isEmpty {
            if let progress = activeImageGenerationProgress {
                let vm = viewModel
                GeneratedMediaProgressCardView(
                    prompt: progress.prompt,
                    progress: .image(step: progress.step, totalSteps: progress.totalSteps, previewImage: progress.previewImage),
                    onCancel: {
                        guard let messageID else { return }
                        Task { [weak vm] in await vm?.cancelImageGeneration(messageID: messageID) }
                    }
                )
            } else if let progress = activeVideoGenerationProgress {
                let vm = viewModel
                GeneratedMediaProgressCardView(
                    prompt: progress.prompt,
                    progress: .video(fractionComplete: progress.fractionComplete),
                    onCancel: {
                        guard let messageID else { return }
                        Task { [weak vm] in await vm?.cancelVideoGeneration(messageID: messageID) }
                    }
                )
            } else if let failure = terminalImageFailure {
                // §4A: "missing media never shows a broken frame: it states
                // its cause in the statusWarn voice" — this is the failed/
                // cancelled-generation case of that rule (as opposed to a
                // completed generation whose binary later went missing from
                // disk, handled by `missingImagePlaceholder`/`generatedVideoView`
                // below). Before this fix, a failed/cancelled generation left
                // this bubble permanently blank: `.failed`/`.cancelled` both
                // set `isComplete = true` on an empty-`contentParts` message
                // and never wrote a `.generatedMedia` part, so nothing here
                // ever rendered — `ImageGenerationProgress.error` was written
                // but never read.
                //
                // Test-coverage honesty: `terminalFailure(in:messageID:)` and
                // `failureCaption(kind:error:)` are both unit-tested directly
                // (`MessagePartsGenerationProgressTests`). This `else if`
                // branch itself is NOT render-tested — reaching it requires
                // `parts.isEmpty`, which forces this view's
                // `@Environment(ChatViewModel.self)` to resolve (same as
                // `activeImageGenerationProgress` above), and ViewInspector's
                // `.environment(_:)` does not satisfy that read during
                // inspection in this setup (confirmed: rendering
                // `MessagePartsView(parts: [], ...)` with `.environment(vm)`
                // reproduces the same crash `ChatHistoryView`'s equivalent
                // attempt did). Manually verified instead: temporarily
                // deleting this `else if`/`missingMediaPlaceholder` pairing
                // (for both image and video) leaves the full `ManifoldUITests`
                // suite green — confirming the gap is real.
                missingMediaPlaceholder(caption: Self.failureCaption(kind: "Image", error: failure.error))
            } else if let failure = terminalVideoFailure {
                missingMediaPlaceholder(caption: Self.failureCaption(kind: "Video", error: failure.error))
            }
        }

        // Identity must survive non-terminal insertions. The streaming
        // coordinator inserts `.thinking` *before* the first text part
        // (ChatGenerationCoordinator's `.thinkingStarted` handler), so an
        // offset-based id would renumber every following part on insert,
        // tearing down `AssistantMarkdownView`/`ToolInvocationView` state
        // instead of moving the views. `keyedParts` derives a stable id from
        // each part's kind + ordinal-within-kind (tools use their call id), so
        // inserting a thinking block ahead of text leaves the text parts'
        // identities untouched.
        ForEach(Self.keyedParts(parts), id: \.key) { keyed in
            partView(for: keyed.part)
        }
    }

    /// A `MessagePart` paired with a stable identity for `ForEach`.
    struct KeyedPart: Identifiable {
        let key: String
        let part: MessagePart
        var id: String { key }
    }

    /// Derives a stable, unique-within-message key for each part.
    ///
    /// - Tool calls/results key on their `ToolCall.id` / `ToolResult.callId`,
    ///   which are stable across the streaming lifecycle (the call id is
    ///   minted once and the result references it).
    /// - All other parts key on `"<kind>-<ordinal>"` where the ordinal counts
    ///   only occurrences of that same kind. Counting per-kind (rather than
    ///   across all parts) is what makes the scheme insertion-stable: inserting
    ///   a `.thinking` part ahead of existing `.text` parts does not change any
    ///   text part's ordinal, so `"text-0"` keeps pointing at the same view.
    ///
    /// Tool ids are prefixed (`tool:`) so they can never collide with a
    /// synthesized `"toolCall-<n>"`/`"toolResult-<n>"` fallback key.
    static func keyedParts(_ parts: [MessagePart]) -> [KeyedPart] {
        var ordinals: [String: Int] = [:]
        return parts.map { part in
            let key: String
            switch part {
            case .toolCall(let call):
                key = "tool:call:\(call.id)"
            case .toolResult(let result):
                key = "tool:result:\(result.callId)"
            case .text:
                key = nextKey(for: "text", in: &ordinals)
            case .thinking:
                key = nextKey(for: "thinking", in: &ordinals)
            case .image:
                key = nextKey(for: "image", in: &ordinals)
            case .audio:
                key = nextKey(for: "audio", in: &ordinals)
            case .generatedMedia(let media):
                key = nextKey(for: "generatedMedia:\(media.kind.rawValue)", in: &ordinals)
            }
            return KeyedPart(key: key, part: part)
        }
    }

    private static func nextKey(for kind: String, in ordinals: inout [String: Int]) -> String {
        let ordinal = ordinals[kind, default: 0]
        ordinals[kind] = ordinal + 1
        return "\(kind)-\(ordinal)"
    }

    @ViewBuilder
    private func partView(for part: MessagePart) -> some View {
        // A host-installed `.chatMessagePartRenderer(_:)` (Theming/
        // ChatMessagePartRenderer.swift) gets first refusal on every part;
        // its `defaultPartView()` escape hatch falls through to this view's
        // own per-kind switch below, mirroring `chatMessageRenderer`'s
        // whole-message LAST-WINS contract at the finer part granularity.
        if let partRenderer {
            partRenderer(
                ChatMessagePartRenderParameters(
                    part: part,
                    role: role,
                    isStreaming: isStreaming,
                    defaultView: { AnyView(defaultPartView(for: part)) }
                )
            )
        } else {
            defaultPartView(for: part)
        }
    }

    @ViewBuilder
    private func defaultPartView(for part: MessagePart) -> some View {
        switch part {
        case .text(let text):
            textView(text)

        case .image(let data, _, let placeholderHash):
            ImageAttachmentView(data: data, placeholderHash: placeholderHash)

        case .audio(let url, let duration, let waveform):
            AudioMessageView(url: url, duration: duration, waveform: waveform, role: role)

        case .thinking(let text, _):
            // While reasoning is in progress (`isThinkingStreaming`), the part's
            // text holds whatever has been flushed so far by the streaming
            // batcher and is rendered inline as a live preview. Once
            // `.finalizeThinking` clears the flag, the text becomes the
            // authoritative final block and the disclosure group switches to
            // its collapsed-by-default view.
            ThinkingBlockView(text: text, isThinkingStreaming: isThinkingStreaming)

        case .toolCall(let call):
            toolCallView(call)

        case .toolResult(let result):
            // Emit the result inline only when there is no paired `.toolCall`
            // above — that covers the case where the call part was trimmed out
            // of history. Otherwise we've already rendered the completed
            // disclosure on the toolCall branch and the matching result has
            // been folded into it.
            if !parts.contains(where: {
                if case .toolCall(let c) = $0 { return c.id == result.callId }
                return false
            }) {
                ToolInvocationView(
                    part: .toolResult(result),
                    state: result.errorKind == nil ? .completed : .failed
                )
            }

        case .generatedMedia(let media):
            generatedMediaView(media)
        }
    }

    @ViewBuilder
    private func generatedMediaView(_ media: GeneratedMediaPayload) -> some View {
        // Dispatch on the collapsed media kind. Image/video reuse the existing
        // per-modality helpers via the lossless legacy bridges; audio (and any
        // future modality without a dedicated view) degrades to a labelled
        // file-presence row.
        switch media.kind {
        case .image:
            if let payload = media.asImagePayload {
                generatedImageView(payload)
            } else {
                generatedMediaFallback(media)
            }
        case .video:
            if let payload = media.asVideoPayload {
                generatedVideoView(payload)
            } else {
                generatedMediaFallback(media)
            }
        case .audio:
            // Bridge the unified payload onto the existing Lane-1 audio player
            // (`AudioMessageView`, which renders `MessagePart.audio`). It only
            // needs url/duration/waveform/role, so reuse it rather than ship a
            // second player. The generated payload carries no waveform samples;
            // `AudioMessageView` degrades to a flat strip when `waveform` is nil.
            if FileManager.default.fileExists(atPath: media.url.path) {
                AudioMessageView(
                    url: media.url,
                    duration: media.durationSeconds ?? 0,
                    waveform: nil,
                    role: role
                )
            } else {
                generatedMediaFallback(media)
            }
        }
    }

    @ViewBuilder
    private func generatedMediaFallback(_ media: GeneratedMediaPayload) -> some View {
        // Hosts that want a richer renderer (e.g. an audio player) should read
        // `media.url` directly; the runtime ships no first-party player view.
        if FileManager.default.fileExists(atPath: media.url.path) {
            Text(media.prompt)
                .font(theme.type.caption)
                .foregroundStyle(theme.ink2)
        } else {
            missingMediaPlaceholder(caption: "Media file not found")
        }
    }

    @ViewBuilder
    private func generatedVideoView(_ payload: VideoMessagePayload) -> some View {
        // The video binary lives on disk; surface a simple file-exists check
        // so the UI degrades gracefully when the binary is missing (deleted,
        // container migration, restored backup without binary).
        if FileManager.default.fileExists(atPath: payload.videoURL.path) {
            // AVKit player replaces the historical prompt-text rendering
            // (docs/UI-REFRESH-2026.md §4A — "Video gets the AVKit player in
            // the same clipping"). Tap opens the *system* viewer via the
            // platform's own full-screen playback controls; no custom
            // lightbox is built here.
            VideoPlayer(player: AVPlayer(url: payload.videoURL))
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: theme.shape.md))
                .accessibilityLabel(Text(payload.prompt))
        } else {
            missingMediaPlaceholder(caption: "Video file not found")
        }
    }

    /// Caption for a failed/cancelled generation, reusing the same
    /// missing-media/statusWarn language as the "binary went missing from
    /// disk" captions below (`"Image unavailable"` / `"Video file not
    /// found"`) rather than inventing a new voice for this case. Pure/static
    /// so the copy is unit-testable without a view.
    static func failureCaption(kind: String, error: String?) -> String {
        if let error {
            return "\(kind) generation failed: \(error)"
        }
        return "\(kind) generation cancelled"
    }

    /// Shared missing-media treatment (§4A — "never shows a broken frame: it
    /// states its cause in the statusWarn voice"). Used by every
    /// generated-media modality (image/video/audio-fallback) once the
    /// referenced binary is gone from disk.
    private func missingMediaPlaceholder(caption: String) -> some View {
        RoundedRectangle(cornerRadius: theme.shape.sm)
            .fill(theme.statusWarnSoft)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(theme.statusWarnColor)
                    Text(caption)
                        .font(theme.type.caption)
                        .foregroundStyle(theme.statusWarnColor)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 160)
    }

    @ViewBuilder
    private func generatedImageView(_ payload: ImageMessagePayload) -> some View {
        // The image binary lives on disk (see ``ImageMessagePayload``); load
        // it lazily and gracefully handle the file-missing case (deleted,
        // container migration, restored backup without binary).
        if FileManager.default.fileExists(atPath: payload.imageURL.path) {
            #if os(iOS)
            if let uiImage = UIImage(contentsOfFile: payload.imageURL.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(Text(payload.prompt))
            } else {
                missingImagePlaceholder(payload: payload)
            }
            #elseif os(macOS)
            if let nsImage = NSImage(contentsOf: payload.imageURL) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(Text(payload.prompt))
            } else {
                missingImagePlaceholder(payload: payload)
            }
            #endif
        } else {
            missingImagePlaceholder(payload: payload)
        }
    }

    @ViewBuilder
    private func missingImagePlaceholder(payload: ImageMessagePayload) -> some View {
        // Recoverable: the persisted row points at a binary that is no longer
        // on disk. Surface a placeholder rather than crashing so history
        // remains browsable. Logged at warning level — never fatal.
        let _: Void = {
            Log.ui.warning(
                "Generated image binary missing on disk: \(payload.imageURL.path, privacy: .public)"
            )
        }()
        missingMediaPlaceholder(caption: "Image unavailable")
    }

    @ViewBuilder
    private func toolCallView(_ call: ToolCall) -> some View {
        if let matchingResult = parts.compactMap({ part -> ToolResult? in
            if case .toolResult(let r) = part, r.callId == call.id { return r }
            return nil
        }).first {
            // Completed: render a single completed/failed disclosure keyed
            // by the call's tool name, with the paired result folded in.
            let state: ToolInvocationView.State = matchingResult.errorKind == nil ? .completed : .failed
            ToolInvocationView(
                part: .toolCall(call),
                state: state,
                pairedResult: matchingResult
            )
        } else if pendingApprovalIDs.contains(call.id) {
            ToolInvocationView(
                part: .toolCall(call),
                state: .pendingApproval,
                onApprove: { [weak gate = viewModel.toolApprovalGate] in
                    gate?.resolve(callId: call.id, with: .approved)
                },
                onDeny: { [weak gate = viewModel.toolApprovalGate] reason in
                    gate?.resolve(callId: call.id, with: .denied(reason: reason))
                }
            )
        } else {
            ToolInvocationView(
                part: .toolCall(call),
                state: .running
            )
        }
    }

    @ViewBuilder
    private func textView(_ text: String) -> some View {
        if role == .assistant {
            // Take the inline-citation path only when the answer actually carries
            // a resolvable `[n]` marker; otherwise keep the existing markdown
            // renderer so fenced code / lists / streaming behave exactly as before.
            if !citations.isEmpty,
               InlineCitationRenderer.hasResolvableMarker(in: text, citations: citations) {
                InlineCitationTextView(content: text, citations: citations)
            } else {
                AssistantMarkdownView(content: text)
            }
        } else {
            Text(text)
                .font(.body)
                .foregroundStyle(role == .user ? .white : .primary)
                .textSelection(.enabled)
        }
    }

}

#Preview("Text Only") {
    MessagePartsView(parts: [.text("Hello world")], role: .assistant)
        .environment(ChatViewModel())
}

// MARK: - GenerationProgressLifecycle

/// Common shape ``ImageGenerationProgress``/``VideoGenerationProgress``
/// already carry — retroactively surfaced as a protocol (rather than editing
/// either type, which live in `ChatViewModel+ImageGeneration.swift`/
/// `ChatViewModel+VideoGeneration.swift`) purely so
/// ``MessagePartsView/activeProgress(in:messageID:)`` can be written once and
/// shared by both modalities.
protocol GenerationProgressLifecycle {
    /// `true` once a terminal event (completed / failed / cancelled) has been
    /// observed for this generation.
    var isComplete: Bool { get }
    /// Localized failure description, or `nil` for a successful completion
    /// or a user-initiated cancellation — see ``MessagePartsView/terminalFailure(in:messageID:)``
    /// for how a `nil` error is distinguished from "no terminal event yet".
    var error: String? { get }
}

extension ImageGenerationProgress: GenerationProgressLifecycle {}
extension VideoGenerationProgress: GenerationProgressLifecycle {}
