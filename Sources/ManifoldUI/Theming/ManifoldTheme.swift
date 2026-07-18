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
/// Publicized in Unit 2 §L2 (issue #2307): the migration tranches routed the
/// ~65 literal call sites through it in Unit 1, and the style protocols this
/// tranche adds are the first consumers that need to *construct* a custom
/// `ManifoldTheme`, not just read the default. Public surface here is
/// intentionally just this type and its nested token structs — component
/// call sites, the glass-resolution helpers, and everything else stay
/// `package`.
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
    public var chatTheme: ChatTheme

    // MARK: - Semantic tiers (spec §7)

    /// Resolves to the host app's `Color.accentColor` — **never a literal**, so
    /// consumers keep their brand tint for free. Default: `Color.accentColor`.
    public var accent: AnyShapeStyle

    /// The chat surface's base fill (behind everything). Default: `Color.clear`
    /// — today nothing paints a dedicated "ground" layer; the system background
    /// shows through, which this default reproduces exactly.
    public var ground: AnyShapeStyle

    /// Primary elevated-surface fill (cards, rows, the composer field).
    /// Default: `.fill.tertiary` — the token `ChatInputBar.swift:61` and
    /// `ToolInvocationView.swift:135` currently spell as a literal.
    public var surface: AnyShapeStyle

    /// Secondary elevated-surface fill, one step lighter than ``surface``.
    /// Default: `.fill.quaternary`.
    public var surface2: AnyShapeStyle

    /// Primary text/icon ink. Default: `.primary`.
    public var ink: AnyShapeStyle

    /// Secondary ink (captions, metadata). Default: `.secondary`.
    public var ink2: AnyShapeStyle

    /// Tertiary ink (the most de-emphasized readable tier). Default: `.tertiary`.
    public var ink3: AnyShapeStyle

    /// "Nominal / compatible / succeeded" status color. Default: `Color.green`
    /// — the literal every `.green` status site in `Sources/ManifoldUI` and
    /// `Sources/ManifoldUIModelManagement` migrates from.
    public var statusOK: AnyShapeStyle

    /// `statusOK` at reduced opacity, for soft/pill fills. Default:
    /// `Color.green.opacity(0.15)` — the tint ratio already used at
    /// `ToolInvocationView.swift:237`.
    public var statusOKSoft: AnyShapeStyle

    /// "Borderline / degraded" status color. Default: `Color.yellow`.
    public var statusWarn: AnyShapeStyle

    /// `statusWarn` at reduced opacity. Default: `Color.yellow.opacity(0.15)`.
    public var statusWarnSoft: AnyShapeStyle

    /// "Failed / incompatible / critical" status color. Default: `Color.red` —
    /// matches the memory/context indicators' `.critical`/`>= 0.95` literal.
    /// Note: `ToolInvocationView`'s failure card currently uses `.orange`
    /// (`:229`), not `.red` — that call site is a distinct semantic choice
    /// ("recoverable tool failure" reads as a warning, not a hard error) that
    /// the migration tranche maps to `statusWarn`, not `statusError`. This
    /// default does not paper over that distinction.
    public var statusError: AnyShapeStyle

    /// `statusError` at reduced opacity. Default: `Color.red.opacity(0.15)`.
    public var statusErrorSoft: AnyShapeStyle

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
    public var statusOKColor: Color

    /// See ``statusOKColor``. Default: `Color.yellow`.
    public var statusWarnColor: Color

    /// See ``statusOKColor``. Default: `Color.red`.
    public var statusErrorColor: Color

    /// Neutral "informational" tone — distinct from the OK/Warn/Error
    /// severity triad above. Covers call sites like "curated", "in use",
    /// "download available", and help/info affordances (spec §7 addendum;
    /// Rory's 2026-07-18 decision on #2307) — e.g. `WhyDownloadView.swift:36`,
    /// `LocalModelStorageView.swift:93`, `StorageManagementView.swift:147`,
    /// `DownloadProgressView.swift:105`. Default: `Color.blue`, the literal
    /// every one of those call sites already uses.
    public var info: AnyShapeStyle

    /// ``info`` at reduced opacity, for soft/pill fills. Default:
    /// `Color.blue.opacity(0.15)` — the tint ratio `DownloadableModelRow.swift:78`
    /// and `HuggingFaceBrowserView.swift:317` already use (with `.green`, not
    /// `.blue`, at the latter — that site maps to `statusOKSoft` instead).
    public var infoSoft: AnyShapeStyle

    /// `Color`-typed sibling of ``info``, for the same ViewInspector reason as
    /// ``statusOKColor``. Default: `Color.blue`.
    public var infoColor: Color

    /// A small, fixed categorical palette for identity badges that need more
    /// than the OK/Warn/Error/Info tones — model-format badges
    /// (`ModelPicker.swift:256-259`: GGUF/MLX/Foundation/default) and
    /// multi-step speed classes (`DownloadableModelRow.swift:196-199`:
    /// fast/usable/sluggish/tooSlow, where "usable" and "sluggish" don't fit
    /// the severity triad). Inventoried via grep across
    /// `Sources/ManifoldUIModelManagement` before designing (spec §7
    /// addendum; Rory's 2026-07-18 decision on #2307). Not an open palette —
    /// exactly the tones today's UI uses; a consumer needing more distinct
    /// categories extends this struct, not raw `Color`.
    public var categorical: ManifoldThemeCategoricalTints

    /// Material reference for translucent chrome. Plain `.regularMaterial` in
    /// Unit 1 — the per-OS `glassEffect`/`GlassEffectContainer` resolution
    /// (`#available(iOS 26, macOS 26, *)`) is a Unit 2 §L1 addition (spec §9).
    public var glass: Material

    /// The corner-radius scale (xs 6 · sm 11 · md 14 · lg 20 · capsule),
    /// `@ScaledMetric`-consumed at the call site like ``ChatTheme/cornerRadius``
    /// is today.
    public var shape: ManifoldThemeShapeScale

    /// HIG text-style roles. Dynamic Type keeps working because these are text
    /// styles (`.body`/`.caption`/…), not point sizes — same contract as
    /// ``ChatTheme/bubbleFont``/``ChatTheme/metadataFont``.
    public var type: ManifoldThemeTypeScale

    /// Creates a theme. Every parameter defaults to the framework's historical
    /// value, so `ManifoldTheme()` (and ``standard``) reproduce today's
    /// appearance exactly — the zero-visual-change guarantee this unit ships.
    public init(
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
        info: AnyShapeStyle = AnyShapeStyle(Color.blue),
        infoSoft: AnyShapeStyle = AnyShapeStyle(Color.blue.opacity(0.15)),
        infoColor: Color = .blue,
        categorical: ManifoldThemeCategoricalTints = ManifoldThemeCategoricalTints(),
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
        self.info = info
        self.infoSoft = infoSoft
        self.infoColor = infoColor
        self.categorical = categorical
        self.glass = glass
        self.shape = shape
        self.type = type
    }

    /// The framework default since Unit 2 §L5 (issue #2307) — carries the
    /// flipped ``ChatTheme/standard`` (gradient bubble) plus every other
    /// semantic token at its historical (Unit 1) value: the flip is scoped to
    /// bubble chrome and the four style-protocol defaults below, not a
    /// re-hue of status/surface/ink tokens. See ``classic`` to restore the
    /// pre-refresh appearance.
    public static let standard = ManifoldTheme()

    /// Reproduces the pre-2026-refresh appearance: ``ChatTheme/classic``
    /// (solid-accent bubble, `16`pt radius) with every other semantic token
    /// unchanged (they never differed between standard and classic — only
    /// the bubble tokens and the four style-protocol defaults moved). Combine
    /// with `.composerStyle(.plain)`, `.thinkingBlockStyle(.plain)`,
    /// `.toolInvocationStyle(.plain)`, and `.sessionRowStyle(.plain)` — or
    /// just call `View.classicManifoldTheme()` below, which applies all five
    /// in one call.
    public static let classic = ManifoldTheme(chatTheme: .classic)
}

public extension View {
    /// Restores the complete pre-2026-refresh appearance in one call: the
    /// ``ManifoldTheme/classic`` token set plus every classic style preset
    /// (composer/thinking-block/tool-invocation/session-row). Equivalent to
    /// applying `.manifoldTheme(.classic)`, `.composerStyle(.plain)`,
    /// `.thinkingBlockStyle(.plain)`, `.toolInvocationStyle(.plain)`, and
    /// `.sessionRowStyle(.plain)` individually — spec §8's "classic presets
    /// ... restore the pre-refresh appearance in one modifier group."
    ///
    /// ```swift
    /// ChatView(showModelManagement: $show)
    ///     .classicManifoldTheme()
    /// ```
    func classicManifoldTheme() -> some View {
        self
            .manifoldTheme(.classic)
            .composerStyle(.plain)
            .thinkingBlockStyle(.plain)
            .toolInvocationStyle(.plain)
            .sessionRowStyle(.plain)
    }
}

/// The categorical tint set backing ``ManifoldTheme/categorical``. Each pair
/// (`AnyShapeStyle` + `Color`) mirrors the ``ManifoldTheme/statusOK``/
/// ``ManifoldTheme/statusOKColor`` split — the `Color`-typed sibling exists
/// for `ViewInspector`-inspectable call sites (`.foregroundStyle(_:)`
/// arguments), same rationale as ``ManifoldTheme/statusOKColor``'s doc
/// comment.
public struct ManifoldThemeCategoricalTints: Sendable {
    /// GGUF model-format badge (`ModelPicker.swift:256`); also the "sluggish"
    /// speed class (`DownloadableModelRow.swift:198`). Default: `Color.orange`.
    public var orange: AnyShapeStyle
    /// See ``orange``. Default: `Color.orange`.
    public var orangeColor: Color

    /// MLX model-format badge (`ModelPicker.swift:257`). Default: `Color.purple`.
    public var purple: AnyShapeStyle
    /// See ``purple``. Default: `Color.purple`.
    public var purpleColor: Color

    /// "Usable" speed class (`DownloadableModelRow.swift:197`) — distinct from
    /// ``ManifoldTheme/info`` so a consumer can retint identity badges without
    /// also retinting every info affordance. Default: `Color.blue`.
    public var blue: AnyShapeStyle
    /// See ``blue``. Default: `Color.blue`.
    public var blueColor: Color

    /// Default/unknown model-format badge (`ModelPicker.swift:259`).
    /// Default: `Color.gray`.
    public var gray: AnyShapeStyle
    /// See ``gray``. Default: `Color.gray`.
    public var grayColor: Color

    public init(
        orange: AnyShapeStyle = AnyShapeStyle(Color.orange),
        orangeColor: Color = .orange,
        purple: AnyShapeStyle = AnyShapeStyle(Color.purple),
        purpleColor: Color = .purple,
        blue: AnyShapeStyle = AnyShapeStyle(Color.blue),
        blueColor: Color = .blue,
        gray: AnyShapeStyle = AnyShapeStyle(Color.gray),
        grayColor: Color = .gray
    ) {
        self.orange = orange
        self.orangeColor = orangeColor
        self.purple = purple
        self.purpleColor = purpleColor
        self.blue = blue
        self.blueColor = blueColor
        self.gray = gray
        self.grayColor = grayColor
    }
}

/// Corner-radius scale token (spec §7): xs 6 · sm 11 · md 14 · lg 20 · capsule.
/// Nested radii are meant to be derived concentrically by component code
/// (outer radius − padding = inner radius), not stored redundantly here.
///
/// Public since Unit 2 §L2 — a stored property of the now-public
/// ``ManifoldTheme/shape``, so it must be constructible by a consumer
/// building a custom theme.
public struct ManifoldThemeShapeScale: Sendable {
    public var xs: CGFloat
    public var sm: CGFloat
    public var md: CGFloat
    public var lg: CGFloat

    public init(xs: CGFloat = 6, sm: CGFloat = 11, md: CGFloat = 14, lg: CGFloat = 20) {
        self.xs = xs
        self.sm = sm
        self.md = md
        self.lg = lg
    }
}

/// HIG text-style roles consumed by component code. Kept intentionally small
/// in Unit 1 — the full role set grows as Unit 2's style protocols land.
///
/// Public since Unit 2 §L2 — see ``ManifoldThemeShapeScale``'s doc comment;
/// same reasoning, backing ``ManifoldTheme/type``.
public struct ManifoldThemeTypeScale: Sendable {
    /// Section/sheet titles. Default: `.headline`.
    public var title: Font
    /// Primary body copy. Default: `.body` — matches ``ChatTheme/bubbleFont``.
    public var body: Font
    /// Secondary metadata. Default: `.caption` — matches ``ChatTheme/metadataFont``.
    public var caption: Font
    /// Tertiary/badge copy. Default: `.caption2`.
    public var caption2: Font

    public init(
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

public extension EnvironmentValues {
    /// The active theme root. Defaults to ``ManifoldTheme/standard`` so
    /// untouched views render with the historical appearance.
    @Entry var manifoldTheme: ManifoldTheme = .standard
}

public extension View {
    /// Applies a ``ManifoldTheme`` to this view and everything below it,
    /// including content presented in `.sheet`/`.fullScreenCover` from inside
    /// the subtree. Mirrors `.chatTheme(_:)`'s cascading-modifier shape.
    ///
    /// Writes through to `\.chatTheme` as well as `\.manifoldTheme`, so call
    /// sites that only read the legacy `\.chatTheme` key (every bubble today)
    /// see a theme consistent with the one just applied here.
    ///
    /// ```swift
    /// ChatView(showModelManagement: $show)
    ///     .manifoldTheme(myBrandTheme)
    /// ```
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
