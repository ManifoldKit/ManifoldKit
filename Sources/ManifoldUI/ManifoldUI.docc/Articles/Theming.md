# Theming the Chat UI

Restyle every chat surface — bubbles, composer, reasoning, tool cards, and the sidebar — without forking a single view.

## Overview

ManifoldUI ships an opinionated default look, but every styling decision is an override seam. The 2026 UI refresh (issue #2307, `docs/UI-REFRESH-2026.md`) generalizes this from "bubbles only" to every themeable surface, using one three-tier token model:

1. **Primitive** — raw values (a `Color`, a `CGFloat`, a `Material`). Never referenced directly by component code.
2. **Semantic** — ``ManifoldTheme``'s stored properties (`accent`, `surface`, `statusOK`, `info`, `categorical`, `shape`, `type`, …). Component code may only reference this tier.
3. **Component** — the style-protocol layer (``MessageBubbleStyle``, ``ComposerStyle``, ``ThinkingBlockStyle``, ``ToolInvocationStyle``, ``SessionRowStyle``) plus the per-message/per-part renderer seams. Components read semantic tokens and decide layout/shape; they never hold a primitive.

Every layer is additive, and ``ManifoldTheme/standard`` carries the 2026 refresh's new look as the framework default since Unit 2 §L5 (issue #2307) — this is a deliberate pre-1.0 visual break, not a silent drift; see `docs/MIGRATION-ui-refresh.md` for the full change inventory. A consumer who wants the pre-refresh appearance back applies one modifier: `View.classicManifoldTheme()` (or ``ManifoldTheme/classic`` / the individual `.plain` style presets). `DefaultAppearanceCharacterizationTests` locks the new defaults; `ClassicAppearanceCharacterizationTests` locks the restored look to the exact pre-flip values, so the old appearance stays reproducible forever even though it is no longer the default.

The litmus test for any theme you write: toggle Dark Mode, max Dynamic Type, and Increase Contrast — nothing should stay fixed. Colors flow through `ShapeStyle` (asset-catalog colors get Dark Mode/Increase Contrast for free), fonts are HIG text styles (Dynamic Type keeps scaling), and any metric that should grow with text size is multiplied by a `@ScaledMetric` factor at the point it is drawn.

## Semantic tokens — `ManifoldTheme`

``ManifoldTheme`` is the token root, injected via `.manifoldTheme(_:)`. It embeds the original ``ChatTheme`` (bubble-specific tokens, unchanged) and adds the surfaces every other component needs:

```swift
import SwiftUI
import ManifoldUI

func makeBrandTheme() -> ManifoldTheme {
    var theme = ManifoldTheme.standard
    theme.accent = AnyShapeStyle(Color.indigo)
    theme.surface = AnyShapeStyle(Color.indigo.opacity(0.08))
    theme.shape = ManifoldThemeShapeScale(xs: 4, sm: 8, md: 12, lg: 18)
    return theme
}
```

| Tier | Tokens | Covers |
|---|---|---|
| Brand | `accent` | Resolves to the host's `Color.accentColor` — never a literal. |
| Surfaces | `ground`, `surface`, `surface2`, `glass` | Chat background, elevated cards/rows/fields, translucent chrome. |
| Ink | `ink`, `ink2`, `ink3` | Primary/secondary/tertiary text and icons. |
| Severity | `statusOK(Soft)`, `statusWarn(Soft)`, `statusError(Soft)` (+ `Color`-typed siblings) | Nominal/degraded/failed states — model fit, endpoint health, tool outcomes. |
| Info | `info`, `infoSoft`, `infoColor` | Neutral callouts that are not severity: curated, in-use, download-available, help affordances. |
| Categorical | `categorical` (``ManifoldThemeCategoricalTints``) | A small fixed identity palette — model-format badges (GGUF/MLX/Foundation), multi-step speed classes — for cases the OK/Warn/Error/Info tiers don't fit. |
| Geometry | `shape` (``ManifoldThemeShapeScale``: xs/sm/md/lg), `type` (``ManifoldThemeTypeScale``: title/body/caption/caption2) | Concentric corner radii and HIG text-style roles. |

### Coverage table

| Surface | Token source today |
|---|---|
| Message bubbles | ``ChatTheme`` (embedded in ``ManifoldTheme/chatTheme``) |
| Composer field background | ``ManifoldTheme/surface`` via ``ComposerStyle`` |
| Tool cards (checkmark / warning icons) | ``ManifoldTheme/statusOK``/``statusWarn`` via ``ToolInvocationStyle`` |
| Reasoning disclosure | ``ManifoldTheme/ink2``/``ink3`` via ``ThinkingBlockStyle`` |
| Sidebar rows | ``ManifoldTheme/ink2``/``ink3`` via ``SessionRowStyle`` (system owns row selection/vibrancy — see `docs/UI-REFRESH-2026.md` §2) |
| Model-management badges (format, speed, fit) | ``ManifoldTheme/categorical``, ``ManifoldTheme/statusOK``/``statusWarn``/``statusError`` — `ModelPicker`/`DownloadableModelRow` call sites migrated in Unit 2 §L3 |

## Component styles

Five style-protocol seams follow the same recipe — implement `makeBody(configuration:)`, read `@Environment` from the returned view, install with a cascading modifier:

- <doc:ComposerStyling> — the composer container (capsule/bar, phase-aware)
- <doc:ThinkingBlockStyling> — the reasoning disclosure (streaming/settled/expanded)
- <doc:ToolInvocationStyling> — tool-call cards (four lifecycle states)
- <doc:SessionRowStyling> — sidebar row content
- ``MessageBubbleStyle`` — bubble chrome (ships since the original theming layer)

Each ships a `.plain`-style built-in that reproduces the pre-refresh chrome exactly (the `.classic` preset) alongside the new-look style, which is the built-in default since Unit 2 §L5. See <doc:WhiteLabelTheming> for a worked brand swap using this token + style layering.

## Per-message and per-part rendering

Two renderer seams intercept content rather than restyling it:

- `.chatMessageRenderer(_:)` — first refusal on an entire message; call `params.defaultMessageView()` to fall through.
- <doc:PartRendering> — first refusal on one *content part* within a message (a specific tool call, a generated-media kind); call `params.defaultPartView()` to fall through. Finer-grained than the message renderer — other parts in the same message still render through the built-in per-kind views.

Both compose LAST-WINS: nested `.chatMessageRenderer(_:)`/`.chatMessagePartRenderer(_:)` calls resolve to whichever is closest to the leaf view, the same way `.font(_:)`/`.tint(_:)` cascade.

## Accessibility checklist

- **Dark Mode** — use asset-catalog colors or system `ShapeStyle`s; every ``ManifoldTheme`` default is a system color or material, never a literal RGB.
- **Dynamic Type** — keep fonts as text styles (``ManifoldThemeTypeScale``); scale custom spacing with `@ScaledMetric`, as ``ChatTheme``'s bubble metrics already do.
- **Increase Contrast** — system fills (`.fill.tertiary`, `.secondary`) and `.separator` adapt automatically; a custom `ManifoldTheme` using bespoke colors should be checked in the Accessibility Inspector.
- **Reduce Motion** — shimmer/live states (the new-look `ThinkingBlockStyle`/`ToolInvocationStyle` variants) must render statically when `accessibilityReduceMotion` is set; see `ManifoldGlassResolution`'s sibling a11y tests for the established pattern.
- **VoiceOver** — the built-in tool/thinking/session-row styles carry the same accessibility identifiers and labels the pre-refresh views used; a fully custom style is responsible for its own labels.

## Topics

### Token root

- ``ManifoldTheme``
- ``ManifoldThemeShapeScale``
- ``ManifoldThemeTypeScale``
- ``ManifoldThemeCategoricalTints``
- ``ChatTheme``

### Bubble styles

- ``MessageBubbleStyle``
- ``MessageBubbleConfiguration``
- ``PlainMessageBubbleStyle``
- ``IMessageMessageBubbleStyle``
- ``CardMessageBubbleStyle``

### Message and part rendering

- ``ChatMessageRenderParameters``
- ``ChatMessageRenderer``
- ``ChatMessagePartRenderParameters``
- ``ChatMessagePartRenderer``
