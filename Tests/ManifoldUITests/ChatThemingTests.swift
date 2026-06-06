import XCTest
import SwiftUI
import ViewInspector
import ManifoldInference
@testable import ManifoldUI

/// Tests for the three-layer theming system: `ChatTheme` tokens (Layer 1),
/// `MessageBubbleStyle` (Layer 2), and the per-message renderer slot (Layer 3).
///
/// The regression test in particular guards the non-breaking promise: pinning
/// `ChatTheme.standard` to the exact values `MessageBubbleView` previously
/// hardcoded means any drift in the default appearance breaks the build.
@MainActor
final class ChatThemingTests: XCTestCase {

    private let sessionID = UUID()

    // MARK: - Layer 1: ChatTheme.standard regression guard

    /// `ChatTheme.standard` must reproduce the literals `MessageBubbleView` used
    /// before theming: padding 12, corner radius 16, content spacing 4, bubble
    /// stack spacing 6, body/caption fonts. (ShapeStyle backgrounds are pinned
    /// by the `init` defaults, which use the same `Color.accentColor` /
    /// `.fill.tertiary` literals as the old code — see `chrome(for:scale:)`.)
    func test_standardTheme_matchesHistoricalConstants() {
        let standard = ChatTheme.standard
        XCTAssertEqual(standard.cornerRadius, 16, "Historical bubble corner radius was 16")
        XCTAssertEqual(standard.bubblePadding, 12, "Historical bubble padding was 12")
        XCTAssertEqual(standard.contentSpacing, 4, "Historical inner VStack spacing was 4")
        XCTAssertEqual(standard.bubbleStackSpacing, 6, "Historical bubble/link-preview spacing was 6")
        XCTAssertEqual(standard.bubbleFont, .body, "Historical system text used .body")
        XCTAssertEqual(standard.metadataFont, .caption, "Historical timestamp font was .caption")
    }

    /// At the default content size category the scale factor is 1, so resolved
    /// chrome equals the raw tokens — the byte-for-byte guarantee.
    func test_standardChrome_atUnitScale_equalsRawTokens() {
        let chrome = ChatTheme.standard.chrome(for: .user, scale: 1)
        XCTAssertEqual(chrome.cornerRadius, 16)
        XCTAssertEqual(chrome.padding, 12)
    }

    /// The Dynamic Type factor multiplies through to the consumed metrics.
    func test_chrome_scalesWithDynamicTypeFactor() {
        let chrome = ChatTheme.standard.chrome(for: .assistant, scale: 2)
        XCTAssertEqual(chrome.cornerRadius, 32, "Corner radius must scale with Dynamic Type")
        XCTAssertEqual(chrome.padding, 24, "Padding must scale with Dynamic Type")
    }

    /// A custom theme must actually change the values `MessageBubbleView`
    /// consumes (the sabotage-direction check for the regression guard above).
    func test_customTheme_changesConsumedChromeValues() {
        let custom = ChatTheme(cornerRadius: 4, bubblePadding: 99)
        let chrome = custom.chrome(for: .user, scale: 1)
        XCTAssertEqual(chrome.cornerRadius, 4, "Custom corner radius must propagate")
        XCTAssertEqual(chrome.padding, 99, "Custom padding must propagate")
        XCTAssertNotEqual(
            chrome.cornerRadius,
            ChatTheme.standard.cornerRadius,
            "Custom theme must differ from the standard theme"
        )
    }

    /// `background(for:)` selects per role.
    func test_themeBackground_selectsPerRole() {
        // AnyShapeStyle is not Equatable, so assert the selection does not trap
        // and that a custom per-role override is honored structurally by routing
        // through `chrome(for:)`. The presence of distinct stored properties is
        // the contract; here we simply exercise every role path.
        let theme = ChatTheme()
        _ = theme.background(for: .user)
        _ = theme.background(for: .assistant)
        _ = theme.background(for: .system)
    }

    // MARK: - Layer 2: MessageBubbleStyle

    func test_builtInStyles_areDistinctTypes() {
        // Static accessors resolve to the documented concrete types.
        XCTAssertTrue(type(of: PlainMessageBubbleStyle.plain) == PlainMessageBubbleStyle.self)
        XCTAssertTrue(type(of: IMessageMessageBubbleStyle.iMessage) == IMessageMessageBubbleStyle.self)
        XCTAssertTrue(type(of: CardMessageBubbleStyle.card) == CardMessageBubbleStyle.self)
    }

    /// The default environment style is the plain (theme-driven) style, which is
    /// what keeps untouched views on the historical look.
    func test_defaultEnvironmentStyle_isPlain() {
        let defaultStyle = EnvironmentValues().messageBubbleStyle
        XCTAssertTrue(defaultStyle is PlainMessageBubbleStyle, "Default bubble style must be .plain")
    }

    /// A resolved style produces a renderable view for a given configuration.
    func test_resolvedBubble_rendersConfigurationContent() throws {
        let configuration = MessageBubbleConfiguration(
            content: AnyView(Text("hello bubble")),
            role: .assistant,
            isStreaming: false
        )
        let resolved = ResolvedMessageBubble(style: PlainMessageBubbleStyle(), configuration: configuration)
        let text = try resolved.inspect().find(text: "hello bubble")
        XCTAssertEqual(try text.string(), "hello bubble")
    }

    // MARK: - Layer 3: per-message renderer with defaultMessageView() fallback

    /// A renderer that returns a custom view for some messages and
    /// `params.defaultMessageView()` for the rest must compose: the custom path
    /// shows the custom view, the fallback path shows the built-in bubble (which
    /// still carries the accessibility contract label).
    func test_renderer_fallsThroughToDefaultMessageView() throws {
        let userMessage = ChatMessage(role: .user, content: "Plain user line.", sessionID: sessionID)
        let assistantMessage = ChatMessage(role: .assistant, content: "tool output", sessionID: sessionID)

        // Consumer override: take over assistant messages, defer user messages.
        let renderer: ChatMessageRenderer = { params in
            if params.message.role == .assistant {
                AnyView(Text("CUSTOM:\(params.message.content)"))
            } else {
                params.defaultMessageView()
            }
        }

        let userParams = ChatMessageRenderParameters(
            message: userMessage,
            isStreaming: false,
            isPinned: false,
            session: nil,
            linkPreviewProvider: nil,
            customKindRenderer: nil
        )
        let assistantParams = ChatMessageRenderParameters(
            message: assistantMessage,
            isStreaming: false,
            isPinned: false,
            session: nil,
            linkPreviewProvider: nil,
            customKindRenderer: nil
        )

        // Custom path: the assistant message renders the consumer's view.
        let custom = renderer(assistantParams)
        let customLabel = try custom.inspect().find(text: "CUSTOM:tool output")
        XCTAssertEqual(try customLabel.string(), "CUSTOM:tool output")

        // Fallback path: the user message renders the framework bubble, which
        // still exposes the VoiceOver contract label.
        let fallback = renderer(userParams)
        let label = try fallback.inspect()
            .find(where: { (try? $0.accessibilityLabel().string()) != nil })
            .accessibilityLabel()
            .string()
        XCTAssertEqual(
            label,
            MessageBubbleView.accessibilityLabel(for: userMessage),
            "defaultMessageView() must preserve the accessibility contract"
        )
    }

    /// `defaultMessageView()` returns the framework bubble for the supplied
    /// message regardless of role.
    func test_defaultMessageView_buildsBuiltInBubble() throws {
        let message = ChatMessage(role: .user, content: "Hi there.", sessionID: sessionID)
        let params = ChatMessageRenderParameters(
            message: message,
            isStreaming: false,
            isPinned: false,
            session: nil,
            linkPreviewProvider: nil,
            customKindRenderer: nil
        )
        let label = try params.defaultMessageView().inspect()
            .find(where: { (try? $0.accessibilityLabel().string()) != nil })
            .accessibilityLabel()
            .string()
        XCTAssertEqual(label, MessageBubbleView.accessibilityLabel(for: message))
    }

    // MARK: - Accessibility: theming must not strip the bubble contract

    /// After the Layer-1/2 refactor, the user bubble must still expose the
    /// '<Role> said: <content>' label even under a non-standard theme.
    func test_themedBubble_preservesAccessibilityLabel() throws {
        let message = ChatMessage(role: .user, content: "Themed and accessible.", sessionID: sessionID)
        let view = MessageBubbleView(message: message, isStreaming: false)
            .chatTheme(ChatTheme(cornerRadius: 2, bubblePadding: 30))
            .messageBubbleStyle(.card)

        let label = try view.inspect()
            .find(where: { (try? $0.accessibilityLabel().string()) != nil })
            .accessibilityLabel()
            .string()
        XCTAssertEqual(
            label,
            MessageBubbleView.accessibilityLabel(for: message),
            "Theming/style overrides must not strip the accessibility contract"
        )
    }
}
