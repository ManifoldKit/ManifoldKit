# Composer Styling

Restyle the chat composer's container chrome without rebuilding its "+" menu, attachments, or send/stop logic.

## Overview

> Important: **Not yet wired.** `ChatInputBar` does not read `\.composerStyle`
> in this tranche (Unit 2 §L2, issue #2307) — it still draws its field chrome
> directly. Applying `.composerStyle(_:)` today compiles and installs the
> environment value, but it is a no-op until the composer redesign
> (Unit 2 §L3) restructures `ChatInputBar` to consume it. The protocol and
> built-in styles below are correct and tested in isolation now so that
> tranche can adopt them without redesigning this seam.

``ComposerStyle`` owns only the composer's *container* — background, shape, padding — the same split ``MessageBubbleStyle`` uses for bubbles. ``ComposerConfiguration/content`` is the text-entry field only (not the "+" menu, attachments, or send/stop button — those stay siblings the composer redesign assembles around the styled field).

A style receives the current ``ComposerPhase`` (`idle` / `composing` / `generating` / `voice`) and whether the draft-attachment strip has content, so it can adapt container geometry — e.g. a taller accessory band while `.voice` — without knowing anything about attachments or voice wiring itself.

```swift
import SwiftUI
import ManifoldUI

struct RoundedComposerStyle: ComposerStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.content
            .padding(configuration.phase == .voice ? 16 : 8)
            .background(.thinMaterial, in: Capsule())
    }
}
```

Install it the same way as ``MessageBubbleStyle``:

```swift,no-build
ChatView(showModelManagement: $showModels)
    .composerStyle(RoundedComposerStyle())
```

Two built-ins ship: ``PlainComposerStyle`` (`.plain`, the default — reproduces `ChatInputBar`'s historical field chrome, `.padding(10)` over a `ManifoldTheme.surface`-filled `RoundedRectangle(cornerRadius: 12)`, byte-for-byte) and ``GlassComposerStyle`` (`.glass`, the 2026 refresh's floating glass capsule/docked bar).

## Topics

- ``ComposerStyle``
- ``ComposerConfiguration``
- ``ComposerPhase``
- ``PlainComposerStyle``
- ``GlassComposerStyle``
