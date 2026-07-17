import SwiftUI
import ManifoldInference

/// Renders a single `MessagePart.toolCall` or `MessagePart.toolResult`
/// within a message bubble.
///
/// Four visual states are branched off the `MessagePart` case and the presence
/// of a completed `ToolResult`:
/// - ``State/pendingApproval`` — tool-name chip + argument preview + Approve/Deny.
/// - ``State/running`` — spinner while the tool executes.
/// - ``State/completed`` — collapsed disclosure showing args + content.
/// - ``State/failed`` — collapsed disclosure with the `ToolResult.ErrorKind`
///   chip.
///
/// This view is intentionally "dumb" — it takes the part and optional
/// callback closures, never reaches into `@Environment` for a view model.
/// The approval-queue wiring lives in ``UIToolApprovalGate`` and the host's
/// ``ChatViewModel``; this view is just the visual shell they drive.
///
/// ## Accessibility identifiers
///
/// - Container: `tool-invocation-<state>-<toolName>` where state is one of
///   `pending`, `running`, `completed`, `failed`.
/// - Approve button: `approval-approve-button`.
/// - Deny button: `approval-deny-button`.
public struct ToolInvocationView: View {

    @Environment(\.manifoldTheme) private var theme

    /// Visual state the view should render.
    ///
    /// The caller decides which state applies based on whether the part is a
    /// `MessagePart.toolCall` that still needs approval, is currently
    /// running, or already has a matching `MessagePart.toolResult` paired
    /// with it. Keeping the state explicit in the API makes the view unit
    /// testable without having to fabricate the whole messages array.
    public enum State: Sendable, Equatable {
        case pendingApproval
        case running
        case completed
        case failed
    }

    /// The part being rendered. Must be either `MessagePart.toolCall` or
    /// `MessagePart.toolResult` — any other case renders as an empty view
    /// so mixed-content bubbles degrade gracefully.
    public let part: MessagePart

    /// Optional paired `ToolResult` for ``State/completed`` / ``State/failed``
    /// renders driven off a `MessagePart.toolCall` primary part. Supplying
    /// the result alongside the call lets the disclosure group label with
    /// the tool name while still surfacing the result body underneath.
    public let pairedResult: ToolResult?

    /// The visual state to render.
    public let state: State

    /// Invoked when the user taps Approve on a pending approval.
    /// Only read when ``state`` is ``State/pendingApproval``.
    public var onApprove: (() -> Void)?

    /// Invoked when the user taps Deny on a pending approval. The optional
    /// `String` carries an opt-in reason surfaced back to the model via the
    /// synthesised `ToolResult.ErrorKind.permissionDenied`.
    /// Only read when ``state`` is ``State/pendingApproval``.
    public var onDeny: ((String?) -> Void)?

    /// Invoked when the user taps a permission-denied re-authentication CTA.
    /// Only shown for failed results whose presentation metadata includes a CTA.
    public var onReauthenticate: ((ToolErrorPresentation.ReauthenticationCTA) -> Void)?

    public init(
        part: MessagePart,
        state: State,
        pairedResult: ToolResult? = nil,
        onApprove: (() -> Void)? = nil,
        onDeny: ((String?) -> Void)? = nil,
        onReauthenticate: ((ToolErrorPresentation.ReauthenticationCTA) -> Void)? = nil
    ) {
        self.part = part
        self.state = state
        self.pairedResult = pairedResult
        self.onApprove = onApprove
        self.onDeny = onDeny
        self.onReauthenticate = onReauthenticate
    }

    public var body: some View {
        switch (part, state) {
        case (.toolCall(let call), .pendingApproval):
            pendingView(call: call)
        case (.toolCall(let call), .running):
            runningView(call: call)
        case (.toolCall(let call), .completed):
            // Completed pair: fold the paired result (if any) into the same
            // disclosure labeled with the call's tool name.
            completedCallView(call: call, result: pairedResult)
        case (.toolCall(let call), .failed):
            failedView(call: call, result: pairedResult)
        case (.toolResult(let result), .completed):
            completedCallView(call: nil, result: result)
        case (.toolResult(let result), .failed):
            failedView(call: nil, result: result)
        default:
            // Mixed-content bubbles should not crash if a caller supplies a
            // text / image / thinking part by accident. Silently skip.
            EmptyView()
        }
    }

    // MARK: - States

    private func pendingView(call: ToolCall) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(.secondary)
                Text(call.toolName)
                    .font(.caption.monospaced())
                    .fontWeight(.semibold)
            }
            Text(argumentPreview(call.arguments))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button("Deny") { onDeny?(nil) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("approval-deny-button")
                Button("Approve") { onApprove?() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("approval-approve-button")
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tool-invocation-pending-\(call.toolName)")
    }

    private func runningView(call: ToolCall) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text("calling ")
                .font(.caption)
                .foregroundStyle(.secondary)
            + Text(call.toolName)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            + Text("…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .accessibilityIdentifier("tool-invocation-running-\(call.toolName)")
    }

    private func completedCallView(call: ToolCall?, result: ToolResult?) -> some View {
        let toolName = call?.toolName ?? "tool"
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let call {
                    Text("Arguments")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(call.arguments)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if let result {
                    Text("Result")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(result.content)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(theme.statusOKColor)
                Text(toolName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("tool-invocation-completed-\(toolName)")
    }

    private func failedView(call: ToolCall?, result: ToolResult?) -> some View {
        let toolName = call?.toolName ?? "tool"
        let presentation = ToolErrorPresentation(errorKind: result?.errorKind, toolName: call?.toolName)
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let call {
                    Text("Arguments")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(call.arguments)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if let result {
                    Text("Error")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(presentation.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(result.content)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if let cta = presentation.reauthenticationCTA {
                    Button(cta.message) {
                        onReauthenticate?(cta)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("tool-error-reauth-button")
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(toolName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(presentation.summary)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityIdentifier("tool-invocation-failed-\(toolName)")
    }

    // MARK: - Helpers

    private func argumentPreview(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 80 { return trimmed }
        return String(trimmed.prefix(80)) + "…"
    }
}

// MARK: - Previews

#Preview("Pending") {
    ToolInvocationView(
        part: .toolCall(ToolCall(
            id: "1",
            toolName: "sample_repo_search",
            arguments: #"{"query":"readme","limit":5}"#
        )),
        state: .pendingApproval,
        onApprove: {},
        onDeny: { _ in }
    )
    .padding()
}

#Preview("Running") {
    ToolInvocationView(
        part: .toolCall(ToolCall(
            id: "2",
            toolName: "sample_repo_search",
            arguments: #"{"query":"readme"}"#
        )),
        state: .running
    )
    .padding()
}

#Preview("Completed") {
    ToolInvocationView(
        part: .toolResult(ToolResult(
            callId: "3",
            content: #"[{"path":"README.md","snippet":"Sample Workspace"}]"#
        )),
        state: .completed
    )
    .padding()
}

#Preview("Failed") {
    ToolInvocationView(
        part: .toolResult(ToolResult(
            callId: "4",
            content: "User denied execution.",
            errorKind: .permissionDenied
        )),
        state: .failed
    )
    .padding()
}
