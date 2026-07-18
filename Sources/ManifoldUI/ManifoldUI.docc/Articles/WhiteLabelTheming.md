# White-Label Your Chat

A worked example: re-theme ManifoldKit's default chat surface into a fictional brand, using only the public theming surface.

## Overview

This recipe swaps every layer <doc:Theming> describes — tokens, one component style, geometry — for a fake brand called "Aurora." It is deliberately small: a real brand swap is almost always this shape (a custom ``ManifoldTheme`` plus, at most, one or two custom style-protocol conformances for anything the token layer alone can't express).

### 1. Build the brand's `ManifoldTheme`

Every token defaults to the framework's current look, so you only override what the brand actually changes. `accent` should stay `Color.accentColor` unless the brand deliberately wants a fixed hue instead of the host app's own tint (uncommon — most brands want their own accent to shine through, which `Color.accentColor` already gives them via the asset catalog).

```swift
import SwiftUI
import ManifoldUI

func auroraTheme() -> ManifoldTheme {
    var theme = ManifoldTheme.standard
    theme.chatTheme.userBubbleBackground = AnyShapeStyle(
        LinearGradient(
            colors: [Color(red: 0.36, green: 0.20, blue: 0.62), Color(red: 0.62, green: 0.31, blue: 0.71)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    )
    theme.surface = AnyShapeStyle(Color(red: 0.36, green: 0.20, blue: 0.62).opacity(0.08))
    theme.statusOK = AnyShapeStyle(Color(red: 0.20, green: 0.62, blue: 0.45))
    theme.statusOKColor = Color(red: 0.20, green: 0.62, blue: 0.45)
    theme.shape = ManifoldThemeShapeScale(xs: 4, sm: 8, md: 12, lg: 18)
    return theme
}
```

### 2. One custom component style, if the token layer can't express it

Most brand swaps stop at step 1 — bubbles, the composer capsule, tool cards, and session rows all read the tokens above automatically through the built-in styles. Reach for a custom ``ToolInvocationStyle``/``ComposerStyle``/etc. conformance only when the brand wants *structure* the built-ins don't offer (a different disclosure shape, a logo mark, …):

```swift
import SwiftUI
import ManifoldUI

struct AuroraToolInvocationStyle: ToolInvocationStyle {
    func makeBody(configuration: ToolInvocationConfiguration) -> some View {
        AuroraToolInvocationBody(configuration: configuration)
    }
}

private struct AuroraToolInvocationBody: View {
    let configuration: ToolInvocationConfiguration
    @Environment(\.manifoldTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(theme.accent)
            Text(configuration.toolName)
                .font(theme.type.caption.monospaced())
                .foregroundStyle(theme.ink2)
        }
        .padding(8)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.shape.sm, style: .continuous))
    }
}
```

### 3. Apply everything at the chat root

Both layers cascade like any other environment value — one call at the root reaches every bubble, composer, tool card, and sidebar row below it:

```swift
import SwiftUI
import ManifoldUI

// (auroraTheme() and AuroraToolInvocationStyle from steps 1–2, repeated here
// so this snippet compiles standalone — in your app they live wherever your
// theming code lives.)
func auroraTheme() -> ManifoldTheme {
    var theme = ManifoldTheme.standard
    theme.surface = AnyShapeStyle(Color.purple.opacity(0.08))
    return theme
}

struct AuroraToolInvocationStyle: ToolInvocationStyle {
    func makeBody(configuration: ToolInvocationConfiguration) -> some View {
        Text(configuration.toolName)
    }
}

struct AuroraChatScreen: View {
    @Binding var showModelManagement: Bool

    var body: some View {
        ChatView(showModelManagement: $showModelManagement)
            .manifoldTheme(auroraTheme())
            .toolInvocationStyle(AuroraToolInvocationStyle())
    }
}
```

That's the whole recipe. No view was forked, no protocol was widened, and every other surface (composer, reasoning, session rows) still reads the shared `ManifoldTheme` you built in step 1 even though only one of them (`ToolInvocationStyle`) got a fully custom conformance.

### Restoring the framework's classic look, for comparison

If Aurora ever wants the pre-2026-refresh chrome instead of a new brand, that's the one-call restore <doc:Theming> and `docs/MIGRATION-ui-refresh.md` document:

```swift
import SwiftUI
import ManifoldUI

struct ClassicChatScreen: View {
    @Binding var showModelManagement: Bool

    var body: some View {
        ChatView(showModelManagement: $showModelManagement)
            .classicManifoldTheme()
    }
}
```

## See Also

- <doc:Theming> — the full token/style-protocol map this recipe draws from.
- ``ManifoldTheme/classic``, ``ChatTheme/classic`` — the pre-refresh preset values.
