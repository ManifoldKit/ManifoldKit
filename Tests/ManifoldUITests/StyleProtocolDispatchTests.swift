import XCTest
import SwiftUI
import ViewInspector
import ManifoldInference
import ManifoldRuntime
@testable import ManifoldUI

/// Dispatch-matrix and liveness tests for the Unit 2 §L2 style protocols
/// (`docs/UI-REFRESH-2026.md` §8, issue #2307): ``ComposerStyle``,
/// ``ThinkingBlockStyle``, ``ToolInvocationStyle``, ``SessionRowStyle``, and
/// the ``ChatMessagePartRenderer`` seam. Each recording style below proves the
/// dispatch actually reaches the style with the correct `Configuration` for
/// every typed state — the plan's "tool ×4, composer ×4, thinking ×3" bar
/// (`docs/UI-REFRESH-2026-PLAN.md` §L2).
///
/// ## What is proven, and how
///
/// **Configuration correctness** (does a style, given a `Configuration`,
/// render the right thing for every typed state) is proven via direct
/// `Resolved*(style:configuration:)` construction (mirroring `ChatThemingTests`'
/// `test_resolvedBubble_...`), bypassing SwiftUI's environment machinery
/// entirely — the style and configuration are passed straight to the
/// constructor.
///
/// **Live wiring** (does the production view — `ThinkingBlockView` /
/// `ToolInvocationView` / `SessionRowView` — actually read its style from
/// `@Environment` and feed it into the matching `Resolved*` wrapper, rather
/// than a hardcoded style or the old pre-refresh rendering) is proven by
/// `StyleWiringAuditTest`'s audits (a separate file, so
/// `AuditSabotageCoverageAuditTest` — which discovers audits by filename —
/// actually sees them and enforces their `test_sabotage_...` coverage). Those
/// grep the view's own source for the `@Environment(\.xStyle)` property
/// **and** a `ResolvedX(style: style, ...)` construction. This is a
/// source-shape check, not a runtime one — it cannot verify SwiftUI actually
/// *propagates* the right value through the environment at render time, only
/// that the view's code path is structurally wired to ask for it.
///
/// **What is NOT proven**: that SwiftUI's environment propagation itself
/// correctly delivers a `.toolInvocationStyle(_:)`-installed value down to
/// the reading `@Environment` property at render time. That is standard
/// `@Entry`/`.environment(_:_:)` machinery this file does not reimplement,
/// and it could not be verified through `ViewInspector` here: `ViewInspector`
/// 0.10.x's plain `.inspect()` does not re-resolve a custom view's
/// `@Environment` reads against an externally-applied `.environment()`
/// override — confirmed empirically two ways, both showing the view's body
/// still observed the *default* environment value: (1) a minimal repro with
/// a throwaway `@Entry` key and a `Text` reading it, and (2)
/// `ViewHosting.host(_:)` (both the synchronous and the
/// `async`-with-post-host-delay forms) applied to `ToolInvocationView`
/// itself with a custom `ToolInvocationStyle` installed via `.environment()`
/// — `.inspect()` after hosting still rendered the default `PlainToolInvocationStyle`
/// output, not the custom style's. If a future `ViewInspector` upgrade fixes
/// this, `StyleWiringAuditTest`'s audits should be replaced with real
/// environment-injected `ViewHosting` liveness tests.
@MainActor
final class StyleProtocolDispatchTests: XCTestCase {

    /// `ViewInspector`'s `.inspect().find(...)` evaluates a view's `body`
    /// more than once while resolving the search (confirmed empirically: a
    /// recording style hit twice per single `.find()` call, always as exact
    /// adjacent duplicates). Collapsing adjacent duplicates keeps the
    /// dispatch-order assertions meaningful without asserting on
    /// ViewInspector's internal re-evaluation count, which is not part of
    /// this seam's public contract.
    private func dedupAdjacent<T: Equatable>(_ values: [T]) -> [T] {
        var result: [T] = []
        for value in values where result.last != value {
            result.append(value)
        }
        return result
    }

    // MARK: - Recording styles
    //
    // Plain classes (not actors) marked `@unchecked Sendable`, matching this
    // suite's established recorder pattern (e.g. `ChatViewModelLoadProgressBridgeTests`'
    // `Counter`) — every recording happens synchronously on the main actor
    // during a single `ViewInspector` `.inspect()` call, so no real
    // cross-thread race exists.

    final class ComposerRecorder: @unchecked Sendable {
        var seenPhases: [ComposerPhase] = []
    }

    private struct RecordingComposerStyle: ComposerStyle {
        let recorder: ComposerRecorder
        func makeBody(configuration: Configuration) -> some View {
            recorder.seenPhases.append(configuration.phase)
            return configuration.content
        }
    }

    final class ThinkingRecorder: @unchecked Sendable {
        var seenStates: [ThinkingBlockState] = []
    }

    private struct RecordingThinkingBlockStyle: ThinkingBlockStyle {
        let recorder: ThinkingRecorder
        func makeBody(configuration: Configuration) -> some View {
            recorder.seenStates.append(configuration.state)
            return Text(configuration.text)
        }
    }

    final class ToolRecorder: @unchecked Sendable {
        var seenStates: [ToolInvocationLifecycleState] = []
    }

    private struct RecordingToolInvocationStyle: ToolInvocationStyle {
        let recorder: ToolRecorder
        func makeBody(configuration: Configuration) -> some View {
            recorder.seenStates.append(configuration.state)
            return Text(configuration.toolName)
        }
    }

    // MARK: - Composer: 4 phases reach the style

    func test_composerStyle_dispatchesAllFourPhases() throws {
        let recorder = ComposerRecorder()
        let phases: [ComposerPhase] = [.idle, .composing, .generating, .voice]

        for phase in phases {
            let configuration = ComposerConfiguration(
                content: AnyView(Text("field")),
                phase: phase,
                hasAttachments: false
            )
            let resolved = ResolvedComposer(style: RecordingComposerStyle(recorder: recorder), configuration: configuration)
            _ = try resolved.inspect().find(text: "field")
        }

        XCTAssertEqual(dedupAdjacent(recorder.seenPhases), phases, "All four ComposerPhase states must reach the style")
    }

    /// Since Unit 2 §L5's defaults flip (issue #2307) the built-in default is
    /// the new-look `GlassComposerStyle`, not `PlainComposerStyle` — see
    /// `DefaultAppearanceCharacterizationTests.test_defaultEnvironmentStyles_areNewLook_notClassic`
    /// for the guard test and `ClassicAppearanceCharacterizationTests` for the
    /// restored-look pin.
    func test_defaultEnvironmentComposerStyle_isGlass() {
        XCTAssertTrue(EnvironmentValues().composerStyle is GlassComposerStyle)
    }

    // MARK: - Thinking block: 3 states reach the style

    func test_thinkingBlockStyle_dispatchesAllThreeStates() throws {
        let recorder = ThinkingRecorder()
        let states: [ThinkingBlockState] = [.streaming, .settled(duration: 4), .expanded(duration: 4)]

        for state in states {
            let configuration = ThinkingBlockConfiguration(state: state, text: "reasoning trace", toggleExpanded: {})
            let resolved = ResolvedThinkingBlock(style: RecordingThinkingBlockStyle(recorder: recorder), configuration: configuration)
            _ = try resolved.inspect().find(text: "reasoning trace")
        }

        XCTAssertEqual(dedupAdjacent(recorder.seenStates), states, "All three ThinkingBlockState cases must reach the style")
    }

    /// Since Unit 2 §L5's defaults flip (issue #2307) the built-in default is
    /// the new-look `ShimmerThinkingBlockStyle`.
    func test_defaultEnvironmentThinkingBlockStyle_isShimmer() {
        XCTAssertTrue(EnvironmentValues().thinkingBlockStyle is ShimmerThinkingBlockStyle)
    }

    /// `duration == 0` is the documented "unknown" convention for a block
    /// never observed streaming (``ThinkingBlockState``'s doc comment).
    func test_thinkingBlockState_unknownDuration_isZero() {
        let state = ThinkingBlockState.settled(duration: 0)
        guard case .settled(let duration) = state else {
            return XCTFail("expected .settled")
        }
        XCTAssertEqual(duration, 0)
    }

    // MARK: - Tool invocation: 4 lifecycle states reach the style

    func test_toolInvocationStyle_dispatchesAllFourStates() throws {
        let recorder = ToolRecorder()
        let states: [ToolInvocationLifecycleState] = [.awaitingApproval, .running, .completed, .failed]

        for state in states {
            let configuration = ToolInvocationConfiguration(
                state: state,
                toolName: "sample_tool",
                arguments: nil,
                resultContent: nil,
                errorPresentation: nil,
                onApprove: nil,
                onDeny: nil,
                onReauthenticate: nil
            )
            let resolved = ResolvedToolInvocation(style: RecordingToolInvocationStyle(recorder: recorder), configuration: configuration)
            _ = try resolved.inspect().find(text: "sample_tool")
        }

        XCTAssertEqual(dedupAdjacent(recorder.seenStates), states, "All four ToolInvocationLifecycleState cases must reach the style")
    }

    /// Since Unit 2 §L5's defaults flip (issue #2307) the built-in default is
    /// the new-look `CardToolInvocationStyle`.
    func test_defaultEnvironmentToolInvocationStyle_isCard() {
        XCTAssertTrue(EnvironmentValues().toolInvocationStyle is CardToolInvocationStyle)
    }

    /// `ToolInvocationView.body` must construct its `ResolvedToolInvocation`
    /// from the resolved `state`/`toolName`/`arguments`/`result` for every
    /// `(part, state)` combination it accepts — the liveness check that the
    /// production view actually feeds the new protocol rather than dead code
    /// sitting next to the old hardcoded switch.
    func test_toolInvocationView_buildsPlainStyleOutput_forEveryState() throws {
        let call = ToolCall(id: "1", toolName: "get_weather", arguments: "{}")

        let pending = ToolInvocationView(part: .toolCall(call), state: .pendingApproval)
        _ = try pending.inspect().find(text: "get_weather")

        let running = ToolInvocationView(part: .toolCall(call), state: .running)
        let runningText = try running.inspect().find(ViewType.Text.self)
        XCTAssertTrue(try runningText.string().contains("get_weather"))

        let completed = ToolInvocationView(part: .toolCall(call), state: .completed)
        _ = try completed.inspect().find(text: "get_weather")

        let failed = ToolInvocationView(
            part: .toolResult(ToolResult(callId: "1", content: "denied", errorKind: .permissionDenied)),
            state: .failed
        )
        _ = try failed.inspect().find(text: "tool")
    }

    // MARK: - SessionRowView liveness

    func test_sessionRowView_buildsPlainStyleOutput() throws {
        let session = ChatSession(
            id: UUID(),
            title: "Pinned chat",
            createdAt: Date(),
            updatedAt: Date(),
            isPinned: true
        )
        let view = SessionRowView(session: session, isSelected: true)
        _ = try view.inspect().find(text: "Pinned chat")
    }

    /// Since Unit 2 §L5's defaults flip (issue #2307) the built-in default is
    /// the new-look `QuietSessionRowStyle`.
    func test_defaultEnvironmentSessionRowStyle_isQuiet() {
        XCTAssertTrue(EnvironmentValues().sessionRowStyle is QuietSessionRowStyle)
    }

    /// The resolved wrapper reaches a custom style with the exact
    /// title/snippet/isPinned/isSelected/updatedAt the spec's Configuration
    /// carries (spec §8) — proven directly, same rationale as the class doc
    /// comment on why this file avoids `.sessionRowStyle(_:)` +
    /// `ViewInspector` for the live-environment path.
    func test_resolvedSessionRow_carriesFullConfiguration() throws {
        final class Recorder: @unchecked Sendable { var configurations: [SessionRowConfiguration] = [] }
        struct RecordingStyle: SessionRowStyle {
            let recorder: Recorder
            func makeBody(configuration: Configuration) -> some View {
                recorder.configurations.append(configuration)
                return Text(configuration.title)
            }
        }

        let recorder = Recorder()
        let updatedAt = Date()
        let configuration = SessionRowConfiguration(
            title: "Pinned chat",
            snippet: "Last message preview",
            updatedAt: updatedAt,
            isPinned: true,
            isSelected: true
        )
        let resolved = ResolvedSessionRow(style: RecordingStyle(recorder: recorder), configuration: configuration)
        _ = try resolved.inspect().find(text: "Pinned chat")

        let seen = dedupAdjacent(recorder.configurations.map { $0.title })
        XCTAssertEqual(seen, ["Pinned chat"])
        XCTAssertEqual(recorder.configurations.first?.snippet, "Last message preview")
        XCTAssertEqual(recorder.configurations.first?.isPinned, true)
        XCTAssertEqual(recorder.configurations.first?.isSelected, true)
        XCTAssertEqual(recorder.configurations.first?.updatedAt, updatedAt)
    }

    // MARK: - Part-renderer: fallthrough contract

    /// A renderer that overrides one part kind and falls through
    /// (`defaultPartView()`) for the rest.
    func test_partRenderer_fallsThroughToDefaultPartView() throws {
        let toolCall = MessagePart.toolCall(ToolCall(id: "1", toolName: "get_weather", arguments: "{}"))
        let textPart = MessagePart.text("hello")

        let renderer: ChatMessagePartRenderer = { params in
            if case .toolCall(let call) = params.part, call.toolName == "get_weather" {
                return AnyView(Text("CUSTOM:\(call.toolName)"))
            }
            return params.defaultPartView()
        }

        let toolParams = ChatMessagePartRenderParameters(
            part: toolCall,
            role: .assistant,
            isStreaming: false,
            defaultView: { AnyView(Text("default-tool")) }
        )
        let textParams = ChatMessagePartRenderParameters(
            part: textPart,
            role: .assistant,
            isStreaming: false,
            defaultView: { AnyView(Text("default-text")) }
        )

        let customOutput = renderer(toolParams)
        _ = try customOutput.inspect().find(text: "CUSTOM:get_weather")

        let fallthroughOutput = renderer(textParams)
        _ = try fallthroughOutput.inspect().find(text: "default-text")
    }

    /// LAST-WINS composition: `EnvironmentValues` is a plain struct with one
    /// `@Entry`-backed storage slot per key (mirrors ``chatMessageRenderer``'s
    /// slot) — writing the key twice keeps only the most recent write, which
    /// is exactly what makes nested `.chatMessagePartRenderer(_:)`
    /// applications resolve to whichever is closest to the point of
    /// consumption, the same way `.font(_:)`/`.tint(_:)` cascade. This tests
    /// that storage contract directly rather than SwiftUI's view-tree
    /// environment propagation, which this seam does not reimplement (see
    /// the class doc comment).
    func test_partRenderer_lastWins_overwritesEarlierEnvironmentWrite() throws {
        let outer: ChatMessagePartRenderer = { _ in AnyView(Text("OUTER")) }
        let inner: ChatMessagePartRenderer = { _ in AnyView(Text("INNER")) }

        var env = EnvironmentValues()
        env.chatMessagePartRenderer = outer
        env.chatMessagePartRenderer = inner

        let params = ChatMessagePartRenderParameters(
            part: .text("irrelevant"),
            role: .assistant,
            isStreaming: false,
            defaultView: { AnyView(Text("default")) }
        )
        let output = try XCTUnwrap(env.chatMessagePartRenderer)(params)
        _ = try output.inspect().find(text: "INNER")
    }

    func test_defaultEnvironmentPartRenderer_isNil() {
        XCTAssertNil(EnvironmentValues().chatMessagePartRenderer)
    }

    // MARK: - Categorical / info token tier: defaults match today's literals

    /// Rory's 2026-07-18 decision on #2307: the categorical/info tier must
    /// default to exactly the literals it replaces — zero visual change.
    func test_categoricalAndInfoTokens_defaultToHistoricalLiterals() {
        let standard = ManifoldTheme.standard
        XCTAssertEqual(standard.infoColor, .blue, "info defaults to the .blue literal every curated/in-use/download call site uses")
        XCTAssertEqual(standard.categorical.orangeColor, .orange, "GGUF badge / sluggish speed class literal")
        XCTAssertEqual(standard.categorical.purpleColor, .purple, "MLX badge literal")
        XCTAssertEqual(standard.categorical.blueColor, .blue, "usable speed class literal")
        XCTAssertEqual(standard.categorical.grayColor, .gray, "default/unknown model-format badge literal")
    }

    func test_customTheme_canOverrideCategoricalTokens() {
        let custom = ManifoldTheme(categorical: ManifoldThemeCategoricalTints(orangeColor: .brown))
        XCTAssertEqual(custom.categorical.orangeColor, .brown)
        XCTAssertNotEqual(custom.categorical.orangeColor, ManifoldTheme.standard.categorical.orangeColor)
    }
}
