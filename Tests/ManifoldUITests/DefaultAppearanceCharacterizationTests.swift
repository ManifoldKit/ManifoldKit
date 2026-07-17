import XCTest
import SwiftUI
import ViewInspector
@testable import ManifoldUI
import ManifoldInference

/// Locks today's rendered appearance **before** the token-refactor migration
/// tranches (`T1-migrate-ui`/`-mmgmt`/`-voice`, issue #2307 §1.3) touch any
/// view file. Per the plan's sync point 1 (`docs/UI-REFRESH-2026-PLAN.md`
/// "Synchronization points"), these tests exist and pass *before* any literal
/// is replaced by a `ManifoldTheme` token read — the rewiring diff must prove
/// itself against this baseline, not the other way around.
///
/// Covers the `ManifoldUI`-module anchors only (`ChatTheme`, `ToolInvocationView`,
/// `MemoryIndicatorView`, `ContextIndicatorView`). The `ManifoldUIModelManagement`
/// anchors (`ModelPicker`, `DownloadableModelRow`) live in a companion
/// `DefaultAppearanceCharacterizationTests.swift` in `Tests/ManifoldUIModelManagementTests`
/// — `ManifoldUITests` cannot import `ManifoldUIModelManagement` (dependency
/// direction: mmgmt depends on UI, never the reverse).
///
/// ## What's covered, and why some anchors aren't runtime-asserted here
///
/// Every value pinned below is either (a) read directly off a public/internal
/// API (`ChatTheme`'s stored properties, `DownloadableModelRow.fitTint(_:)`),
/// or (b) extracted from the actual rendered view tree via ViewInspector's
/// `foregroundStyleShapeStyle(Color.self)` / `fillShapeStyle(Color.self)` —
/// both only resolve a modifier whose `ShapeStyle` argument is a plain
/// `Color` (e.g. `.foregroundStyle(.green)`, `Circle().fill(indicatorColor)`).
///
/// `ViewInspector` 0.10.x (`Package.swift`) has no equivalent extractor for
/// `.background(_:in:)` or for `HierarchicalShapeStyle`/opacity-composited
/// styles (`.quaternary.opacity(0.5)`, `.orange.opacity(0.15)`,
/// `.fill.tertiary`) — there is no modifier-attribute path that resolves
/// those to a concrete, comparable value. Those specific anchors
/// (`ToolInvocationView.swift:135,237`, `ChatInputBar.swift:61`,
/// `ModelPicker.swift:269-272`'s badge fill, `DownloadableModelRow.swift`'s
/// `speedTint`/`badgeColor` results, which are also `private` and therefore
/// uncallable from this test file even setting ViewInspector aside) are
/// **not** runtime-pinned here. `HardcodedColorAuditTest` (§1.4) still polices
/// silent drift on their literal text via source scanning, and the migration
/// tranche that touches each file carries the burden of proving the resolved
/// color is unchanged by manual/visual review. This is a real coverage gap,
/// not an oversight — flagged for the orchestrator in the tranche report.
@MainActor
final class DefaultAppearanceCharacterizationTests: XCTestCase {

    // MARK: - ChatTheme.swift:22-51 — fills, fonts, radii, paddings

    /// `ChatTheme.standard`'s scalar/font tokens, pinned directly off the
    /// stored properties (`ChatTheme.swift:32-51`).
    func test_chatTheme_standard_scalarAndFontTokens() {
        let standard = ChatTheme.standard
        XCTAssertEqual(standard.cornerRadius, 16, "ChatTheme.swift:32 default cornerRadius")
        XCTAssertEqual(standard.bubblePadding, 12, "ChatTheme.swift:35 default bubblePadding")
        XCTAssertEqual(standard.contentSpacing, 4, "ChatTheme.swift:39 default contentSpacing")
        XCTAssertEqual(standard.bubbleStackSpacing, 6, "ChatTheme.swift:43 default bubbleStackSpacing")
        XCTAssertEqual(standard.bubbleFont, .body, "ChatTheme.swift:47 default bubbleFont")
        XCTAssertEqual(standard.metadataFont, .caption, "ChatTheme.swift:51 default metadataFont")
    }

    /// `ChatTheme.swift:22-29`'s bubble fills are drawn via
    /// `.background(chrome.background, in: RoundedRectangle(...))`
    /// (`MessageBubbleStyle.swift:86-88`) — a `.background(_:in:)` modifier,
    /// which ViewInspector 0.10.x cannot resolve to a concrete `ShapeStyle`
    /// (see the class doc comment). `ChatTheme.swift` itself is not touched by
    /// any Unit-1 migration tranche — the migrations move *other* files'
    /// literals onto `ManifoldTheme` tokens, they never edit `ChatTheme.swift`
    /// — so the risk this specific anchor drifts during Unit 1 is near zero.
    /// The scalar/font assertion above is what actually guards this file.

    // MARK: - ToolInvocationView.swift:183,229 — plain-Color status foreground styles

    func test_toolInvocationView_successCheckmark_isGreen() throws {
        let call = ToolCall(id: "1", toolName: "demo", arguments: "{}")
        let result = ToolResult(callId: "1", content: "ok")
        let view = ToolInvocationView(part: .toolCall(call), state: .completed, pairedResult: result)
        let checkmark = try view.inspect().find(ViewType.Image.self) { image in
            (try? image.actualImage().name()) == "checkmark.circle"
        }
        let style = try checkmark.foregroundStyleShapeStyle(Color.self)
        XCTAssertEqual(style, Color.green, "ToolInvocationView.swift:183 success checkmark foreground")
    }

    func test_toolInvocationView_failureIcon_isOrange() throws {
        let call = ToolCall(id: "1", toolName: "demo", arguments: "{}")
        let result = ToolResult(callId: "1", content: "boom", errorKind: .transient)
        let view = ToolInvocationView(part: .toolCall(call), state: .failed, pairedResult: result)
        let icon = try view.inspect().find(ViewType.Image.self) { image in
            (try? image.actualImage().name()) == "exclamationmark.triangle"
        }
        let style = try icon.foregroundStyleShapeStyle(Color.self)
        XCTAssertEqual(style, Color.orange, "ToolInvocationView.swift:229 failure icon foreground")
    }

    // MARK: - MemoryIndicatorView.swift:32-34 — pressure-tier dot fill

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

    // MARK: - ContextIndicatorView.swift:26-28 — usage-ratio color

    /// Below the 80% threshold the percentage text foreground is `Color.secondary`
    /// (`ContextIndicatorView.swift:53`'s `.secondary` ternary branch — `Color`,
    /// not `HierarchicalShapeStyle`, because the other ternary branch is the
    /// `color: Color` computed property and both arms of a ternary must share
    /// a static type).
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
