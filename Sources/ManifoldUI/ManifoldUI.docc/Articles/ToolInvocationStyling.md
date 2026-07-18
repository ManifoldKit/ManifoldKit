# Tool Invocation Styling

Restyle the tool-call card across its four lifecycle states.

## Overview

``ToolInvocationStyle`` draws one tool-call card. ``ToolInvocationLifecycleState`` mirrors `ToolInvocationView.State`'s four states — `awaitingApproval → running → completed | failed` (`docs/UI-REFRESH-2026.md` §4) — carried on ``ToolInvocationConfiguration`` alongside the tool name, arguments, result content, and the approval/reauthentication closures.

```swift
import SwiftUI
import ManifoldUI

struct PillToolInvocationStyle: ToolInvocationStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            if configuration.state == .running {
                ProgressView().controlSize(.mini)
            }
            Text(configuration.toolName)
                .font(.caption.monospaced())
            if configuration.state == .awaitingApproval {
                Button("Approve") { configuration.onApprove?() }
                Button("Deny") { configuration.onDeny?(nil) }
            }
        }
        .padding(8)
        .background(.thinMaterial, in: Capsule())
    }
}
```

Install with `.toolInvocationStyle(_:)`. Two built-ins ship: ``PlainToolInvocationStyle`` (`.plain`, the `.classic` preset — reproduces `ToolInvocationView`'s historical chrome for all four states) and ``CardToolInvocationStyle`` (`.card`, the built-in default since Unit 2 §L5's defaults flip — the 2026 refresh's design, reading status colors from ``ManifoldTheme`` instead of the literal `.orange` the pre-refresh failed-state chip used, and rendering the same approve/deny/reauthenticate controls ``PlainToolInvocationStyle`` does).

The MCP reauthenticate hook (spec §4) surfaces through ``ToolInvocationConfiguration/onReauthenticate`` when a failed result's ``ToolErrorPresentation/reauthenticationCTA`` is non-nil — a style is responsible for rendering the CTA if it wants to surface it.

## Topics

- ``ToolInvocationStyle``
- ``ToolInvocationConfiguration``
- ``ToolInvocationLifecycleState``
- ``PlainToolInvocationStyle``
- ``CardToolInvocationStyle``
