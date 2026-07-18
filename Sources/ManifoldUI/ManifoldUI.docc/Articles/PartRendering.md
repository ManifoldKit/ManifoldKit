# Per-Part Rendering

Take over one content part — a specific tool call, a generated-media kind — without forking the whole message.

## Overview

`.chatMessageRenderer(_:)` gives a host first refusal on an entire message. ``ChatMessagePartRenderer`` (issue #1640) is its finer-grained sibling: first refusal on one *content part* within a message's ``ManifoldRuntime/MessagePart`` array — a `.toolCall` for a specific tool, a `.generatedMedia` of a specific kind — while every other part in the same message still renders through the framework's built-in per-kind views.

```swift
import SwiftUI
import ManifoldUI
import ManifoldRuntime

@MainActor
func installWeatherCardRenderer<V: View>(_ content: V) -> some View {
    content.chatMessagePartRenderer { params in
        if case .toolCall(let call) = params.part, call.toolName == "get_weather" {
            AnyView(Text("Weather card for \(call.toolName)"))
        } else {
            params.defaultPartView()
        }
    }
}
```

``ChatMessagePartRenderParameters/defaultPartView()`` is the same fallthrough contract ``ChatMessageRenderParameters/defaultMessageView()`` has — you are never forced into all-or-nothing rendering for a message just because you want to restyle one tool call.

Like every other style/renderer slot, `.chatMessagePartRenderer(_:)` cascades LAST-WINS: nested calls resolve to whichever is closest to the leaf view, the same way `.font(_:)` does.

## Topics

- ``ChatMessagePartRenderParameters``
- ``ChatMessagePartRenderer``
