import XCTest
import SwiftUI
import ViewInspector
@testable import ManifoldUI
import ManifoldInference

/// Pins the framework's **current default appearance** — the 2026 UI refresh
/// (Unit 2 §L5, issue #2307) flipped the built-in look, so this file now
/// anchors the *new* defaults. Through Unit 1 this suite pinned the
/// pre-refresh appearance byte-for-byte; those exact assertions now live in
/// ``ClassicAppearanceCharacterizationTests``, which pins `.classic` to the
/// same historical values this file used to pin `.standard` to — the
/// pre-refresh look must remain reproducible forever, just no longer as the
/// default.
///
/// Covers the `ManifoldUI`-module anchors only (`ChatTheme`, `ToolInvocationView`,
/// `MemoryIndicatorView`, `ContextIndicatorView`). The `ManifoldUIModelManagement`
/// anchors (`ModelPicker`, `DownloadableModelRow`) live in a companion
/// `DefaultAppearanceCharacterizationTests.swift` in `Tests/ManifoldUIModelManagementTests`.
///
/// ## What's covered, and why some anchors aren't runtime-asserted here
///
/// Every value pinned below is either (a) read directly off a public/internal
/// API (`ChatTheme`'s stored properties), or (b) extracted from the actual
/// rendered view tree via ViewInspector's `foregroundStyleShapeStyle(Color.self)`
/// / `fillShapeStyle(Color.self)` — both only resolve a modifier whose
/// `ShapeStyle` argument is a plain `Color`.
///
/// The flip changed which built-in style ``ToolInvocationView``/
/// ``ThinkingBlockView``/``SessionRowView`` dispatch to by default
/// (``CardToolInvocationStyle``/``ShimmerThinkingBlockStyle``/
/// ``QuietSessionRowStyle``, all reading `ManifoldTheme`'s `AnyShapeStyle`-typed
/// tokens like `statusOK`/`statusWarn`), which widens the ViewInspector gap
/// already documented pre-flip: `CardToolInvocationStyle`'s icons use
/// `theme.statusOK`/`theme.statusWarn` (not the `Color`-typed
/// `statusOKColor`/`statusWarnColor` siblings `PlainToolInvocationStyle` used),
/// so this file can pin icon *presence* (the SF Symbol name, via
/// accessibility identifiers) but not resolved color for the new default —
/// a real, documented coverage gap, same posture as the pre-flip anchors this
/// class always disclosed rather than papered over.
@MainActor
final class DefaultAppearanceCharacterizationTests: XCTestCase {

    // MARK: - ChatTheme.swift — post-flip bubble tokens

    /// `ChatTheme.standard`'s scalar/font tokens since the Unit 2 §L5 flip.
    /// `cornerRadius` moved from `16` to `20` (`ManifoldThemeShapeScale.lg`
    /// alignment, spec §1 "concentric geometry"). Every other scalar/font is
    /// unchanged by the flip.
    func test_chatTheme_standard_scalarAndFontTokens() {
        let standard = ChatTheme.standard
        XCTAssertEqual(standard.cornerRadius, 20, "ChatTheme.swift post-flip default cornerRadius")
        XCTAssertEqual(standard.bubblePadding, 12, "ChatTheme.swift default bubblePadding (unchanged by the flip)")
        XCTAssertEqual(standard.contentSpacing, 4, "ChatTheme.swift default contentSpacing (unchanged by the flip)")
        XCTAssertEqual(standard.bubbleStackSpacing, 6, "ChatTheme.swift default bubbleStackSpacing (unchanged by the flip)")
        XCTAssertEqual(standard.bubbleFont, .body, "ChatTheme.swift default bubbleFont (unchanged by the flip)")
        XCTAssertEqual(standard.metadataFont, .caption, "ChatTheme.swift default metadataFont (unchanged by the flip)")
    }

    // MARK: - ManifoldTheme.swift — Color-typed status token defaults (unchanged by the flip)

    /// The flip is scoped to bubble chrome and the four style-protocol
    /// defaults — it does not re-hue any semantic token. `ManifoldTheme.standard`
    /// and `.classic` share these values.
    func test_manifoldTheme_standard_statusColorTokens_matchHistoricalLiterals() {
        let standard = ManifoldTheme.standard
        XCTAssertEqual(standard.statusOKColor, .green)
        XCTAssertEqual(standard.statusWarnColor, .yellow)
        XCTAssertEqual(standard.statusErrorColor, .red)
    }

    // MARK: - The flip-changes-output guard (reviewer-mandated, issue #2307 U2-L5)

    /// Guards against a future regression where a built-in style's default is
    /// silently hardcoded back to its classic counterpart in a way the
    /// wiring audits (source-shape checks) can't catch — this asserts the
    /// *resolved* environment defaults are actually the new-look types, not
    /// just that some style is present. If this ever fails, either the flip
    /// was reverted or a `PlainXStyle`/`ChatTheme.standard` edit accidentally
    /// re-collapsed default and classic back together.
    func test_defaultEnvironmentStyles_areNewLook_notClassic() {
        let env = EnvironmentValues()
        XCTAssertTrue(env.composerStyle is GlassComposerStyle, "composerStyle default must be the new-look GlassComposerStyle, not PlainComposerStyle")
        XCTAssertTrue(env.thinkingBlockStyle is ShimmerThinkingBlockStyle, "thinkingBlockStyle default must be the new-look ShimmerThinkingBlockStyle, not PlainThinkingBlockStyle")
        XCTAssertTrue(env.toolInvocationStyle is CardToolInvocationStyle, "toolInvocationStyle default must be the new-look CardToolInvocationStyle, not PlainToolInvocationStyle")
        XCTAssertTrue(env.sessionRowStyle is QuietSessionRowStyle, "sessionRowStyle default must be the new-look QuietSessionRowStyle, not PlainSessionRowStyle")
    }

    /// The companion half of the guard above: `.standard`/`.classic` (and the
    /// environment defaults vs. their `.plain`-preset counterparts) must
    /// actually differ on a rendered token, not merely be distinct Swift
    /// values that happen to resolve identically. `cornerRadius` is the one
    /// scalar in this inventory both sides can compare directly (bubble fill
    /// is an `AnyShapeStyle`/gradient, not `Equatable`).
    func test_standardVsClassic_differOnCornerRadius() {
        XCTAssertNotEqual(
            ManifoldTheme.standard.chatTheme.cornerRadius,
            ManifoldTheme.classic.chatTheme.cornerRadius,
            "standard and classic must render different bubble corner radii — if this ever passes as equal, the flip has been silently reverted"
        )
        XCTAssertEqual(ManifoldTheme.classic.chatTheme.cornerRadius, 16, "classic must still reproduce the pre-refresh 16pt radius")
    }

    // MARK: - ToolInvocationView — new default (CardToolInvocationStyle) icon presence

    /// Color is not pinned here (see class doc comment) — only that the
    /// completed/failed icons the new default renders are present at all,
    /// which is what a regression to "no icon"/wrong icon would break.
    func test_toolInvocationView_defaultStyle_completedIconIsPresent() throws {
        let call = ToolCall(id: "1", toolName: "demo", arguments: "{}")
        let result = ToolResult(callId: "1", content: "ok")
        let view = ToolInvocationView(part: .toolCall(call), state: .completed, pairedResult: result)
        XCTAssertNoThrow(
            try view.inspect().find(ViewType.Image.self) { image in
                (try? image.actualImage().name()) == "checkmark.circle"
            },
            "CardToolInvocationStyle (the new default) must still render the checkmark icon for .completed"
        )
    }

    func test_toolInvocationView_defaultStyle_failedIconIsPresent() throws {
        let call = ToolCall(id: "1", toolName: "demo", arguments: "{}")
        let result = ToolResult(callId: "1", content: "boom", errorKind: .transient)
        let view = ToolInvocationView(part: .toolCall(call), state: .failed, pairedResult: result)
        XCTAssertNoThrow(
            try view.inspect().find(ViewType.Image.self) { image in
                (try? image.actualImage().name()) == "exclamationmark.triangle"
            },
            "CardToolInvocationStyle (the new default) must still render the warning icon for .failed"
        )
    }

    // MARK: - MemoryIndicatorView.swift:32-34 — pressure-tier dot fill (unchanged by the flip)

    func test_memoryIndicatorView_nominal_isGreenDot() throws {
        try assertMemoryIndicatorDot(.nominal, expected: .green)
    }

    func test_memoryIndicatorView_warning_isYellowDot() throws {
        try assertMemoryIndicatorDot(.warning, expected: .yellow)
    }

    func test_memoryIndicatorView_critical_isRedDot() throws {
        try assertMemoryIndicatorDot(.critical, expected: .red)
    }

    private func assertMemoryIndicatorDot(
        _ level: MemoryPressureLevel,
        expected: Color,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let view = MemoryIndicatorView(
            pressureLevel: level,
            physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
            appMemoryBytes: 1024 * 1024 * 1024
        )
        let dot = try view.inspect().hStack().shape(0)
        let style = try dot.fillShapeStyle(Color.self)
        XCTAssertEqual(style, expected, "MemoryIndicatorView.swift:32-34 indicatorColor(\(level))", file: file, line: line)
    }

    // MARK: - ContextIndicatorView.swift:26-28 — usage-ratio color (unchanged by the flip)

    func test_contextIndicatorView_lowUsage_percentageText_isSecondary() throws {
        try assertContextIndicatorPercentageColor(usedTokens: 10, maxTokens: 100, expected: .secondary)
    }

    func test_contextIndicatorView_highUsage_percentageText_isYellow() throws {
        try assertContextIndicatorPercentageColor(usedTokens: 85, maxTokens: 100, expected: .yellow)
    }

    func test_contextIndicatorView_criticalUsage_percentageText_isRed() throws {
        try assertContextIndicatorPercentageColor(usedTokens: 97, maxTokens: 100, expected: .red)
    }

    private func assertContextIndicatorPercentageColor(
        usedTokens: Int,
        maxTokens: Int,
        expected: Color,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let view = ContextIndicatorView(usedTokens: usedTokens, maxTokens: maxTokens)
        let percentageText = try view.inspect().find(ViewType.Text.self)
        let style = try percentageText.attributes().foregroundColor()
        XCTAssertEqual(style, expected, "ContextIndicatorView.swift:25-28,53 color(ratio)", file: file, line: line)
    }
}
