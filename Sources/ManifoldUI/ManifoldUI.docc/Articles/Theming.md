# Theming the Chat UI

Restyle bubbles, brand colors, and per-message rendering without forking the chat view.

## Overview

ManifoldUI ships an opinionated default look, but every styling decision is an override seam. Customization comes in three composable layers, ranked from cheapest to most powerful:

1. **``ChatTheme`` tokens** — change colors, fonts, padding, and corner radius app-wide.
2. **``MessageBubbleStyle``** — restructure the bubble container (shape, background, padding) per role.
3. **The per-message renderer slot** — take over rendering for specific messages and fall through to the built-in bubble for the rest.

All three are additive. You can adopt one, two, or all three, and a consumer who adopts none keeps today's appearance byte-for-byte — ``ChatTheme/standard`` reproduces the historical look exactly, so the theming system is a zero-breaking-change addition.

Every layer is a thin semantic shell over SwiftUI's own resolution machinery. That is deliberate: colors flow through `ShapeStyle` (so asset-catalog colors get automatic Dark Mode and Increase Contrast), fonts are text styles (so Dynamic Type keeps scaling), and any metric that should grow with text size is multiplied by a `@ScaledMetric` factor at the point it is drawn. The litmus test for any theme you write: toggle Dark Mode, max Dynamic Type, and Increase Contrast — nothing should stay fixed.

## Layer 1 — ChatTheme tokens

``ChatTheme`` is a `Sendable` struct of semantic tokens. Inject it with the `.chatTheme(_:)` modifier; it cascades through the environment like `.tint(_:)` or `.font(_:)`, so a single call at the chat root reaches every bubble.

```swift
ChatView(showModelManagement: $showModels) { APIConfigurationView() }
    .chatTheme(
        ChatTheme(
            userBubbleBackground: AnyShapeStyle(Color.indigo),
            cornerRadius: 22,
            bubblePadding: 14
        )
    )
```

Each token defaults to the framework's historical value, so you override only what you care about. Colors are stored as `AnyShapeStyle`, which means a token can be a flat `Color`, a material, or a hierarchical fill such as `.fill.tertiary` (the default assistant background).

> Tip: Prefer asset-catalog colors (`Color("BrandAccent")`) over literal `Color(red:green:blue:)`. Asset colors carry Dark Mode and high-contrast variants for free; a hard-coded RGB value does not.

## Layer 2 — MessageBubbleStyle

When you need to restructure the bubble *container* — a different shape, border, or shadow — conform to ``MessageBubbleStyle``. It follows Apple's `ButtonStyle` recipe: implement `makeBody(configuration:)`, read any `@Environment` you need from the returned view, and install it with `.messageBubbleStyle(_:)`.

Three built-ins ship, exposed as static members the way Apple ships `.bordered`:

```swift
ChatView(showModelManagement: $showModels) { APIConfigurationView() }
    .messageBubbleStyle(.iMessage)   // .plain (default), .iMessage, or .card
```

The default ``PlainMessageBubbleStyle`` reads the active ``ChatTheme``, which is why Layers 1 and 2 compose: set your brand colors with `.chatTheme(_:)` and `.plain` picks them up automatically.

A custom style receives a ``MessageBubbleConfiguration`` carrying the type-erased inner content, the sender ``ManifoldInference/MessageRole``, and whether the message is still streaming. It owns only the chrome — the rich inner content (message parts, agent badge, timestamps, streaming cursor) is built for you:

```swift
struct OutlineBubbleStyle: MessageBubbleStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.content
            .padding(12)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(configuration.role == .user ? .tint : .secondary)
            )
    }
}
```

Because `makeBody` returns a view, it can read `@Environment(\.colorScheme)`, the active ``ChatTheme``, and `@ScaledMetric` — keeping your style Dark-Mode- and Dynamic-Type-correct.

## Layer 3 — Per-message renderer slot

Sometimes one *kind* of message needs a bespoke view — a tool-call card, a rich receipt, a map. The `.chatMessageRenderer(_:)` modifier installs a closure that gets first refusal on every row. Handle the messages you care about and call `defaultMessageView()` for the rest:

```swift
ChatView(showModelManagement: $showModels) { APIConfigurationView() }
    .chatMessageRenderer { params in
        if case .toolResult = params.message.kind {
            AnyView(ToolResultCard(message: params.message))
        } else {
            params.defaultMessageView()   // built-in bubble, fully themed
        }
    }
```

This is the seam that BYO-UI consumers used to fork the whole message list to reach. The `defaultMessageView()` fallback is the key detail: you are never forced into all-or-nothing rendering. ``ChatMessageRenderParameters`` is an options struct, so future fields will not break your call site.

> Note: A finer-grained per-content-part hook (text / tool-call / thinking blocks) is not yet exposed; it is tracked for a future release. Layers 1–3 cover the vast majority of customization needs today.

## Accessibility checklist

- **Dark Mode** — use asset-catalog colors or system `ShapeStyle`s; avoid literal RGB.
- **Dynamic Type** — keep fonts as text styles; scale custom spacing with `@ScaledMetric`.
- **Increase Contrast** — system fills and `.separator`/`.secondary` styles adapt automatically; bespoke colors should be checked in the Accessibility Inspector.
- **VoiceOver** — the built-in bubble carries an `<Role> said: <content>` label; if you fully replace a message via Layer 3, supply your own `.accessibilityLabel`.

## Topics

### Layer 1 — Tokens
- ``ChatTheme``
- ``ResolvedBubbleChrome``

### Layer 2 — Bubble styles
- ``MessageBubbleStyle``
- ``MessageBubbleConfiguration``
- ``PlainMessageBubbleStyle``
- ``IMessageMessageBubbleStyle``
- ``CardMessageBubbleStyle``

### Layer 3 — Per-message rendering
- ``ChatMessageRenderParameters``
- ``ChatMessageRenderer``
