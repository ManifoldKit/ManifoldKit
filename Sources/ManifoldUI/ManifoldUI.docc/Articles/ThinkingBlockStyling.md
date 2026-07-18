# Thinking Block Styling

Restyle the reasoning disclosure across its three lifecycle states.

## Overview

``ThinkingBlockStyle`` draws one reasoning (thinking-block) disclosure. ``ThinkingBlockState`` is exactly three cases — ``ThinkingBlockState/streaming``, ``ThinkingBlockState/settled(duration:)``, ``ThinkingBlockState/expanded(duration:)`` — matching the spec's shimmer-preview → "Thought for Ns" → hairline-rule-trace lifecycle (`docs/UI-REFRESH-2026.md` §4A). `duration` is best-effort wall-clock time; a block never observed streaming (e.g. loaded already-settled from persisted history) reports `0`.

```swift
import SwiftUI
import ManifoldUI

struct CaptionThinkingBlockStyle: ThinkingBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        switch configuration.state {
        case .streaming:
            Text("Thinking…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .settled(let duration), .expanded(let duration):
            Button {
                configuration.toggleExpanded()
            } label: {
                Text(duration > 0 ? "Thought for \(Int(duration))s" : "Reasoning")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
```

`toggleExpanded` flips between ``ThinkingBlockState/settled(duration:)`` and ``ThinkingBlockState/expanded(duration:)`` — the call site (`ThinkingBlockView`) owns the actual `@State`, so a style only ever reads a snapshot and calls the closure, mirroring how `DisclosureGroup` separates its binding from its label/content builders.

Install with `.thinkingBlockStyle(_:)`. Two built-ins ship: ``PlainThinkingBlockStyle`` (`.plain`, the default — reproduces the framework's historical "Thinking…"/"Reasoning" disclosure) and ``ShimmerThinkingBlockStyle`` (`.shimmer`, the 2026 refresh's design).

## Topics

- ``ThinkingBlockStyle``
- ``ThinkingBlockConfiguration``
- ``ThinkingBlockState``
- ``PlainThinkingBlockStyle``
- ``ShimmerThinkingBlockStyle``
