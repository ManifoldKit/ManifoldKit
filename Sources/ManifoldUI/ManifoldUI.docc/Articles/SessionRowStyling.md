# Session Row Styling

Restyle the sidebar's per-row content without touching system selection chrome.

## Overview

``SessionRowStyle`` styles a session row's *content* only — title, snippet, and the quiet pin/selection cues. Per `docs/UI-REFRESH-2026.md` §2, row *selection* and vibrancy stay system-owned: `SessionListView`'s `List(selection:)` drives the actual highlight on every platform, so a style must not attempt to redraw it.

```swift
import SwiftUI
import ManifoldUI

struct BadgeSessionRowStyle: SessionRowStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(configuration.title).font(.headline).lineLimit(1)
                if let snippet = configuration.snippet {
                    Text(snippet).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if configuration.isPinned {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
```

Install with `.sessionRowStyle(_:)`. Two built-ins ship: ``PlainSessionRowStyle`` (`.plain`, the `.classic` preset — reproduces `SessionRowView`'s historical title-over-relative-timestamp layout) and ``QuietSessionRowStyle`` (`.quiet`, the built-in default since Unit 2 §L5's defaults flip — the 2026 refresh's design, adding the pin glyph and snippet line spec §6 calls for).

``SessionRowConfiguration/updatedAt`` is a `Date`, not a pre-formatted string, so a style can render it with `Text(_:style:.relative)` and keep the live-updating "5m ago" behavior the pre-refresh view already had.

## Topics

- ``SessionRowStyle``
- ``SessionRowConfiguration``
- ``PlainSessionRowStyle``
- ``QuietSessionRowStyle``
