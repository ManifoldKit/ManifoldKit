import XCTest
import Foundation

/// Audit: every Unit 2 §L2 style-protocol view that claims to be "live" (as
/// opposed to the still-inert `ComposerStyle`/`chatMessagePartRenderer`
/// seams — see the U2-L2 PR body's inert-surfaces table, issue #2307) must
/// actually read its style from `@Environment` and feed it into the matching
/// `Resolved*` wrapper, not a hardcoded style.
///
/// This is a source-shape check, not a runtime one: it cannot verify SwiftUI
/// actually *propagates* the right value through the environment at render
/// time — `ViewInspector` 0.10.x's plain `.inspect()` does not re-resolve a
/// custom view's `@Environment` reads against an externally-applied
/// `.environment()` override (confirmed empirically two ways, both showing
/// the view's body still observed the *default* environment value: a
/// minimal repro with a throwaway `@Entry` key, and `ViewHosting.host(_:)`
/// applied to `ToolInvocationView` itself). If a future `ViewInspector`
/// upgrade fixes this, these audits should be replaced with real
/// environment-injected `ViewHosting` liveness tests — see
/// `StyleProtocolDispatchTests`'s class doc comment for the full writeup of
/// what that suite proves instead (`Resolved*(style:configuration:)`
/// dispatch-matrix correctness).
///
/// Named `*Audit*` (not `StyleProtocolDispatchTests`, where these lived
/// originally) so `AuditSabotageCoverageAuditTest` — which discovers audits
/// by filename — actually sees this file and enforces its
/// `test_sabotage_...` coverage.
final class StyleWiringAuditTest: XCTestCase {

    /// The real detection function: `true` only when `source` both reads the
    /// style from the given environment key path AND feeds it into the
    /// matching `Resolved*(style: style, ...)` construction. A source that
    /// hardcodes a concrete style (no environment read) or that reads the
    /// environment but never forwards it into the resolved wrapper both fail
    /// this — either shape is a live-view regression back to "not actually
    /// styleable."
    static func isWired(source: String, environmentKeyPath: String, resolvedWrapperCall: String) -> Bool {
        let readsEnvironment = source.contains("@Environment(\\.\(environmentKeyPath))")
        let feedsResolvedWrapper = source.contains("\(resolvedWrapperCall)(") && source.contains("style: style,")
        return readsEnvironment && feedsResolvedWrapper
    }

    /// The `chatMessagePartRenderer` sibling of ``isWired(source:environmentKeyPath:resolvedWrapperCall:)``
    /// — the part-renderer seam is a plain closure, not a `MessageBubbleStyle`-
    /// family protocol dispatched through a `Resolved*` wrapper, so it needs
    /// its own three-part shape check: the source must (1) read the renderer
    /// from `\.chatMessagePartRenderer`, (2) invoke it with a
    /// `defaultView:` closure that falls through to the view's own per-kind
    /// dispatch, and (3) actually call that per-kind dispatch when no
    /// renderer is installed. Any one of these missing is a live-wiring
    /// regression back to "installs an environment value nothing reads."
    static func isPartRendererWired(source: String) -> Bool {
        let readsEnvironment = source.contains("@Environment(\\.chatMessagePartRenderer)")
        let feedsDefaultViewFallthrough = source.contains("partRenderer(")
            && source.contains("defaultView: { AnyView(defaultPartView(for: part)) }")
        // `defaultPartView(for: part)` must appear at least twice: once
        // inside the `defaultView:` closure handed to the host renderer, and
        // once more as the view's own no-renderer-installed fallthrough call
        // — a source that only ever mentions it inside the closure (the
        // no-renderer branch calls something else instead, e.g. `EmptyView()`)
        // has the closure but never actually falls through when unset, and a
        // plain single-substring check can't tell the two shapes apart.
        let fallsThroughWhenUnset = source.components(separatedBy: "defaultPartView(for: part)").count - 1 >= 2
        return readsEnvironment && feedsDefaultViewFallthrough && fallsThroughWhenUnset
    }

    // MARK: - Audits

    func test_toolInvocationView_readsStyleEnvironmentAndFeedsResolvedWrapper() throws {
        let source = try Self.sourceText(relativeToManifoldUI: "Views/Chat/ToolInvocationView.swift")
        XCTAssertTrue(
            Self.isWired(source: source, environmentKeyPath: "toolInvocationStyle", resolvedWrapperCall: "ResolvedToolInvocation"),
            "ToolInvocationView must read its style from the environment and feed it into ResolvedToolInvocation, not hardcode one"
        )
    }

    func test_thinkingBlockView_readsStyleEnvironmentAndFeedsResolvedWrapper() throws {
        let source = try Self.sourceText(relativeToManifoldUI: "Views/Chat/ThinkingBlockView.swift")
        XCTAssertTrue(
            Self.isWired(source: source, environmentKeyPath: "thinkingBlockStyle", resolvedWrapperCall: "ResolvedThinkingBlock"),
            "ThinkingBlockView must read its style from the environment and feed it into ResolvedThinkingBlock, not hardcode one"
        )
    }

    func test_sessionRowView_readsStyleEnvironmentAndFeedsResolvedWrapper() throws {
        let source = try Self.sourceText(relativeToManifoldUI: "Views/Sidebar/SessionRowView.swift")
        XCTAssertTrue(
            Self.isWired(source: source, environmentKeyPath: "sessionRowStyle", resolvedWrapperCall: "ResolvedSessionRow"),
            "SessionRowView must read its style from the environment and feed it into ResolvedSessionRow, not hardcode one"
        )
    }

    /// Unit 2 §L3 (issue #2307): `ComposerStyle` moved from "fully inert" (the
    /// U2-L2 PR body's inert-surfaces table) to live — `ChatInputBar` now
    /// reads `\.composerStyle` and dispatches through `ResolvedComposer`.
    func test_chatInputBar_readsComposerStyleEnvironmentAndFeedsResolvedWrapper() throws {
        let source = try Self.sourceText(relativeToManifoldUI: "Views/Chat/ChatInputBar.swift")
        XCTAssertTrue(
            Self.isWired(source: source, environmentKeyPath: "composerStyle", resolvedWrapperCall: "ResolvedComposer"),
            "ChatInputBar must read its style from the environment and feed it into ResolvedComposer, not hardcode one"
        )
    }

    /// Unit 2 §L5 (issue #2307, #1640): `chatMessagePartRenderer` moved from
    /// "fully inert" (the U2-L2 PR body's inert-surfaces table) to live —
    /// `MessagePartsView` now reads `\.chatMessagePartRenderer` and gives it
    /// first refusal per part before falling through to `defaultPartView(for:)`.
    /// This wiring doesn't fit `isWired(...)`'s `Resolved*`-wrapper shape (the
    /// part renderer is a plain closure, not a `MessageBubbleStyle`-family
    /// protocol dispatch), so it gets its own direct source check.
    func test_messagePartsView_readsPartRendererEnvironmentAndFallsThroughToDefault() throws {
        let source = try Self.sourceText(relativeToManifoldUI: "Views/Chat/MessagePartsView.swift")
        XCTAssertTrue(
            Self.isPartRendererWired(source: source),
            "MessagePartsView must read the part renderer from the environment, hand it a defaultPartView() fallthrough, and fall through to its own per-kind dispatch when no renderer is installed"
        )
    }

    // MARK: - Sabotage (exercises the real `isWired` detection function)

    /// Plants a synthetic, unwired source string — a hardcoded style with no
    /// `@Environment` read at all, the shape a regression (e.g. reverting
    /// `ToolInvocationView` back to `style: PlainToolInvocationStyle()`)
    /// would produce — and asserts the real `isWired(...)` predicate flags
    /// it. This was additionally verified live against the actual production
    /// files during development (temporarily replacing each view's
    /// `style: style,` with a hardcoded `style: PlainXStyle(),` and
    /// confirming the corresponding audit above failed, then reverting
    /// before committing); this in-file version is the permanent,
    /// synthetic-fixture form `AuditSabotageCoverageAuditTest` requires.
    func test_sabotage_unwiredHardcodedStyle_isFlaggedByIsWired() {
        let unwiredSource = """
            public struct ToolInvocationView: View {
                public var body: some View {
                    ResolvedToolInvocation(
                        style: PlainToolInvocationStyle(),
                        configuration: configuration
                    )
                }
            }
            """
        XCTAssertFalse(
            Self.isWired(source: unwiredSource, environmentKeyPath: "toolInvocationStyle", resolvedWrapperCall: "ResolvedToolInvocation"),
            "A hardcoded style with no @Environment read must be flagged as unwired"
        )

        // Also cover the other failure shape: reads the environment but never
        // forwards it into the resolved wrapper (e.g. a copy/paste that
        // dropped the `style: style,` argument).
        let readsButDoesNotForwardSource = """
            public struct ToolInvocationView: View {
                @Environment(\\.toolInvocationStyle) private var style
                public var body: some View {
                    ResolvedToolInvocation(
                        style: PlainToolInvocationStyle(),
                        configuration: configuration
                    )
                }
            }
            """
        XCTAssertFalse(
            Self.isWired(source: readsButDoesNotForwardSource, environmentKeyPath: "toolInvocationStyle", resolvedWrapperCall: "ResolvedToolInvocation"),
            "Reading the environment style but not forwarding it into the resolved wrapper must also be flagged"
        )

        // Sabotage-direction check: the real wired shape must pass.
        let wiredSource = """
            public struct ToolInvocationView: View {
                @Environment(\\.toolInvocationStyle) private var style
                public var body: some View {
                    ResolvedToolInvocation(
                        style: style,
                        configuration: configuration
                    )
                }
            }
            """
        XCTAssertTrue(
            Self.isWired(source: wiredSource, environmentKeyPath: "toolInvocationStyle", resolvedWrapperCall: "ResolvedToolInvocation"),
            "The real wired shape must NOT be flagged — confirms the predicate isn't trivially always-false"
        )
    }

    /// Sabotage coverage for ``isPartRendererWired(source:)``, mirroring
    /// ``test_sabotage_unwiredHardcodedStyle_isFlaggedByIsWired``'s three
    /// shapes (no environment read; reads but never forwards the
    /// fallthrough; the real wired shape) for the part-renderer's distinct
    /// three-part check.
    func test_sabotage_unwiredPartRenderer_isFlaggedByIsPartRendererWired() {
        let noEnvironmentReadSource = """
            struct MessagePartsView: View {
                private func partView(for part: MessagePart) -> some View {
                    defaultPartView(for: part)
                }
                private func defaultPartView(for part: MessagePart) -> some View {
                    switch part { default: EmptyView() }
                }
            }
            """
        XCTAssertFalse(
            Self.isPartRendererWired(source: noEnvironmentReadSource),
            "A view with no @Environment(\\.chatMessagePartRenderer) read must be flagged as unwired"
        )

        let readsButNeverForwardsSource = """
            struct MessagePartsView: View {
                @Environment(\\.chatMessagePartRenderer) private var partRenderer
                private func partView(for part: MessagePart) -> some View {
                    defaultPartView(for: part)
                }
                private func defaultPartView(for part: MessagePart) -> some View {
                    switch part { default: EmptyView() }
                }
            }
            """
        XCTAssertFalse(
            Self.isPartRendererWired(source: readsButNeverForwardsSource),
            "Reading the renderer but never calling it with a defaultView fallthrough must also be flagged"
        )

        let noFallthroughDispatchSource = """
            struct MessagePartsView: View {
                @Environment(\\.chatMessagePartRenderer) private var partRenderer
                private func partView(for part: MessagePart) -> some View {
                    if let partRenderer {
                        partRenderer(
                            ChatMessagePartRenderParameters(
                                part: part,
                                role: role,
                                isStreaming: isStreaming,
                                defaultView: { AnyView(defaultPartView(for: part)) }
                            )
                        )
                    } else {
                        EmptyView()
                    }
                }
            }
            """
        XCTAssertFalse(
            Self.isPartRendererWired(source: noFallthroughDispatchSource),
            "A view whose no-renderer-installed branch never calls its own per-kind dispatch must be flagged"
        )

        let wiredSource = """
            struct MessagePartsView: View {
                @Environment(\\.chatMessagePartRenderer) private var partRenderer
                private func partView(for part: MessagePart) -> some View {
                    if let partRenderer {
                        partRenderer(
                            ChatMessagePartRenderParameters(
                                part: part,
                                role: role,
                                isStreaming: isStreaming,
                                defaultView: { AnyView(defaultPartView(for: part)) }
                            )
                        )
                    } else {
                        defaultPartView(for: part)
                    }
                }
            }
            """
        XCTAssertTrue(
            Self.isPartRendererWired(source: wiredSource),
            "The real wired shape must NOT be flagged — confirms the predicate isn't trivially always-false"
        )
    }

    // MARK: - Helpers

    private static func sourceText(relativeToManifoldUI relativePath: String, filePath: StaticString = #filePath) throws -> String {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Sources/ManifoldUI").appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "StyleWiringAuditTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Sources/ManifoldUI/\(relativePath) from #filePath"
        ])
    }
}
