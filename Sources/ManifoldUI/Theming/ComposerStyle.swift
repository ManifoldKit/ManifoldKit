import SwiftUI
import ManifoldInference

/// Which lifecycle phase the composer is in (spec §3, §8).
///
/// The phase drives the send/stop morph and which accessory band renders
/// above the field; it is data owned by the composer's view model, not the
/// style — the style only ever reads it to decide chrome (Principle 3,
/// "state is data, styling decides").
public enum ComposerPhase: Sendable, Equatable {
    /// No draft text, no attachments, not generating.
    case idle
    /// The user is actively drafting (has text and/or attachments).
    case composing
    /// A turn is in flight — the send affordance morphs to stop.
    case generating
    /// The voice accessory panel is open above the capsule/bar.
    case voice
}

/// The inputs handed to a ``ComposerStyle`` when it draws the composer's
/// chrome (capsule/bar background, shape, padding).
///
/// Narrower than ``MessageBubbleConfiguration``'s split, not an exact mirror
/// of it: a bubble style's `content` is the message's *entire* rich inner
/// content (parts, agent badge, timestamp, streaming cursor) with only the
/// container chrome pulled out, whereas ``content`` here is the text-entry
/// field alone. ``affordances`` — the "+" menu, regenerate, and send/stop
/// controls — is a distinct type-erased slot (Unit 2 §L3, issue #2307) so a
/// style can choose whether to enclose it with ``content`` in one container
/// (the glass capsule, spec §3) or leave it a visual sibling outside the
/// styled field (the classic look, spec §8's `.plain` preset). The
/// draft-attachment strip and quick-action pills stay outside this
/// configuration entirely — they render in `ChatInputBar`'s accessory band
/// above the styled composer, never inside it.
public struct ComposerConfiguration {

    /// The text-entry field, type-erased so a style does not need to know
    /// about focus state, disabled-state gating, or the placeholder text
    /// `ChatInputBar` computes. Does **not** include the "+" menu, send/stop
    /// button, or attachment strip — see this type's doc comment.
    public let content: AnyView

    /// The "+" menu / regenerate / send-stop affordances, type-erased. A
    /// style decides whether these sit inside the same container as
    /// ``content`` (``GlassComposerStyle``'s one capsule) or beside it as an
    /// independent sibling (``PlainComposerStyle``'s classic layout).
    /// Defaults to an empty view so existing direct-construction call sites
    /// (dispatch-matrix tests predating this field) keep compiling.
    public let affordances: AnyView

    /// The current lifecycle phase. Styles typically use this to switch
    /// container geometry (e.g. a taller accessory band while `.voice`).
    public let phase: ComposerPhase

    /// `true` when the draft-attachment strip has at least one attachment.
    /// Styles may use this to reserve space for the accessory band above the
    /// field without the strip's content leaking into the style layer.
    public let hasAttachments: Bool

    public init(
        content: AnyView,
        affordances: AnyView = AnyView(EmptyView()),
        phase: ComposerPhase,
        hasAttachments: Bool
    ) {
        self.content = content
        self.affordances = affordances
        self.phase = phase
        self.hasAttachments = hasAttachments
    }
}

/// A type that draws the chrome around the chat composer.
///
/// Follows the same recipe as ``MessageBubbleStyle``: implement
/// ``makeBody(configuration:)`` to wrap `configuration.content` (and, since
/// Unit 2 §L3, `configuration.affordances`) in your own background/shape/
/// padding, install it with `.composerStyle(_:)`, and read `@Environment`
/// (color scheme, the active ``ManifoldTheme``) from inside the returned
/// `Body` view.
///
/// **Live** (issue #2307, Unit 2 §L3): `ChatInputBar` reads `\.composerStyle`
/// and dispatches through ``ResolvedComposer`` — see
/// `StyleWiringAuditTest`'s composer wiring assertion.
///
/// `Sendable` because the resolved style is carried through the SwiftUI
/// environment.
public protocol ComposerStyle: Sendable {
    associatedtype Body: View
    typealias Configuration = ComposerConfiguration

    /// Produces the styled composer for the given configuration.
    ///
    /// `@MainActor` because composers are only ever built during SwiftUI
    /// render (the configuration carries a non-`Sendable` `AnyView`); the
    /// style type itself stays `Sendable` so it can be carried through the
    /// environment.
    @MainActor @ViewBuilder func makeBody(configuration: Configuration) -> Body
}

// MARK: - Built-in styles

/// The default style: reproduces the framework's historical composer layout
/// — `ChatInputBar`'s `HStack(alignment: .bottom, spacing: 8) { field;
/// actionButtons }`, with the field alone wrapped in `.padding(10).background(
/// .fill.tertiary, in: RoundedRectangle(cornerRadius: 12))` — by reading
/// `ManifoldTheme.surface` (default `AnyShapeStyle(.fill.tertiary)`, the same
/// literal) instead of the hardcoded material. The corner radius stays the
/// literal `12`, not a ``ManifoldThemeShapeScale`` token (`sm` is 11, `md` is
/// 14 — neither equals 12), so this reproduces the historical chrome
/// byte-for-byte rather than silently drifting it onto the nearest scale
/// step. ``ComposerConfiguration/affordances`` renders as an unstyled sibling
/// beside the field — never enclosed in the field's own background — exactly
/// matching the classic layout.
///
/// This is the `.classic` preset since Unit 2 §L5's defaults flip (issue
/// #2307) — the new-look glass capsule/bar (``GlassComposerStyle``, spec §3)
/// is the built-in default now.
public struct PlainComposerStyle: ComposerStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        PlainComposerBody(configuration: configuration)
    }
}

private struct PlainComposerBody: View {
    let configuration: ComposerConfiguration

    @Environment(\.manifoldTheme) private var theme

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            configuration.content
                .padding(10)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
            configuration.affordances
        }
    }
}

/// A **new-look** style implementing the spec's floating glass capsule (iOS)
/// / docked glass bar (macOS) geometry (spec §3): field and ``ComposerConfiguration/affordances``
/// share one enclosing glass container, so the "+" menu / send-stop controls
/// read as part of the same capsule rather than free-floating siblings. The
/// built-in default since Unit 2 §L5's defaults flip (issue #2307) — apply
/// `.composerStyle(.plain)` (or `View.classicManifoldTheme()`) to restore the
/// pre-refresh layout.
public struct GlassComposerStyle: ComposerStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        GlassComposerBody(configuration: configuration)
    }
}

private struct GlassComposerBody: View {
    let configuration: ComposerConfiguration

    @Environment(\.manifoldTheme) private var theme

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            configuration.content
            configuration.affordances
        }
        .padding(10)
        .manifoldGlass(theme, in: Capsule(style: .continuous))
    }
}

// MARK: - Static accessors

public extension ComposerStyle where Self == PlainComposerStyle {
    /// The default theme-driven composer chrome. `.composerStyle(.plain)`.
    static var plain: PlainComposerStyle { .init() }
}

public extension ComposerStyle where Self == GlassComposerStyle {
    /// The 2026 refresh's glass capsule/bar. `.composerStyle(.glass)`.
    static var glass: GlassComposerStyle { .init() }
}

// MARK: - Environment injection

public extension EnvironmentValues {
    /// The active composer style. Defaults to ``GlassComposerStyle`` since
    /// Unit 2 §L5's defaults flip (issue #2307) — the framework's built-in
    /// look is now the glass capsule/bar. Apply `.composerStyle(.plain)` (or
    /// `View.classicManifoldTheme()`) to restore the pre-refresh layout.
    @Entry var composerStyle: any ComposerStyle = GlassComposerStyle()
}

public extension View {
    /// Sets the ``ComposerStyle`` for the chat composer in this view and below.
    ///
    /// Cascades through the environment like `.messageBubbleStyle(_:)`:
    ///
    /// ```swift
    /// ChatView(showModelManagement: $show)
    ///     .composerStyle(.glass)
    /// ```
    func composerStyle<S: ComposerStyle>(_ style: S) -> some View {
        environment(\.composerStyle, style)
    }
}

// MARK: - Resolution

/// Applies an existential ``ComposerStyle`` to a configuration. See
/// ``ResolvedMessageBubble``'s doc comment for the type-erasure rationale —
/// this mirrors it exactly.
struct ResolvedComposer: View {
    let style: any ComposerStyle
    let configuration: ComposerConfiguration

    var body: some View {
        AnyView(style.makeBody(configuration: configuration))
    }
}
