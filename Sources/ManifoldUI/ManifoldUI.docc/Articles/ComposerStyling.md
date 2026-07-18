# Composer Styling

Restyle the chat composer's container chrome without rebuilding its "+" menu, attachments, or send/stop logic.

## Overview

**Live** (Unit 2 §L3, issue #2307): `ChatInputBar` reads `\.composerStyle` and
dispatches through it, so applying `.composerStyle(_:)` changes what actually
renders at the bottom of the chat.

``ComposerStyle`` owns the composer's *container* — background, shape, padding, and whether the "+" menu / send-stop affordances share that container with the field. ``ComposerConfiguration/content`` is the text-entry field alone; ``ComposerConfiguration/affordances`` is the "+" menu / regenerate / send-stop row, kept as a separate type-erased slot so a style can choose to enclose it (one glass capsule) or leave it a sibling (the classic layout). The draft-attachment strip and quick-action pills render in `ChatInputBar`'s accessory band above the styled composer and never pass through this seam.

A style receives the current ``ComposerPhase`` (`idle` / `composing` / `generating` / `voice`) and whether the draft-attachment strip has content, so it can adapt container geometry — e.g. a taller accessory band while `.voice` — without knowing anything about attachments or voice wiring itself.

```swift
import SwiftUI
import ManifoldUI

struct RoundedComposerStyle: ComposerStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.content
            configuration.affordances
        }
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

Two built-ins ship: ``PlainComposerStyle`` (`.plain`, the default — reproduces `ChatInputBar`'s historical layout, field wrapped in `.padding(10)` over a `ManifoldTheme.surface`-filled `RoundedRectangle(cornerRadius: 12)` with the affordances beside it, byte-for-byte) and ``GlassComposerStyle`` (`.glass`, the 2026 refresh's floating glass capsule/docked bar enclosing field + affordances in one container).

## Topics

- ``ComposerStyle``
- ``ComposerConfiguration``
- ``ComposerPhase``
- ``PlainComposerStyle``
- ``GlassComposerStyle``
