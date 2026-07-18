import SwiftUI

/// The reasoning-disclosure lifecycle (spec §4A, §8) — exactly three states:
///
/// - ``streaming``: reasoning is still arriving; the built-in style shows a
///   one-line live preview (the batcher's latest flushed text).
/// - ``settled(duration:)``: reasoning finished; collapsed by default,
///   showing how long the model thought.
/// - ``expanded(duration:)``: the user disclosed the block; the full trace
///   renders behind a hairline rule, always quieter than the answer.
///
/// `duration` is best-effort wall-clock time between the first and last
/// `.thinkingToken`/`.thinkingCompleted` events for this block, tracked by
/// the call site (`ThinkingBlockView`) — no duration-measurement plumbing
/// exists in `ManifoldInference`/`ManifoldRuntime` today, so a block whose
/// streaming start was never observed (e.g. a persisted message loaded
/// already-settled from history) reports `0`. Styles that show a duration
/// should treat `0` as "unknown", not "instant".
public enum ThinkingBlockState: Sendable, Equatable {
    case streaming
    case settled(duration: TimeInterval)
    case expanded(duration: TimeInterval)
}

/// The inputs handed to a ``ThinkingBlockStyle`` when it draws one reasoning
/// disclosure.
///
/// Mirrors ``MessageBubbleConfiguration``'s data-only shape: the style reads
/// `state`/`text` and decides visuals; toggling between ``ThinkingBlockState/settled(duration:)``
/// and ``ThinkingBlockState/expanded(duration:)`` is driven by calling
/// ``toggleExpanded``, which the call site wires to its own `@State`
/// (mirrors `DisclosureGroup`'s binding-owns-the-state shape — the
/// configuration is a snapshot, not a live binding).
public struct ThinkingBlockConfiguration {

    /// The lifecycle state to render.
    public let state: ThinkingBlockState

    /// The reasoning text: the batcher's latest partial flush while
    /// ``ThinkingBlockState/streaming``, the full accumulated trace once
    /// settled or expanded.
    public let text: String

    /// Call to toggle between ``ThinkingBlockState/settled(duration:)`` and
    /// ``ThinkingBlockState/expanded(duration:)``. A no-op while
    /// ``ThinkingBlockState/streaming`` — the disclosure only becomes
    /// interactive once reasoning has finished arriving, matching today's
    /// behavior (the streaming branch already renders its own
    /// `DisclosureGroup` with a live inline preview, not a toggle-to-expand
    /// affordance).
    public let toggleExpanded: () -> Void

    public init(state: ThinkingBlockState, text: String, toggleExpanded: @escaping () -> Void) {
        self.state = state
        self.text = text
        self.toggleExpanded = toggleExpanded
    }
}

/// A type that draws a reasoning (thinking-block) disclosure.
///
/// Follows the same recipe as ``MessageBubbleStyle``: implement
/// ``makeBody(configuration:)``, install with `.thinkingBlockStyle(_:)`, read
/// `@Environment` from inside the returned `Body`.
public protocol ThinkingBlockStyle: Sendable {
    associatedtype Body: View
    typealias Configuration = ThinkingBlockConfiguration

    @MainActor @ViewBuilder func makeBody(configuration: Configuration) -> Body
}

// MARK: - Built-in styles

/// The default style: reproduces `ThinkingBlockView`'s historical chrome —
/// "Thinking… <preview>" while streaming, a collapsed "Reasoning" disclosure
/// once settled, unchanged whether or not `duration` is known (this style
/// never renders it, matching today's UI having no duration display at all).
/// This is the `.classic` preset since Unit 2 §L5's defaults flip (issue
/// #2307) — ``ShimmerThinkingBlockStyle`` is the built-in default now.
public struct PlainThinkingBlockStyle: ThinkingBlockStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        PlainThinkingBlockBody(configuration: configuration)
    }
}

private struct PlainThinkingBlockBody: View {
    let configuration: ThinkingBlockConfiguration

    private var isExpandedBinding: Binding<Bool> {
        Binding(
            get: {
                if case .expanded = configuration.state { return true }
                return false
            },
            set: { _ in configuration.toggleExpanded() }
        )
    }

    private var inlinePreview: String {
        let trimmed = configuration.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lastLine = trimmed.split(whereSeparator: \.isNewline).last.map(String.init) ?? trimmed
        return String(lastLine.suffix(80))
    }

    var body: some View {
        switch configuration.state {
        case .streaming:
            // Not user-interactive (see `toggleExpanded`'s doc comment) — a
            // fixed-closed disclosure group whose label carries the live
            // preview. This is a deliberate, documented behavior change from
            // the pre-refresh view, which let a user expand/collapse even
            // while streaming: the spec's 3-state `ThinkingBlockState` model
            // has no "streaming+expanded" case (see that type's doc comment),
            // so this style can no longer honor a manual expand during
            // streaming. Accepted for this tranche; flagged in the PR body
            // for Unit 2 §L5's migration note.
            DisclosureGroup(isExpanded: .constant(false)) {
                Text(configuration.text.isEmpty ? " " : configuration.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            } label: {
                HStack(spacing: 6) {
                    Label("Thinking…", systemImage: "brain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !inlinePreview.isEmpty {
                        Text(inlinePreview)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .accessibilityHidden(true)
                    }
                }
            }
            .accessibilityLabel("Reasoning in progress")

        case .settled, .expanded:
            DisclosureGroup(isExpanded: isExpandedBinding) {
                Text(configuration.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            } label: {
                Label("Reasoning", systemImage: "brain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Reasoning")
            .accessibilityHint(isExpandedBinding.wrappedValue ? "Double-tap to collapse." : "Double-tap to expand.")
        }
    }
}

/// A **new-look** style implementing the spec's shimmer-preview →
/// "Thought for Ns" → hairline-rule-trace lifecycle (spec §4A). The built-in
/// default since Unit 2 §L5's defaults flip (issue #2307) — apply
/// `.thinkingBlockStyle(.plain)` (or `View.classicManifoldTheme()`) to
/// restore the pre-refresh disclosure.
public struct ShimmerThinkingBlockStyle: ThinkingBlockStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        ShimmerThinkingBlockBody(configuration: configuration)
    }
}

private struct ShimmerThinkingBlockBody: View {
    let configuration: ThinkingBlockConfiguration

    @Environment(\.manifoldTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isExpandedBinding: Binding<Bool> {
        Binding(
            get: {
                if case .expanded = configuration.state { return true }
                return false
            },
            set: { _ in configuration.toggleExpanded() }
        )
    }

    private func durationLabel(_ duration: TimeInterval) -> String {
        guard duration > 0 else { return "Thought" }
        let seconds = Int(duration.rounded())
        return "Thought for \(seconds)s"
    }

    var body: some View {
        switch configuration.state {
        case .streaming:
            Text(configuration.text.isEmpty ? "Thinking…" : configuration.text)
                .font(theme.type.caption)
                .foregroundStyle(theme.ink2)
                .lineLimit(1)
                // Shimmer/live states are identical across OS versions but
                // static under Reduce Motion (spec §9).
                .opacity(reduceMotion ? 1 : 0.85)

        case .settled(let duration):
            DisclosureGroup(isExpanded: isExpandedBinding) {
                EmptyView()
            } label: {
                Text(durationLabel(duration))
                    .font(theme.type.caption)
                    .foregroundStyle(theme.ink2)
            }

        case .expanded(let duration):
            VStack(alignment: .leading, spacing: 4) {
                Text(durationLabel(duration))
                    .font(theme.type.caption)
                    .foregroundStyle(theme.ink2)
                Divider()
                Text(configuration.text)
                    .font(theme.type.caption2)
                    .foregroundStyle(theme.ink3)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Static accessors

public extension ThinkingBlockStyle where Self == PlainThinkingBlockStyle {
    /// The default theme-driven reasoning disclosure. `.thinkingBlockStyle(.plain)`.
    static var plain: PlainThinkingBlockStyle { .init() }
}

public extension ThinkingBlockStyle where Self == ShimmerThinkingBlockStyle {
    /// The 2026 refresh's shimmer/settle/expand disclosure. `.thinkingBlockStyle(.shimmer)`.
    static var shimmer: ShimmerThinkingBlockStyle { .init() }
}

// MARK: - Environment injection

public extension EnvironmentValues {
    /// The active thinking-block style. Defaults to ``ShimmerThinkingBlockStyle``
    /// since Unit 2 §L5's defaults flip (issue #2307). Apply
    /// `.thinkingBlockStyle(.plain)` (or `View.classicManifoldTheme()`) to
    /// restore the pre-refresh disclosure.
    @Entry var thinkingBlockStyle: any ThinkingBlockStyle = ShimmerThinkingBlockStyle()
}

public extension View {
    /// Sets the ``ThinkingBlockStyle`` for reasoning disclosures in this view
    /// and below.
    ///
    /// ```swift
    /// ChatView(showModelManagement: $show)
    ///     .thinkingBlockStyle(.shimmer)
    /// ```
    func thinkingBlockStyle<S: ThinkingBlockStyle>(_ style: S) -> some View {
        environment(\.thinkingBlockStyle, style)
    }
}

// MARK: - Resolution

/// Applies an existential ``ThinkingBlockStyle`` to a configuration. See
/// ``ResolvedMessageBubble``'s doc comment for the type-erasure rationale.
struct ResolvedThinkingBlock: View {
    let style: any ThinkingBlockStyle
    let configuration: ThinkingBlockConfiguration

    var body: some View {
        AnyView(style.makeBody(configuration: configuration))
    }
}
