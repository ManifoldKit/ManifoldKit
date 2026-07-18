# Composer Styling

Restyle the chat composer's container chrome without rebuilding its "+" menu, attachments, or send/stop logic.

## Overview

``ComposerStyle`` owns only the composer's *container* — background, shape, padding — the same split ``MessageBubbleStyle`` uses for bubbles. `ChatInputBar` assembles the field, attachment gating, and send/stop button, then hands the fully-built content to your style as a type-erased ``ComposerConfiguration/content``.

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

Two built-ins ship: ``PlainComposerStyle`` (`.plain`, the default — reproduces the framework's historical rounded-rectangle field background) and ``GlassComposerStyle`` (`.glass`, the 2026 refresh's floating glass capsule/docked bar).

## Topics

- ``ComposerStyle``
- ``ComposerConfiguration``
- ``ComposerPhase``
- ``PlainComposerStyle``
- ``GlassComposerStyle``
