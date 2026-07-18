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

    @Environment(\.toolInvocationStyle) private var style

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
            resolvedView(
                lifecycleState: .awaitingApproval,
                callToolName: call.toolName,
                arguments: call.arguments,
                result: nil
            )
        case (.toolCall(let call), .running):
            resolvedView(
                lifecycleState: .running,
                callToolName: call.toolName,
                arguments: call.arguments,
                result: nil
            )
        case (.toolCall(let call), .completed):
            // Completed pair: fold the paired result (if any) into the same
            // disclosure labeled with the call's tool name.
            resolvedView(
                lifecycleState: .completed,
                callToolName: call.toolName,
                arguments: call.arguments,
                result: pairedResult
            )
        case (.toolCall(let call), .failed):
            resolvedView(
                lifecycleState: .failed,
                callToolName: call.toolName,
                arguments: call.arguments,
                result: pairedResult
            )
        case (.toolResult(let result), .completed):
            // No paired `.toolCall` — the call part was trimmed out of
            // history. `callToolName` is `nil` here (there is no call to name),
            // distinct from a call literally named `"tool"`.
            resolvedView(lifecycleState: .completed, callToolName: nil, arguments: nil, result: result)
        case (.toolResult(let result), .failed):
            resolvedView(lifecycleState: .failed, callToolName: nil, arguments: nil, result: result)
        default:
            // Mixed-content bubbles should not crash if a caller supplies a
            // text / image / thinking part by accident. Silently skip.
            EmptyView()
        }
    }

    // MARK: - Style dispatch

    /// - Parameter callToolName: The real `ToolCall.toolName`, or `nil` when
    ///   there is no paired call (a `.toolResult`-only render). Kept as a true
    ///   optional — rather than a `"tool"` placeholder string — so a tool
    ///   genuinely named `"tool"` still gets its re-authentication CTA (see
    ///   ``ToolErrorPresentation/init(errorKind:toolName:)``, which treats a
    ///   non-nil, non-empty `toolName` as a real call to derive a service name
    ///   from). A string sentinel would have collapsed that case into "no CTA".
    private func resolvedView(
        lifecycleState: ToolInvocationLifecycleState,
        callToolName: String?,
        arguments: String?,
        result: ToolResult?
    ) -> some View {
        let errorPresentation: ToolErrorPresentation? = {
            guard lifecycleState == .failed else { return nil }
            return ToolErrorPresentation(errorKind: result?.errorKind, toolName: callToolName)
        }()
        return ResolvedToolInvocation(
            style: style,
            configuration: ToolInvocationConfiguration(
                state: lifecycleState,
                toolName: callToolName ?? "tool",
                arguments: arguments,
                resultContent: result?.content,
                errorPresentation: errorPresentation,
                onApprove: onApprove,
                onDeny: onDeny,
                onReauthenticate: onReauthenticate
            )
        )
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
