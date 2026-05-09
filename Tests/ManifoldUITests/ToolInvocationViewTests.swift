import XCTest
import SwiftUI
import ViewInspector
import ManifoldInference
@testable import ManifoldUI

/// Visual-contract tests for ``ToolInvocationView``. Each test renders the
/// view against a fixture ``MessagePart`` and asserts the accessibility
/// identifier that drives the XCUITest selectors. The view is dumb — no
/// ``ChatViewModel`` environment required.
@MainActor
final class ToolInvocationViewTests: XCTestCase {

    // MARK: - Fixtures

    private func pendingCall(
        id: String = "pending-1",
        name: String = "sample_repo_search"
    ) -> MessagePart {
        .toolCall(ToolCall(
            id: id,
            toolName: name,
            arguments: #"{"query":"readme","limit":5}"#
        ))
    }

    private func runningCall(
        id: String = "running-1",
        name: String = "sample_repo_search"
    ) -> MessagePart {
        .toolCall(ToolCall(id: id, toolName: name, arguments: #"{"query":"x"}"#))
    }

    private func completedResult(
        callId: String = "done-1"
    ) -> MessagePart {
        .toolResult(ToolResult(
            callId: callId,
            content: #"[{"path":"README.md","snippet":"Sample"}]"#
        ))
    }

    private func failedResult(
        callId: String = "failed-1"
    ) -> MessagePart {
        .toolResult(ToolResult(
            callId: callId,
            content: "denied",
            errorKind: .permissionDenied
        ))
    }

    // MARK: - Tests

    func test_pendingApproval_exposesApproveAndDenyIdentifiers() throws {
        let view = ToolInvocationView(
            part: pendingCall(),
            state: .pendingApproval,
            onApprove: {},
            onDeny: { _ in }
        )
        _ = try view.inspect().find(viewWithAccessibilityIdentifier: "tool-invocation-pending-sample_repo_search")
        _ = try view.inspect().find(viewWithAccessibilityIdentifier: "approval-approve-button")
        _ = try view.inspect().find(viewWithAccessibilityIdentifier: "approval-deny-button")
    }

    func test_running_exposesContainerIdentifier() throws {
        let view = ToolInvocationView(part: runningCall(), state: .running)
        _ = try view.inspect().find(viewWithAccessibilityIdentifier: "tool-invocation-running-sample_repo_search")
    }

    func test_completed_rendersResultContentUnderDisclosureIdentifier() throws {
        // Result-only render path (e.g. trimmed history): identifier falls
        // back to the literal "tool" segment since the original call is gone.
        let view = ToolInvocationView(part: completedResult(), state: .completed)
        _ = try view.inspect().find(viewWithAccessibilityIdentifier: "tool-invocation-completed-tool")
    }

    func test_completed_withPairedCall_usesToolNameInIdentifier() throws {
        let call = ToolCall(id: "c1", toolName: "sample_repo_search", arguments: "{}")
        let result = ToolResult(callId: "c1", content: "[]")
        let view = ToolInvocationView(
            part: .toolCall(call),
            state: .completed,
            pairedResult: result
        )
        _ = try view.inspect().find(viewWithAccessibilityIdentifier: "tool-invocation-completed-sample_repo_search")
    }

    func test_failed_rendersErrorKindIdentifier() throws {
        let view = ToolInvocationView(part: failedResult(), state: .failed)
        _ = try view.inspect().find(viewWithAccessibilityIdentifier: "tool-invocation-failed-tool")
    }

    func test_errorPresentation_exposesLocalizedSummariesForEveryKind() {
        for kind in ToolResult.ErrorKind.allCases {
            let presentation = ToolErrorPresentation(errorKind: kind, toolName: "docs__search")
            XCTAssertEqual(presentation.summary, kind.localizedDescription)
        }
    }

    func test_permissionDeniedPresentation_exposesReauthenticationCTA() throws {
        let presentation = ToolErrorPresentation(errorKind: .permissionDenied, toolName: "notion__search")

        let cta = try XCTUnwrap(presentation.reauthenticationCTA)
        XCTAssertEqual(cta.serviceName, "Notion")
        XCTAssertEqual(cta.label, "Tap to sign in")
        XCTAssertEqual(cta.message, "Notion isn't connected. Tap to sign in.")
        XCTAssertEqual(cta.actionID, "mcp.reauthenticate.notion")
    }

    func test_nonPermissionDeniedPresentation_hasNoReauthenticationCTA() {
        let presentation = ToolErrorPresentation(errorKind: .timeout, toolName: "notion__search")

        XCTAssertNil(presentation.reauthenticationCTA)
    }

    func test_failedPermissionDenied_withPairedCall_rendersReauthenticationCTA() throws {
        let call = ToolCall(id: "c1", toolName: "notion__search", arguments: "{}")
        let result = ToolResult(callId: "c1", content: "authorization required", errorKind: .permissionDenied)
        var tappedCTA: ToolErrorPresentation.ReauthenticationCTA?
        let view = ToolInvocationView(
            part: .toolCall(call),
            state: .failed,
            pairedResult: result,
            onReauthenticate: { tappedCTA = $0 }
        )

        _ = try view.inspect().find(viewWithAccessibilityIdentifier: "tool-error-reauth-button")
        let button = try view.inspect().find(button: "Notion isn't connected. Tap to sign in.")
        try button.tap()

        XCTAssertEqual(tappedCTA?.actionID, "mcp.reauthenticate.notion")
    }

    func test_approveButton_invokesOnApproveClosure() throws {
        var approved = false
        let view = ToolInvocationView(
            part: pendingCall(),
            state: .pendingApproval,
            onApprove: { approved = true },
            onDeny: { _ in }
        )
        let button = try view.inspect().find(button: "Approve")
        try button.tap()
        XCTAssertTrue(approved, "Tapping Approve should invoke onApprove()")
    }

    func test_denyButton_invokesOnDenyWithNoReason() throws {
        var denyReason: String?? = nil
        let view = ToolInvocationView(
            part: pendingCall(),
            state: .pendingApproval,
            onApprove: {},
            onDeny: { reason in denyReason = .some(reason) }
        )
        let button = try view.inspect().find(button: "Deny")
        try button.tap()
        // onDeny called with nil reason from the inline Deny button.
        XCTAssertNotNil(denyReason, "Deny button should invoke onDeny()")
        XCTAssertNil(denyReason ?? "non-nil sentinel", "Inline Deny forwards nil reason")
    }
}
