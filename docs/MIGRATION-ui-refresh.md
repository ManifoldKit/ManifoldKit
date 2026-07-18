# Migrating to the 2026 UI refresh — the visual break

**Audience:** consumer
**Status:** living (finalized at Unit 2 merge, issue #2307)

> **This is a deliberate pre-1.0 visual break (Principle 9).** ManifoldKit's
> built-in chat look changed — new default styles ship out of the box, the
> pre-refresh look is preserved as **classic presets**, not deprecated APIs.
> Per the repo's public API policy, retired shapes are deleted, not carried
> forward with `@available(*, deprecated)` shims.

## TL;DR

- Every app that renders `ChatView`/`SessionRowView`/`ThinkingBlockView`/
  `ToolInvocationView`/the composer **without any style modifiers** gets a new
  look automatically on upgrade: glass composer capsule, shimmer reasoning
  disclosure, card-style tool invocations, quiet session rows with pin glyphs,
  and a gradient user bubble with a larger corner radius.
- Want the old look back? Apply **one modifier** at the chat root:
  ```swift
  ChatView(showModelManagement: $show)
      .classicManifoldTheme()
  ```
- Nothing about the turn loop, tool-calling contract, or `sendMessage(_:)`
  changed. This is a *rendering* change only.

## Full default-appearance change inventory

| Surface | Pre-refresh default | New default | Restore |
|---|---|---|---|
| User bubble fill | Solid `Color.accentColor` | Linear gradient derived from `Color.accentColor` | `.chatTheme(.classic)` or `.classicManifoldTheme()` |
| Bubble corner radius | `16`pt | `20`pt (aligned to `ManifoldThemeShapeScale.lg`) | same |
| Composer chrome | `PlainComposerStyle` — field + unstyled sibling affordances | `GlassComposerStyle` — field + affordances share one glass capsule (iOS floating, macOS docked) | `.composerStyle(.plain)` |
| Reasoning disclosure | `PlainThinkingBlockStyle` — "Thinking…"/"Reasoning" `DisclosureGroup` | `ShimmerThinkingBlockStyle` — shimmer preview → "Thought for Ns" → hairline-rule trace | `.thinkingBlockStyle(.plain)` |
| Tool invocation card | `PlainToolInvocationStyle` — literal `.orange`/`.green` accents | `CardToolInvocationStyle` — semantic `statusOK`/`statusWarn` tokens, compact card chrome | `.toolInvocationStyle(.plain)` |
| Sidebar session row | `PlainSessionRowStyle` — title + relative-time caption only | `QuietSessionRowStyle` — adds a quiet pin glyph and snippet line | `.sessionRowStyle(.plain)` |
| Chat shell chrome (iOS) | Opaque `Divider()` seam between transcript and composer | Edge-to-edge scroll under a glass composer (`safeAreaInset` + `manifoldGlass(_:in:)`); native `glassEffect` on iOS 26+, `.regularMaterial` below | No dedicated restore — `.classicManifoldTheme()` does not un-flip the shell chrome; the composer/reasoning/tool/row *styles* are the only per-surface classic presets |
| macOS toolbar | Same system toolbar contribution as before (no MK-drawn bar) | Unchanged in shape; the model-switcher chip (below) is new, opt-in content | Omit `.chatModelSwitcher(_:)` |
| Message-part rendering | `chatMessagePartRenderer(_:)` compiled but was never consulted by `MessagePartsView` | **Live**: `MessagePartsView` gives a host renderer first refusal per part before falling through to its own per-kind dispatch | No restore needed — a host that never calls `.chatMessagePartRenderer(_:)` sees no change |
| Reasoning-disclosure interactivity **(behavior, not just appearance)** | A user could expand/collapse the disclosure even while reasoning was still streaming | The 3-state `ThinkingBlockState` model (`streaming`/`settled(duration:)`/`expanded(duration:)`) has no "streaming+expanded" case, so both built-in styles render the streaming branch as non-interactive (a fixed-closed `DisclosureGroup`) | Not restorable via a style — this is a data-model constraint, not a rendering choice. If your app depended on mid-stream manual expansion, that affordance no longer exists in either style |
| Pinned-message pin glyph | Top-trailing overlay badge on the bubble (#2007) | Relocated into the bubble's metadata row, alongside timestamp/token-count/status labels (spec §12) — same `isPinned` signal and glyph, different position | No restore — this is a `MessageBubbleView` layout change, not a style-protocol default |
| Generated video rendering | Prompt text only (`MessagePartsView.swift`, pre-#2320) | AVKit `VideoPlayer` in the same clipping (spec §4A: "Video gets the AVKit player in the same clipping") — tap opens the *system* playback controls, no custom lightbox | No restore — this is a functional fix (a read path that had no player), not a style choice |
| Missing generated media (image/video, binary deleted from disk) | A bare gray placeholder rect + `.secondary` caption | One shared `statusWarn`-voice placeholder (`theme.statusWarnSoft` fill, `theme.statusWarnColor` icon/caption) stating the cause, per spec §4A "never shows a broken frame" | No restore — token-driven, not style-protocol-driven; a custom `ManifoldTheme.statusWarn`/`statusWarnSoft` still recolors it |

Every semantic *color* token (`statusOK`/`statusWarn`/`statusError`, `ink`/
`ink2`/`ink3`, `surface`/`surface2`, the categorical/info tiers) is
**unchanged** by the flip — the refresh restyles chrome and geometry, it does
not re-hue anything. `ManifoldTheme.standard` and `.classic` share every
semantic token; they differ only in `chatTheme` (the bubble tokens above).

**A note on "byte-for-byte" for the classic composer**: `PlainComposerStyle`
(the `.composerStyle(.plain)` restore) reproduces `ChatInputBar`'s pre-refresh
layout visually, but not at the modifier-chain level — the field's
`.padding(10)`/`.background(_:in: RoundedRectangle(cornerRadius: 12))` now
apply *inside* `PlainComposerStyle`'s body rather than inline in
`ChatInputBar` (L3's own PR body flagged this: "'Byte-for-byte' ... is
accurate for rendered pixels but not for the modifier chain ... visually
equivalent, not source-identical"). No characterization test pins the
composer's rendered chrome specifically (unlike the bubble/tool-card/status
anchors `DefaultAppearanceCharacterizationTests`/
`ClassicAppearanceCharacterizationTests` do cover) — if you depended on the
exact SwiftUI modifier order around the composer field (e.g. a
`.background(_:)` you expected to compose a particular way with a
downstream modifier), verify visually rather than assuming source identity.

## Restoring the classic look

Apply all five classic presets in one call at the chat root (and anywhere a
`SessionListView`/standalone style-consuming view is presented outside that
subtree, since environment values only cascade downward):

```swift
import ManifoldKit

ChatView(showModelManagement: $show)
    .classicManifoldTheme()
```

`classicManifoldTheme()` is exactly:

```swift
.manifoldTheme(.classic)
.composerStyle(.plain)
.thinkingBlockStyle(.plain)
.toolInvocationStyle(.plain)
.sessionRowStyle(.plain)
```

so you may also apply any subset individually — e.g. keep the new composer
capsule but restore the classic tool-invocation card:

```swift
ChatView(showModelManagement: $show)
    .toolInvocationStyle(.plain)
```

`ChatTheme.classic` and `ManifoldTheme.classic` are `public` — reach them
directly if you're constructing a theme by hand rather than through the
convenience modifier.

## New opt-in surface: the model switcher chip

Unit 2 §L3 built a unified quick model switcher (`ModelSwitcherView`,
`ModelSwitcher`, `ModelSwitcherRow` — all `public` in `ManifoldUIModelManagement`)
that lists local models and cloud endpoints in one list. Unit 2 §L5 mounts
its *chrome* into `ChatView`'s toolbar — a chip that presents the switcher
content as a popover on macOS (anchored to the chip) or a sheet with
`.presentationDetents` on iOS. The chip only appears if you supply content.
`ModelRegistry.compatibility(for:)` (public, already used by
`ModelPicker`/`ModelManagementSheet`) is the compatibility source — no
separate capability service needed:

```swift
import ManifoldKit
import ManifoldUIModelManagement

ChatView(showModelManagement: $show)
    .chatModelSwitcher {
        ModelSwitcherView(
            rows: ModelSwitcher.rows(
                models: chatViewModel.availableModels,
                endpoints: chatViewModel.availableEndpoints,
                selectedModelID: chatViewModel.selectedModel?.id,
                selectedEndpointID: chatViewModel.selectedEndpoint?.id,
                physicalMemoryBytes: chatViewModel.physicalMemoryBytes,
                compatibility: chatViewModel.modelRegistry.compatibility(for:)
            ),
            onSelect: { entry in
                switch entry {
                case .model(let model):
                    chatViewModel.selectedModel = model
                case .endpoint(let endpoint):
                    Task { await chatViewModel.loadCloudEndpoint(endpoint) }
                }
            },
            onFixEndpoint: { _ in showModelManagement = true }
        )
    }
```

`ChatView` cannot import `ModelSwitcherView` directly — `ManifoldUI` must not
depend on `ManifoldUIModelManagement` (Principle 2). The seam mirrors
`chatAPIConfiguration(_:)`'s closure-injection shape for exactly this reason.
Omitting `.chatModelSwitcher(_:)` renders no chip at all — this is fully
opt-in, no upgrade action required. `Example/Advanced/DemoContentView.swift`
wires this exact call site (with `.onChange(of: chatViewModel.selectedModel)`
already dispatching the load, so `onSelect` only needs to set the selection);
`ModelSwitcherMigrationGuardTests` (`Tests/ManifoldUIModelManagementTests`)
is the compile-time guard keeping this snippet honest.

## Retired API

None. Every `.classic`/`.plain` preset is new, additive public surface; no
existing public symbol was removed or renamed by this refresh. The `Plain*`
built-in styles kept their names — only which style each `@Entry` environment
default resolves to changed.

## Why the PR title carries `!`

No public symbol was removed or renamed — every `.classic`/`.plain` preset
and the model-switcher seam are additive. The `!` on the integration PR's
title marks this as a **behavior-visible break** (rendered defaults changed
for every consumer who never applied a style override) so Release Please's
changelog lead calls it out prominently, per this repo's pre-1.0 policy of
"deliberate, never casual" breakage (Principle 9) — not because a symbol was
deleted.
