import XCTest
import SwiftUI
import ViewInspector
@testable import ManifoldUI
import ManifoldInference

/// Pins `.classic` to the exact values ``DefaultAppearanceCharacterizationTests``
/// pinned `.standard` to **before** the Unit 2 §L5 defaults flip (issue
/// #2307) — the pre-refresh appearance must remain reproducible forever, even
/// though it is no longer the framework default. Every assertion below is a
/// straight copy of this repo's pre-flip characterization values; only the
/// theme/style under test changed from `.standard`/the environment default to
/// `.classic`/the `.plain` presets.
///
/// ## Why `ToolInvocationView`'s classic-style checks build ``PlainToolInvocationStyle``
/// directly instead of rendering ``ToolInvocationView`` under an environment
/// override
///
/// `StyleWiringAuditTest`'s class doc comment documents an empirically
/// confirmed `ViewInspector` 0.10.x limitation: `.inspect()` does not
/// re-resolve a custom view's `@Environment` reads against an
/// externally-applied `.environment(\.toolInvocationStyle, ...)` override —
/// rendering `ToolInvocationView(...).environment(\.toolInvocationStyle, PlainToolInvocationStyle())`
/// and inspecting it would still observe whatever the *default* environment
/// value resolves to (now `CardToolInvocationStyle`, post-flip), not the
/// override. So this file pins `PlainToolInvocationStyle`'s own
/// `makeBody(configuration:)` output directly — the same "configuration
/// correctness via direct `Resolved*` construction" pattern
/// `StyleProtocolDispatchTests` already established for dispatch-matrix
/// coverage — rather than attempting a live environment-injected render.
@MainActor
final class ClassicAppearanceCharacterizationTests: XCTestCase {

    // MARK: - ChatTheme.classic — pre-refresh scalar/font tokens

    func test_chatTheme_classic_scalarAndFontTokens() {
        let classic = ChatTheme.classic
        XCTAssertEqual(classic.cornerRadius, 16, "ChatTheme.classic must reproduce the pre-refresh 16pt cornerRadius")
        XCTAssertEqual(classic.bubblePadding, 12)
        XCTAssertEqual(classic.contentSpacing, 4)
        XCTAssertEqual(classic.bubbleStackSpacing, 6)
        XCTAssertEqual(classic.bubbleFont, .body)
        XCTAssertEqual(classic.metadataFont, .caption)
    }

    /// `ChatTheme.classic`'s user-bubble fill is the pre-refresh solid
    /// `Color.accentColor` — not the post-flip gradient `ChatTheme.standard`
    /// carries. Not runtime-pinned here: `userBubbleBackground` is
    /// `AnyShapeStyle`-typed (so a bubble renders it via `.background(_:in:)`,
    /// not a plain `.foregroundStyle(_:)`/`.fill(_:)` argument), and
    /// `ViewInspector` 0.10.x has no extractor that resolves an
    /// `AnyShapeStyle` back to a concrete, comparable value — the same gap
    /// `ManifoldTheme.swift`'s `statusOKColor` doc comment documents for the
    /// analogous `AnyShapeStyle` status tokens. `test_chatTheme_classic_scalarAndFontTokens`
    /// above is what actually guards `ChatTheme.classic`'s other tokens; this
    /// one field's exact-fill regression risk is flagged, not silently
    /// dropped, matching this suite's established disclosure policy.

    // MARK: - ManifoldTheme.classic — Color-typed status token defaults

    func test_manifoldTheme_classic_statusColorTokens_matchHistoricalLiterals() {
        let classic = ManifoldTheme.classic
        XCTAssertEqual(classic.statusOKColor, .green)
        XCTAssertEqual(classic.statusWarnColor, .yellow)
        XCTAssertEqual(classic.statusErrorColor, .red)
    }

    // MARK: - ToolInvocationView (classic == PlainToolInvocationStyle) — plain-Color status foreground styles

    func test_toolInvocationView_classicStyle_successCheckmark_isGreen() throws {
        let configuration = ToolInvocationConfiguration(
            state: .completed,
            toolName: "demo",
            arguments: "{}",
            resultContent: "ok",
            errorPresentation: nil,
            onApprove: nil,
            onDeny: nil,
            onReauthenticate: nil
        )
        let body = PlainToolInvocationStyle().makeBody(configuration: configuration)
        let checkmark = try body.inspect().find(ViewType.Image.self) { image in
            (try? image.actualImage().name()) == "checkmark.circle"
        }
        let style = try checkmark.foregroundStyleShapeStyle(Color.self)
        XCTAssertEqual(style, Color.green, "PlainToolInvocationStyle (classic) success checkmark foreground")
    }

    func test_toolInvocationView_classicStyle_failureIcon_isOrange() throws {
        let configuration = ToolInvocationConfiguration(
            state: .failed,
            toolName: "demo",
            arguments: "{}",
            resultContent: "boom",
            errorPresentation: ToolErrorPresentation(errorKind: .transient, toolName: "demo"),
            onApprove: nil,
            onDeny: nil,
            onReauthenticate: nil
        )
        let body = PlainToolInvocationStyle().makeBody(configuration: configuration)
        let icon = try body.inspect().find(ViewType.Image.self) { image in
            (try? image.actualImage().name()) == "exclamationmark.triangle"
        }
        let style = try icon.foregroundStyleShapeStyle(Color.self)
        XCTAssertEqual(style, Color.orange, "PlainToolInvocationStyle (classic) failure icon foreground")
    }

    // MARK: - MemoryIndicatorView.swift:32-34 — pressure-tier dot fill (unaffected by the flip)

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

    // MARK: - ContextIndicatorView.swift:26-28 — usage-ratio color (unaffected by the flip)

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
