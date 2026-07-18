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
