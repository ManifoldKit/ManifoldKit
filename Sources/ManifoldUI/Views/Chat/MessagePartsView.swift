import SwiftUI
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

    @Environment(ChatViewModel.self) private var viewModel

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

    var body: some View {
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
            case .generatedImage:
                key = nextKey(for: "generatedImage", in: &ordinals)
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

        case .generatedImage(let payload):
            generatedImageView(payload)
        }
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
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.gray.opacity(0.15))
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.exclamationmark")
                    Text("Image unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 160)
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
            AssistantMarkdownView(content: text)
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
