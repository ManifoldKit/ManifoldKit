# UI Refresh 2026 — design reference

> **Status: living design doc.** Direction decided 2026-07-17: the new look ships
> as the **default** — a deliberate pre-1.0 visual break under Principle 9 —
> with the pre-refresh appearance preserved as shipped *classic presets*.
> Decisions land here first; as the implementation units ship, durable content
> migrates into `Sources/ManifoldUI/ManifoldUI.docc/Articles/Theming.md` and the
> per-protocol DocC pages, and this file becomes the historical record.
>
> **The drawn version is canonical for pixels:**
> [`docs/design/ui-refresh-2026.html`](design/ui-refresh-2026.html) — a
> self-contained page (open it locally in a browser) with interactive light/dark
> mockups of every surface. A claude.ai artifact mirrors that file for
> review-sharing; the repo copy is canonical. Section numbers below (§2, §6A, …)
> refer to that page.
>
> Provenance: synthesized from a full codebase UI survey, mid-2026 AI-chat UX
> research (flagship apps, native clients, Liquid Glass adoption), theming-
> architecture research (Material 3, Stream Chat, shadcn, assistant-ui,
> ExyteChat), an adversarial design review (Rev 2), and deep functionality
> sweeps of the model-selection option space, turn-loop actions, generated
> media, and experimental modules (Rev 5–7).

## 1. Principles

1. **Content scrolls under glass.** The transcript bleeds edge-to-edge beneath
   translucent bars. The composer is glass — a floating capsule on iOS, a
   docked bar on macOS. On pre-26 OSes the same treatment renders in system
   materials.
2. **Tokens all the way down.** No component references a raw `Color`.
   Everything routes through semantic tokens in one `ManifoldTheme`.
3. **State is data, styling decides.** Streaming / failed / awaiting-approval
   are typed states on style-protocol `Configuration` structs; styles decide
   the visuals.
4. **Quiet until it matters.** Live work shimmers; finished work settles into a
   static badge. Reasoning is collapsed by default with a one-line live
   preview.
5. **Concentric geometry.** Corner radii are derived (parent radius − padding),
   from one shape scale in the theme — replacing scattered 4/6/8/12 pt
   constants.
6. **Shared components, native chrome.** Bubbles, tool cards, reasoning,
   tokens, and shimmer are identical across platforms. Chrome is not:
   toolbars, composer placement, picker presentation, and selection follow
   each platform's conventions; pointer/hover feedback is first-class on
   macOS.

## 2. Platform chrome rules (the macOS divergence)

The glass APIs (`glassEffect`, `GlassEffectContainer`,
`backgroundExtensionEffect`) are cross-platform on the 26 OSes; the *idiom*
diverges:

| Surface | iOS | macOS |
|---|---|---|
| Toolbar | MK-drawn glass bar; transcript scrolls beneath | **System window toolbar** — MK contributes items only, never draws the bar, on any OS version. Actions spread out, not collapsed to "⋯" |
| Composer | Floating glass capsule, detached from bottom edge | Docked, width-constrained glass bar; ⌘↩ affordance |
| Model picker | Glass palette | Glass **popover anchored to the toolbar chip**; arrow-key selection, single tab stop |
| Sheets | Glass sheet + detents | Window-style sheet (`presentationDetents` is iOS-only) |
| Sidebar | — | Real `NavigationSplitView` column; selection/vibrancy defer to the system; `SessionRowStyle` styles row *content* only |
| Message actions | Context menu | **Hover-revealed** action pill (copy / regenerate / more) |

Every macOS control gets pointer hover feedback.

## 3. Composer

Single field + at most three affordances: "+" menu, voice, send/stop. Phases:
idle / composing / generating (send morphs to stop) / voice (accessory panel
above the capsule). Quick-action pills and the draft-attachment strip render in
the accessory band above the field.

**Gating is unchanged — the redesign moves geometry, not seams.** Each "+"
item maps 1:1 to its existing `ManifoldConfiguration.Features` flag and
capability check; the mic renders only when `ComposerPermissionGate` passes (a
missing `NSMicrophoneUsageDescription` removes it entirely); voice remains an
optional `ManifoldVoice` integration via the `chatComposerAccessory` slot.

A **scroll-to-bottom control** (new — none exists today) floats above the
composer when the user scrolls up during streaming; tapping resumes follow. It
is owned by the transcript scroll container alongside the anchoring logic.

## 4. Tool invocation lifecycle

One card, four typed states — `awaitingApproval → running → completed |
failed` — delivered to `ToolInvocationStyle` as configuration data. Live
states spin/shimmer; terminal states are static and collapsed (expand for
payload). Status colors come from the semantic tier (retiring literals like
`.orange.opacity(0.15)` in `ToolInvocationView`). Failed states carry a next
action (Retry / Details); the MCP reauthenticate hook renders here.

## 4A. Reasoning & generated media (§4A of the drawn spec)

- **Reasoning, three states** on `ThinkingBlockStyle.Configuration`: streaming
  (one shimmer preview line) → settled ("Thought for Ns") → expanded
  (caption-size selectable trace behind a hairline rule — always quieter than
  the answer, never styled as content).
- **Generation progress card** (image/video/audio kinds): shimmer title, step
  N/M determinate bar, blurred live preview from
  `ImageGenerationProgress.previewImage` (data that exists today with **no
  in-chat UI**), cancel — settles in place into the media. Same lifecycle
  grammar as tool cards.
- **Settled media**: shape-md clipping, glass caption footer (prompt +
  save/expand), tap opens the *system* viewer — no custom lightbox. Video gets
  the AVKit player in the same clipping (today it renders prompt text only).
- **Missing media** never shows a broken frame: it states its cause in the
  statusWarn voice; placeholder hash-grids keep aspect and palette.

## 5. Model picker — two levels

The most option-dense component in the framework. The design splits it:

- **Quick switcher** (toolbar-chip popover/palette): answers *"what do I talk
  to right now?"* — identity + one qualitative fitness signal + capability
  glyphs + live states, plus the thinking-budget row and "Manage models…".
- **Management sheet** (existing Select / Download / Storage surface): all
  depth — quant variant groups, fit/speed/rationale, benchmarks, import,
  storage, endpoint editing. The switcher never grows tabs.

**The one structural change: a unified switcher list.** Local models
(`ModelRegistry.availableModels`) and cloud endpoints (`APIEndpointRecord` via
`EndpointStore`) are mutually exclusive today but never co-presented. The
switcher unifies them; the exclusion already exists in the selection model, so
this is a presentation-layer merge plus one registry-level union — but it is
new plumbing and the picker redesign's real feature.

Switcher rules:

1. **One fitness signal per row, qualitative.** Dot = device-RAM fit
   (`ModelLoadPlan.canRunModel`: green/amber/red/gray-unknown; accent for
   cloud). Backend-registration unavailability is a *different* failure:
   dimmed row + reason string. Raw tok/s never appears in the switcher.
2. **Capability glyphs come from data, not marketing.** ✦ reasoning · ⚙ tools
   · ◎ vision map to `supportsReasoning` / `toolCallClaim` / `mmprojURL` —
   already computed on `ModelInfo`, currently unrendered. A claim renders as a
   claim.
3. **Live states in place.** Downloading shows inline progress; a faulted
   endpoint shows its fault and is one tap from the fix; "In use" marks the
   loaded model and the row reflects `ModelLoadStatus` during loads.
4. **"Thinking budget", not "reasoning effort".** There is no effort enum —
   the lever is `GenerationConfig.maxThinkingTokens` (Off → 0, Auto → nil,
   Extended → named budget), rendered only when
   `ModelManifest.supportsThinking`. Sampler knobs elsewhere gate on
   `supportedSamplingParameters` the same way — never show a control the
   backend won't honor.

Option-space map (dimension → where it surfaces):

| Dimension | Switcher | Management |
|---|---|---|
| Name, backend/type, quant, size | Subtitle | Full detail |
| Capability tier (benchmark-upgraded) | One word ("Balanced") | Badge + measured result, run benchmark |
| Capability flags / tool claim / vision projector | ✦ ⚙ ◎ | Spelled out with provenance (curated/detected/claimed) |
| Device-RAM fit / speed class | Dot only | Fit + speed capsules + rationale on recommended variant |
| Backend availability | Dimmed + reason | Same + companion-package guidance; download-anyway allowed |
| Download states | Inline progress/fault | Full progress view + cancel/retry/resume |
| Endpoint health | Fault inline, tap to fix | Endpoint editor |
| Multi-quant grouping, curation, sort/use-case | — (top variant only) | Disclosure groups, "best for your device", search/sort |
| Thinking budget | Segmented, manifest-gated | — |
| Sampler presets (global) + per-knob gating | — | Generation settings, manifest-gated knobs |
| Import, delete, storage | — | Existing flows, themed |

Deliberately **out of the picker**: embedding-model selection (no UI exists;
bootstrap resolves implicitly), image-gen model install (separate curated
sheet by its own documented design), video-gen management (earlier-stage).

## 6. Sessions, state screens, connected services

- **Sidebar** (§6): List bones + theme for row content; system selection on
  macOS; pinned rows marked quietly.
- **State screens** (§6A) — the rule: **failures render at their scope.**
  Turn-level → in-transcript card (statusError soft fill, Retry + Details);
  session-level recoverable → banner above the composer with its fix inline;
  only bootstrap failure owns the whole screen. First run is a funnel (primary
  → model management, secondary → endpoint setup). Loading states name their
  milestone. Empty session shows suggestion chips via the existing
  `chatEmptyState` slot.
- **Connected services (MCP)** (§6B) — **decided in scope 2026-07-17.** The
  connect/OAuth/consent surface exists only in the demo app today; a themed
  version is promoted into the package (`ManifoldUIModelManagement` settings
  family, **experimental** per API-DESIGN §7b). Rules: connection state uses
  the status tier (connected/reauth/off = OK/warn/neutral); consent explains
  data flow in plain words *before* first tool exposure; connecting a server
  never implies approving its tool calls (per-call approval stays in the tool
  card); reauth reuses the `ToolErrorPresentation` "mcp.reauthenticate" hook;
  tool counts + the Foundation 16-tool cap render via `MCPToolCountView`.

## 7. Token system — `ManifoldTheme`

Three tiers (Material-3 style): **primitive → semantic → component**, where
component code may only reference the semantic tier. `ChatTheme` grows into
(or is wrapped by) one root `ManifoldTheme` injected via environment at
bootstrap — Stream Chat's `Appearance` shape, without the singleton.

Semantic tokens: `accent` (**resolves to the host app's `Color.accentColor`
— never a literal**; consumers keep their brand tint for free), ground /
surface / surface2, ink / ink2 / ink3, statusOK / statusWarn / statusError
(+soft fills), `glass` (material reference: `glassEffect` on 26+,
`.regularMaterial` below), shape scale (xs 6 · sm 11 · md 14 · lg 20 ·
capsule; nested radii derived concentrically), type scale (HIG text styles,
Dynamic Type via `@ScaledMetric` as today).

Component tokens point at semantic tokens only — e.g. `userBubbleBackground`
= a gradient *derived from the resolved accent*, never a fixed hue.

**Enforcement:** `HardcodedColorAuditTest` (+ in-file `test_sabotage_`,
registered with `AuditSabotageCoverageAuditTest`) with a three-way taxonomy:
(a) themeable colors — must route through `ManifoldTheme` (~57 literals
migrate); (b) functional/data colors (agent-avatar UUID hashing,
image-placeholder hash grids) — stay in view code by design; (c)
diagnostic-only views — allowlisted per-file.

## 8. Style-protocol map

Existing precedent (`MessageBubbleStyle`: `@Entry` environment storage,
cascading modifier, static accessors, data-only `Configuration`) extended:

| Protocol / seam | Owns | Configuration carries | Status |
|---|---|---|---|
| `ChatTheme` → `ManifoldTheme` | All tokens (§7) | — | Extend existing |
| `MessageBubbleStyle` | Bubble chrome | role, content, isStreaming | Ships today |
| `ComposerStyle` | Capsule/bar, field, "+" menu, send/stop | phase (idle/composing/generating/voice), attachments | **New** |
| `ThinkingBlockStyle` | Reasoning disclosure | state (streaming / settled(duration) / expanded), text | **New** |
| `ToolInvocationStyle` | Tool cards | lifecycle state, name, args, result, error, approval closures | **New** |
| `SessionRowStyle` | Sidebar row content | title, snippet, isPinned, isSelected | **New** |
| `chatMessageRenderer` | Whole-message override | message + `defaultMessageView()` | Ships today |
| `chatMessagePartRenderer` | Per-part override | part + `defaultPartView()` | **New** (aligns with #1640) |

All `public`. **The new built-in styles become the default look** (the
deliberate break); classic presets (`.chatTheme(.classic)` + legacy styles)
restore the pre-refresh appearance in one modifier group.

## 9. OS fallback matrix

Floor stays iOS 18 / macOS 15; glass behind `#available(iOS 26, macOS 26, *)`.
iOS fallback: identical geometry in `.regularMaterial`. macOS fallback:
graceful, not identical — chrome is system-owned on every version, and there
is no pre-26 `backgroundExtensionEffect` equivalent. Shimmer/live states and
hover feedback are identical on all OS versions (static under Reduce Motion).
Standard glass APIs inherit the WWDC26 system glass-intensity setting for
free — never hand-roll glass-look backgrounds.

## 10. Documentation obligations (ship inside the unit PRs)

- `Theming.md` rewrite: three-tier token model, `ManifoldTheme`, per-surface
  coverage table, light/dark/Increase-Contrast checklist.
- Per-protocol DocC pages (`ComposerStyle`, `ThinkingBlockStyle`,
  `ToolInvocationStyle`, `SessionRowStyle`, `chatMessagePartRenderer`) — one
  compile-gated runnable custom-style snippet each.
- "White-label your chat" recipe — a worked brand swap.
- Connected Services (MCP) DocC page — wiring, consent/reauth contract,
  Foundation tool-cap, experimental status.
- Liquid Glass adoption note — automatic behavior on 26+, fallback, opt-out
  via the `glass` token.
- **Migration note — the 0.x visual break**: full default-appearance change
  inventory, the classic-preset restore path, retired API list
  (delete-don't-deprecate). The CHANGELOG entry leads with it.
- AGENTS.md Part 1 update: new theming surface; add hallucinated-API entries
  as they're observed.

## 11. Test pinning

- **Default-appearance characterization, two anchors**: during Unit 1 the
  resolved values equal today's appearance byte-for-byte; after the flip the
  suite pins the *new* defaults and separately pins that `.classic`
  reproduces the old look.
- Token plumbing: a custom `ManifoldTheme` resolves through every consuming
  surface (one assertion per surface, incl. model-management badges).
- Style-protocol dispatch: correct `Configuration` for every typed state
  (tool ×4, composer ×4, thinking ×3).
- Part-renderer fallthrough: overriding one kind leaves others on
  `defaultPartView()`.
- `HardcodedColorAuditTest` + sabotage, registered with
  `AuditSabotageCoverageAuditTest`.
- Availability seams: glass paths compile under the 26 SDK and fall back
  below (macOS 15 CI exercises the fallback naturally).
- Accessibility invariants: Reduce Motion disables shimmer/spin; Dynamic Type
  scales shape/type; VoiceOver labels on state badges and send/stop.

## 12. Coverage inventory

Every element from the survey has a disposition — **Redesigned** (drawn in
the spec), **Token restyle** (keeps structure, inherits `ManifoldTheme`), or
**Diagnostic-exempt / Out of scope**. The full three-table inventory lives in
§12 of the drawn spec; the rule: anything discovered during implementation
that isn't listed gets a disposition added *before* it's styled. This section
is the completeness check for the Unit 2 review.

Highlights beyond the sections above: branched sessions open with a
"Branched from ‹session›" origin chip (sibling navigation is explicit future
work); pinned messages gain a metadata-row pin glyph; edit sheet, draft
attachment strip, quick-action pills, audio waveform player, link previews,
handoff chips, memory/context indicators, and all management Forms are token
restyles; embedding-model selection and video-gen management are deliberately
out of scope; Architect/Diagnostics/inspectors are diagnostic-exempt.

## 13. Shipping shape

- **Unit 1 — token refactor.** Own PR: pure internal rewiring, zero visual
  change; characterization tests lock today's appearance. Independently
  valuable.
- **Unit 2 — the visual overhaul.** Glass chrome, new default styles, style
  protocols + part renderer, composer/picker redesign, state screens,
  connected services, and the classic presets are **one feature** — built as
  a stacked draft series and merged as a single unit (no phased splits; no
  intermediate PR ships a half-flipped default). Docs and tests ship inside
  each unit.
