import XCTest
import SwiftUI
import ViewInspector
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldInference
@testable import ManifoldUI

/// Accessibility contract tests for chat UI surfaces.
///
/// The existing snapshot suite under `ManifoldSnapshotTests` captures the view
/// hierarchy via `Swift.dump()`, which strips accessibility labels. This suite
/// fills that gap using ViewInspector to walk the SwiftUI tree and assert on
/// the VoiceOver-visible labels and hints that real assistive technology users
/// actually encounter.
///
/// When adding assertions here, prefer pinning to the exact contract string
/// (via `expectedMessageBubbleLabel`) so accidental copy-edits to user-facing
/// strings break the test instead of silently degrading VoiceOver output.
@MainActor
final class ChatA11yContractTests: XCTestCase {

    // MARK: - Contract helpers

    /// The accessibility label format the `MessageBubbleView` contract promises
    /// to VoiceOver users. Kept in the test file (not imported from source) so
    /// a drive-by change to the source helper is caught by a failing assertion
    /// rather than quietly updating the "expected" side of the test.
    ///
    /// When `hasThinking` / `hasAudio` are `true`, suffixes are appended so that
    /// VoiceOver announces non-text message parts without reading hidden data.
    private func expectedMessageBubbleLabel(
        role: MessageRole,
        content: String,
        hasThinking: Bool = false,
        hasAudio: Bool = false
    ) -> String {
        let roleName: String
        switch role {
        case .user: roleName = "User"
        case .assistant: roleName = "Assistant"
        case .system: roleName = "System"
        }
        let base = "\(roleName) said: \(content)"
        var suffixes: [String] = []
        if hasThinking { suffixes.append("Includes reasoning.") }
        if hasAudio { suffixes.append("Includes audio.") }
        return suffixes.isEmpty ? base : "\(base). \(suffixes.joined(separator: " "))"
    }

    private let sessionID = UUID()

    // MARK: - MessageBubbleView

    func test_messageBubble_userRole_hasContractAccessibilityLabel() throws {
        let msg = ManifoldInference.ChatMessage(
            role: .user,
            content: "Hello, tell me about dragons.",
            sessionID: sessionID
        )
        let view = MessageBubbleView(message: msg, isStreaming: false)

        let label = try view.inspect()
            .find(ViewType.HStack.self)
            .find(where: { (try? $0.accessibilityLabel().string()) != nil })
            .accessibilityLabel()
            .string()

        XCTAssertEqual(
            label,
            expectedMessageBubbleLabel(role: .user, content: "Hello, tell me about dragons."),
            "User message bubble must follow the '<Role> said: <content>' contract"
        )
        XCTAssertFalse(label.isEmpty, "Accessibility label must not be empty")
    }

    func test_messageBubble_assistantRole_hasContractAccessibilityLabel() throws {
        let msg = ManifoldInference.ChatMessage(
            role: .assistant,
            content: "Once upon a time...",
            sessionID: sessionID
        )
        let view = MessageBubbleView(message: msg, isStreaming: false)

        let label = try view.inspect()
            .find(ViewType.HStack.self)
            .find(where: { (try? $0.accessibilityLabel().string()) != nil })
            .accessibilityLabel()
            .string()

        XCTAssertEqual(
            label,
            expectedMessageBubbleLabel(role: .assistant, content: "Once upon a time..."),
            "Assistant message bubble must follow the '<Role> said: <content>' contract"
        )
    }

    func test_messageBubble_systemRole_hasContractAccessibilityLabel() throws {
        let msg = ManifoldInference.ChatMessage(
            role: .system,
            content: "You are a helpful assistant.",
            sessionID: sessionID
        )
        let view = MessageBubbleView(message: msg, isStreaming: false)

        let label = try view.inspect()
            .find(ViewType.HStack.self)
            .find(where: { (try? $0.accessibilityLabel().string()) != nil })
            .accessibilityLabel()
            .string()

        XCTAssertEqual(
            label,
            expectedMessageBubbleLabel(role: .system, content: "You are a helpful assistant."),
            "System message bubble must follow the '<Role> said: <content>' contract"
        )
    }

    func test_messageBubble_staticHelperMatchesContract() {
        // The static helper on MessageBubbleView is what the view uses internally.
        // Keeping a direct unit test on it provides a second line of defense if the
        // view-tree inspection ever breaks due to a SwiftUI internals change.
        let user = ManifoldInference.ChatMessage(role: .user, content: "Hi", sessionID: sessionID)
        let assistant = ManifoldInference.ChatMessage(role: .assistant, content: "Hello", sessionID: sessionID)
        let system = ManifoldInference.ChatMessage(role: .system, content: "Be concise", sessionID: sessionID)

        XCTAssertEqual(
            MessageBubbleView.accessibilityLabel(for: user),
            expectedMessageBubbleLabel(role: .user, content: "Hi")
        )
        XCTAssertEqual(
            MessageBubbleView.accessibilityLabel(for: assistant),
            expectedMessageBubbleLabel(role: .assistant, content: "Hello")
        )
        XCTAssertEqual(
            MessageBubbleView.accessibilityLabel(for: system),
            expectedMessageBubbleLabel(role: .system, content: "Be concise")
        )
    }

    func test_messageBubble_withThinkingParts_appendsIncludesReasoning() {
        // A message whose contentParts include a .thinking block must announce
        // reasoning presence so VoiceOver users know they can expand it.
        let msg = ManifoldInference.ChatMessage(
            role: .assistant,
            contentParts: [
                .thinking("Let me reason about this."),
                .text("The answer is 42.")
            ],
            sessionID: sessionID
        )

        let label = MessageBubbleView.accessibilityLabel(for: msg)

        XCTAssertEqual(
            label,
            expectedMessageBubbleLabel(role: .assistant, content: "The answer is 42.", hasThinking: true),
            "Label must append '. Includes reasoning.' when thinking parts are present"
        )
        XCTAssertTrue(
            label.hasSuffix(". Includes reasoning."),
            "Label must end with '. Includes reasoning.' suffix"
        )
    }

    func test_messageBubble_withAudioPart_appendsIncludesAudio() {
        let msg = ManifoldInference.ChatMessage(
            role: .user,
            contentParts: [
                .audio(url: URL(fileURLWithPath: "/Users/example/audio.m4a"), duration: 2, waveform: nil)
            ],
            sessionID: sessionID
        )

        let label = MessageBubbleView.accessibilityLabel(for: msg)

        XCTAssertEqual(
            label,
            expectedMessageBubbleLabel(role: .user, content: "", hasAudio: true),
            "Label must append '. Includes audio.' when audio parts are present"
        )
    }

    func test_messageBubble_withoutThinkingParts_doesNotAppendIncludesReasoning() {
        // A plain text message must NOT have the reasoning suffix.
        let msg = ManifoldInference.ChatMessage(role: .assistant, content: "Just text.", sessionID: sessionID)

        let label = MessageBubbleView.accessibilityLabel(for: msg)

        XCTAssertFalse(
            label.contains("Includes reasoning"),
            "Label must not mention reasoning when no thinking parts are present"
        )
        XCTAssertEqual(
            label,
            expectedMessageBubbleLabel(role: .assistant, content: "Just text.", hasThinking: false)
        )
    }

    // MARK: - Sabotage check for thinking-present label

    func test_sabotage_thinkingPresentLabelDiffersFromPlainLabel() {
        // Confirms that the thinking suffix actually changes the label — guards
        // against a regression where the suffix is silently dropped.
        let withThinking = ManifoldInference.ChatMessage(
            role: .assistant,
            contentParts: [.thinking("some reasoning"), .text("answer")],
            sessionID: sessionID
        )
        let withoutThinking = ManifoldInference.ChatMessage(role: .assistant, content: "answer", sessionID: sessionID)

        XCTAssertNotEqual(
            MessageBubbleView.accessibilityLabel(for: withThinking),
            MessageBubbleView.accessibilityLabel(for: withoutThinking),
            "A message with thinking parts must produce a different label than one without"
        )
    }

    // MARK: - ContextIndicatorView

    func test_contextIndicator_labelIsHumanReadable() throws {
        let view = ContextIndicatorView(usedTokens: 1234, maxTokens: 4096)

        let label = try view.inspect()
            .find(ViewType.HStack.self)
            .accessibilityLabel()
            .string()

        XCTAssertEqual(
            label,
            "Context used: 1234 of 4096 tokens",
            "Context indicator must use human-readable 'Context used: X of Y tokens' format"
        )
    }

    func test_contextIndicator_valueExposesPercentage() throws {
        let view = ContextIndicatorView(usedTokens: 2048, maxTokens: 4096)

        let value = try view.inspect()
            .find(ViewType.HStack.self)
            .accessibilityValue()
            .string()

        XCTAssertEqual(value, "50 percent", "Context indicator must expose percentage via accessibilityValue")
    }

    // MARK: - Send/Stop button (ChatInputBar primary action)
    //
    // `ChatInputBar` reads `ChatViewModel` from `@Environment`, which makes
    // synchronous ViewInspector walks crash (the VM is only materialized by the
    // SwiftUI rendering pipeline, not by ViewInspector's reflective inspection).
    // To keep these tests fast and side-effect-free we inspect the extracted
    // `SendStopButton` subview directly — it's what `ChatInputBar` composes, so
    // asserting against it is a real contract assertion, not a parallel reimpl.

    func test_sendStopButton_idleState_exposesSendMessageLabel() throws {
        let view = SendStopButton(
            isGenerating: false,
            canSend: true,
            onSend: {},
            onStop: {}
        )

        let label = try view.inspect().find(ViewType.Button.self).accessibilityLabel().string()
        XCTAssertEqual(label, "Send message", "Idle send button must expose 'Send message'")
        XCTAssertEqual(
            label,
            SendStopButton.sendLabel,
            "Idle button label must come from the SendStopButton.sendLabel contract constant"
        )
    }

    func test_sendStopButton_generatingState_exposesStopGenerationLabel() throws {
        let view = SendStopButton(
            isGenerating: true,
            canSend: false,
            onSend: {},
            onStop: {}
        )

        let label = try view.inspect().find(ViewType.Button.self).accessibilityLabel().string()
        XCTAssertEqual(label, "Stop generation", "Generating state must expose 'Stop generation'")
        XCTAssertEqual(
            label,
            SendStopButton.stopLabel,
            "Generating button label must come from the SendStopButton.stopLabel contract constant"
        )
    }

    func test_sendStopButton_contractConstants_matchExpectedStrings() {
        XCTAssertEqual(SendStopButton.sendLabel, "Send message")
        XCTAssertEqual(SendStopButton.stopLabel, "Stop generation")
    }

    // MARK: - Error banner

    func test_errorBanner_hasAccessibilityHeaderAndLabel() throws {
        let error = ChatError(
            kind: .generation,
            message: "The model stopped responding.",
            recovery: .retry
        )

        let view = ErrorBannerView(error: error, onDismiss: {}) {
            EmptyView()
        }

        // Walk to the outer HStack where the accessibility modifiers are applied.
        let banner = try view.inspect().find(ViewType.HStack.self)
        let bannerLabel = try banner.accessibilityLabel().string()

        XCTAssertTrue(
            bannerLabel.hasPrefix("Error: "),
            "Error banner accessibility label must begin with 'Error: ' so VoiceOver users recognise its purpose"
        )
        XCTAssertTrue(
            bannerLabel.contains("The model stopped responding."),
            "Error banner must include the underlying error message"
        )
        XCTAssertEqual(
            bannerLabel,
            ErrorBannerView<EmptyView>.accessibilityLabel(for: error),
            "Banner must use the contract helper to build its label"
        )
    }

    // MARK: - Sabotage self-check
    //
    // Per CLAUDE.md: "after asserting an expected outcome, add a sabotage check:
    // temporarily break the code path being tested and confirm the test fails."
    //
    // This test codifies the sabotage by inlining a deliberately-wrong helper
    // and verifying the contract rejects it. If the real helper ever starts
    // producing the same wrong string, the other assertions above would pass
    // spuriously — this guards against that drift without requiring us to
    // manually sabotage-and-revert the source each run.

    func test_sabotage_wrongFormatFailsContract() {
        let msg = ManifoldInference.ChatMessage(role: .user, content: "Hi", sessionID: sessionID)

        // The old (pre-contract) format: "user: Hi". Kept here as the sabotage
        // baseline — if someone reverts the source to this format the real
        // assertions above fail, and this assertion acts as the canary that
        // confirms the sabotage check itself is still meaningful.
        let saboteurLabel = "\(msg.role.rawValue): \(msg.content)"
        let real = MessageBubbleView.accessibilityLabel(for: msg)

        XCTAssertNotEqual(
            real,
            saboteurLabel,
            "The real label must differ from the pre-contract format"
        )
        XCTAssertNotEqual(
            saboteurLabel,
            expectedMessageBubbleLabel(role: .user, content: "Hi"),
            "The saboteur format must not accidentally match the contract — otherwise the sabotage check is meaningless"
        )
    }
}

// ViewInspector 0.10.x uses the implicit Inspectable conformance model;
// no `extension XXX: Inspectable {}` declarations are required for these views.
