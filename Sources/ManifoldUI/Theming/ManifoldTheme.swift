import SwiftUI
import ManifoldInference

/// The token root for the 2026 UI refresh (issue #2307, `docs/UI-REFRESH-2026.md` §7).
///
/// `ManifoldTheme` follows a Material-3-style three-tier model — primitive →
/// semantic → component, where component code may only reference the semantic
/// tier below. This type carries the semantic tier. It embeds the existing
/// ``ChatTheme`` (bubble tokens) **unchanged**: nothing about bubble theming
/// changes shape in Unit 1, this type just gives every *other* themeable
/// surface (status dots, badges, composer chrome, surfaces/inks) the same
/// environment-injected-token treatment ``ChatTheme`` already gives bubbles.
///
/// `package` access in Unit 1 — publicized (with DocC) once the migration
/// tranches (`T1-migrate-ui`/`-mmgmt`/`-voice`) have routed the ~65 literal
/// call sites through it and the built-in styles exist to consume it (Unit 2
/// §L2). Shipping it `package`-only here means zero new public surface lands
/// before there's anything for a consumer to theme.
///
/// ``ManifoldTheme/standard`` reproduces every literal this refactor replaces,
/// byte-for-byte — that's what `DefaultAppearanceCharacterizationTests` locks.
public struct ManifoldTheme: Sendable {

    // MARK: - Bubble tokens (embedded, unchanged)

    /// The embedded ``ChatTheme``. `.chatTheme(_:)` (declared on `ChatTheme.swift`)
    /// keeps working standalone — it only ever wrote `\.chatTheme` into the
    /// environment, and still does. `.manifoldTheme(_:)` below writes *both*
    /// `\.manifoldTheme` and `\.chatTheme` from this embedded value, so a
    /// consumer who only ever reads `\.chatTheme` (pre-refresh call sites) still
    /// sees a theme that's consistent with whatever `ManifoldTheme` was applied.
    package var chatTheme: ChatTheme

    // MARK: - Semantic tiers (spec §7)

    /// Resolves to the host app's `Color.accentColor` — **never a literal**, so
    /// consumers keep their brand tint for free. Default: `Color.accentColor`.
    package var accent: AnyShapeStyle

    /// The chat surface's base fill (behind everything). Default: `Color.clear`
    /// — today nothing paints a dedicated "ground" layer; the system background
    /// shows through, which this default reproduces exactly.
    package var ground: AnyShapeStyle

    /// Primary elevated-surface fill (cards, rows, the composer field).
    /// Default: `.fill.tertiary` — the token `ChatInputBar.swift:61` and
    /// `ToolInvocationView.swift:135` currently spell as a literal.
    package var surface: AnyShapeStyle

    /// Secondary elevated-surface fill, one step lighter than ``surface``.
    /// Default: `.fill.quaternary`.
    package var surface2: AnyShapeStyle

    /// Primary text/icon ink. Default: `.primary`.
    package var ink: AnyShapeStyle

    /// Secondary ink (captions, metadata). Default: `.secondary`.
    package var ink2: AnyShapeStyle

    /// Tertiary ink (the most de-emphasized readable tier). Default: `.tertiary`.
    package var ink3: AnyShapeStyle

    /// "Nominal / compatible / succeeded" status color. Default: `Color.green`
    /// — the literal every `.green` status site in `Sources/ManifoldUI` and
    /// `Sources/ManifoldUIModelManagement` migrates from.
    package var statusOK: AnyShapeStyle

    /// `statusOK` at reduced opacity, for soft/pill fills. Default:
    /// `Color.green.opacity(0.15)` — the tint ratio already used at
    /// `ToolInvocationView.swift:237`.
    package var statusOKSoft: AnyShapeStyle

    /// "Borderline / degraded" status color. Default: `Color.yellow`.
    package var statusWarn: AnyShapeStyle

    /// `statusWarn` at reduced opacity. Default: `Color.yellow.opacity(0.15)`.
    package var statusWarnSoft: AnyShapeStyle

    /// "Failed / incompatible / critical" status color. Default: `Color.red` —
    /// matches the memory/context indicators' `.critical`/`>= 0.95` literal.
    /// Note: `ToolInvocationView`'s failure card currently uses `.orange`
    /// (`:229`), not `.red` — that call site is a distinct semantic choice
    /// ("recoverable tool failure" reads as a warning, not a hard error) that
    /// the migration tranche maps to `statusWarn`, not `statusError`. This
    /// default does not paper over that distinction.
    package var statusError: AnyShapeStyle

    /// `statusError` at reduced opacity. Default: `Color.red.opacity(0.15)`.
    package var statusErrorSoft: AnyShapeStyle

    /// `Color`-typed sibling of ``statusOK``/``statusWarn``/``statusError``.
    ///
    /// Exists because `ViewInspector` 0.10.x (`Package.swift`) can resolve a
    /// rendered `.foregroundStyle(_:)`/`.fill(_:)` modifier's argument back to
    /// a concrete value only when the argument's *static type* is `Color` —
    /// `foregroundStyleShapeStyle(Color.self)` / `fillShapeStyle(Color.self)`
    /// look up the modifier by its generic parameter name
    /// (`_ForegroundStyleModifier<Color>`), so a call site typed
    /// `AnyShapeStyle` (the ``statusOK``-family tokens) renders identically
    /// but is invisible to that extraction — confirmed live: migrating
    /// `ToolInvocationView.swift:183`, `MemoryIndicatorView.swift:32-34`, and
    /// `ContextIndicatorView.swift:26-28` onto the `AnyShapeStyle` tokens
    /// failed `DefaultAppearanceCharacterizationTests` despite zero visual
    /// change, because the characterization test can no longer extract the
    /// rendered color at all (see that file's class doc comment).
    ///
    /// Migration sites that need a plain, ViewInspector-inspectable `Color`
    /// (a `.foregroundStyle(_:)`/`.fill(_:)`/`.tint(_:)` argument, not a
    /// `.background(_:in:)` composite) should read `statusOKColor` instead of
    /// `statusOK`. Both resolve to the same historical literal — this is a
    /// typed *view* onto the same semantic decision, not a second token.
    package var statusOKColor: Color

    /// See ``statusOKColor``. Default: `Color.yellow`.
    package var statusWarnColor: Color

    /// See ``statusOKColor``. Default: `Color.red`.
    package var statusErrorColor: Color

    /// Material reference for translucent chrome. Plain `.regularMaterial` in
    /// Unit 1 — the per-OS `glassEffect`/`GlassEffectContainer` resolution
    /// (`#available(iOS 26, macOS 26, *)`) is a Unit 2 §L1 addition (spec §9).
    package var glass: Material

    /// The corner-radius scale (xs 6 · sm 11 · md 14 · lg 20 · capsule),
    /// `@ScaledMetric`-consumed at the call site like ``ChatTheme/cornerRadius``
    /// is today.
    package var shape: ManifoldThemeShapeScale

    /// HIG text-style roles. Dynamic Type keeps working because these are text
    /// styles (`.body`/`.caption`/…), not point sizes — same contract as
    /// ``ChatTheme/bubbleFont``/``ChatTheme/metadataFont``.
    package var type: ManifoldThemeTypeScale

    /// Creates a theme. Every parameter defaults to the framework's historical
    /// value, so `ManifoldTheme()` (and ``standard``) reproduce today's
    /// appearance exactly — the zero-visual-change guarantee this unit ships.
    package init(
        chatTheme: ChatTheme = .standard,
        accent: AnyShapeStyle = AnyShapeStyle(Color.accentColor),
        ground: AnyShapeStyle = AnyShapeStyle(Color.clear),
        surface: AnyShapeStyle = AnyShapeStyle(.fill.tertiary),
        surface2: AnyShapeStyle = AnyShapeStyle(.fill.quaternary),
        ink: AnyShapeStyle = AnyShapeStyle(.primary),
        ink2: AnyShapeStyle = AnyShapeStyle(.secondary),
        ink3: AnyShapeStyle = AnyShapeStyle(.tertiary),
        statusOK: AnyShapeStyle = AnyShapeStyle(Color.green),
        statusOKSoft: AnyShapeStyle = AnyShapeStyle(Color.green.opacity(0.15)),
        statusWarn: AnyShapeStyle = AnyShapeStyle(Color.yellow),
        statusWarnSoft: AnyShapeStyle = AnyShapeStyle(Color.yellow.opacity(0.15)),
        statusError: AnyShapeStyle = AnyShapeStyle(Color.red),
        statusErrorSoft: AnyShapeStyle = AnyShapeStyle(Color.red.opacity(0.15)),
        statusOKColor: Color = .green,
        statusWarnColor: Color = .yellow,
        statusErrorColor: Color = .red,
        glass: Material = .regularMaterial,
        shape: ManifoldThemeShapeScale = ManifoldThemeShapeScale(),
        type: ManifoldThemeTypeScale = ManifoldThemeTypeScale()
    ) {
        self.chatTheme = chatTheme
        self.accent = accent
        self.ground = ground
        self.surface = surface
        self.surface2 = surface2
        self.ink = ink
        self.ink2 = ink2
        self.ink3 = ink3
        self.statusOK = statusOK
        self.statusOKSoft = statusOKSoft
        self.statusWarn = statusWarn
        self.statusWarnSoft = statusWarnSoft
        self.statusError = statusError
        self.statusErrorSoft = statusErrorSoft
        self.statusOKColor = statusOKColor
        self.statusWarnColor = statusWarnColor
        self.statusErrorColor = statusErrorColor
        self.glass = glass
        self.shape = shape
        self.type = type
    }

    /// The framework default — reproduces the pre-theming appearance exactly.
    package static let standard = ManifoldTheme()
}

/// Corner-radius scale token (spec §7): xs 6 · sm 11 · md 14 · lg 20 · capsule.
/// Nested radii are meant to be derived concentrically by component code
/// (outer radius − padding = inner radius), not stored redundantly here.
package struct ManifoldThemeShapeScale: Sendable {
    package var xs: CGFloat
    package var sm: CGFloat
    package var md: CGFloat
    package var lg: CGFloat

    package init(xs: CGFloat = 6, sm: CGFloat = 11, md: CGFloat = 14, lg: CGFloat = 20) {
        self.xs = xs
        self.sm = sm
        self.md = md
        self.lg = lg
    }
}

/// HIG text-style roles consumed by component code. Kept intentionally small
/// in Unit 1 — the full role set grows as Unit 2's style protocols land.
package struct ManifoldThemeTypeScale: Sendable {
    /// Section/sheet titles. Default: `.headline`.
    package var title: Font
    /// Primary body copy. Default: `.body` — matches ``ChatTheme/bubbleFont``.
    package var body: Font
    /// Secondary metadata. Default: `.caption` — matches ``ChatTheme/metadataFont``.
    package var caption: Font
    /// Tertiary/badge copy. Default: `.caption2`.
    package var caption2: Font

    package init(
        title: Font = .headline,
        body: Font = .body,
        caption: Font = .caption,
        caption2: Font = .caption2
    ) {
        self.title = title
        self.body = body
        self.caption = caption
        self.caption2 = caption2
    }
}

// MARK: - Environment injection

package extension EnvironmentValues {
    /// The active theme root. Defaults to ``ManifoldTheme/standard`` so
    /// untouched views render with the historical appearance.
    @Entry var manifoldTheme: ManifoldTheme = .standard
}

package extension View {
    /// Applies a ``ManifoldTheme`` to this view and everything below it,
    /// including content presented in `.sheet`/`.fullScreenCover` from inside
    /// the subtree. Mirrors `.chatTheme(_:)`'s cascading-modifier shape.
    ///
    /// Writes through to `\.chatTheme` as well as `\.manifoldTheme`, so call
    /// sites that only read the legacy `\.chatTheme` key (every bubble today)
    /// see a theme consistent with the one just applied here.
    func manifoldTheme(_ theme: ManifoldTheme) -> some View {
        environment(\.manifoldTheme, theme)
            .environment(\.chatTheme, theme.chatTheme)
    }
}

// MARK: - Per-OS glass resolution (Unit 2 §L1, spec §9)

/// Which glass rendering path a surface should use — resolved once per call
/// site so the two branches are independently testable without depending on
/// the CI host's actual OS version.
///
/// Native Liquid Glass (`glassEffect`/`GlassEffectContainer`) requires iOS 26
/// / macOS 26; below that floor every surface falls back to
/// ``ManifoldTheme/glass`` (`.regularMaterial` by default). The floor itself
/// stays iOS 18 / macOS 15 (`docs/UI-REFRESH-2026.md` §9) — this resolution is
/// purely which *rendering path* a supported OS gets, never a gate on
/// whether the surface renders at all.
package enum ManifoldGlassResolution: Sendable, Equatable {
    /// Native Liquid Glass is available and should be used.
    case liquidGlass
    /// Fall back to ``ManifoldTheme/glass``.
    case material

    /// Pure, `#available`-free resolution so both branches are directly
    /// unit-testable regardless of the CI host's actual OS version — mirrors
    /// the Reduce-Motion static-helper pattern used for
    /// `TypingIndicatorView`/`StreamingCursorView`
    /// (`StreamingIndicatorReduceMotionTests`).
    package static func resolve(supportsLiquidGlass: Bool) -> ManifoldGlassResolution {
        supportsLiquidGlass ? .liquidGlass : .material
    }

    /// The live resolution for the OS this code is actually running on.
    package static var current: ManifoldGlassResolution {
        if #available(iOS 26, macOS 26, *) {
            resolve(supportsLiquidGlass: true)
        } else {
            resolve(supportsLiquidGlass: false)
        }
    }
}

package extension View {
    /// Applies the theme's glass surface to this view: native `glassEffect`
    /// on iOS 26 / macOS 26+, ``ManifoldTheme/glass`` (`.regularMaterial` by
    /// default) below (`docs/UI-REFRESH-2026.md` §9, "OS fallback matrix").
    ///
    /// `shape` is a concrete `Shape` generic (not an existential), so this
    /// stays `@ViewBuilder`-safe across both branches — callers pass
    /// `Capsule()`, `Circle()`, `RoundedRectangle(cornerRadius:)`, etc.
    @ViewBuilder
    func manifoldGlass<S: Shape>(_ theme: ManifoldTheme, in shape: S) -> some View {
        if #available(iOS 26, macOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(theme.glass, in: shape)
        }
    }

    /// Groups multiple ``manifoldGlass(_:in:)`` surfaces so 26+ can morph
    /// between them as one `GlassEffectContainer` (e.g. the composer +
    /// scroll-to-bottom control sharing one glass surface as it appears).
    /// Below 26 this is a transparent passthrough — there is no equivalent
    /// grouping primitive pre-26, and each surface already renders its own
    /// independent material background via ``manifoldGlass(_:in:)``.
    @ViewBuilder
    func manifoldGlassEffectContainer() -> some View {
        if #available(iOS 26, macOS 26, *) {
            GlassEffectContainer { self }
        } else {
            self
        }
    }
}
