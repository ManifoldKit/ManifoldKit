# Generation Components

Add image generation, video generation, and photo attachment to your chat interface.

## Overview

ManifoldKit ships three composable components for building generative chat experiences: ``PhotoAttachmentButton`` lets users attach photos from their library, and ``ImageGenerationToolSource`` / ``VideoGenerationToolSource`` expose generation as callable tools that the language model can invoke autonomously. Wire them together or use each independently.

## Photo Attachment

``PhotoAttachmentButton`` wraps a `PhotosPicker` and stages the selected image on ``ChatViewModel`` using ``ChatViewModel/stageAttachment(_:)``. The staged image is sent as a ``MessagePart/image(data:mimeType:placeholderHash:)`` part alongside the next user message.

Place it in the `composerAccessory` slot of ``ChatView``:

```swift,no-build
ChatView(showModelManagement: $show, composerAccessory: {
    PhotoAttachmentButton()
})
```

Combine it with ``VoiceComposerAccessory`` when your app supports both modalities:

```swift,no-build
ChatView(showModelManagement: $show, composerAccessory: {
    HStack {
        PhotoAttachmentButton()
        VoiceComposerAccessory(controller: controller)
    }
})
```

The button tint changes to ``Color/accentColor`` when an image is already staged, giving the user visual confirmation without requiring a separate indicator view. ``PhotoAttachmentButton/clearSelection()`` resets both the picker state and the staged attachment — useful when the host needs to programmatically cancel an in-progress compose operation.

> Note: ``PhotoAttachmentButton`` is iOS-only. It is compiled under `#if os(iOS)` and is not available on macOS or visionOS.

## Cross-Platform Vision Input

``VisionInputButton`` is the recommended image-attachment button for apps that target both iOS and macOS. On iOS it presents the system `PhotosPicker`; on macOS it opens an `NSOpenPanel` restricted to image file types. In both cases the selected image is staged on ``ChatViewModel`` via ``ChatViewModel/stageAttachment(_:)`` and sent as a ``MessagePart/image(data:mimeType:placeholderHash:)`` part with the next user message.

``VisionInputButton`` hides itself automatically when the active backend does not report ``BackendCapabilities/supportsVision`` — no extra conditional logic is required in the host UI.

Place it in the `composerAccessory` slot of ``ChatView``:

```swift,no-build
ChatView(showModelManagement: $show, composerAccessory: {
    VisionInputButton()
})
```

Combine it with ``VoiceComposerAccessory`` when your app supports both modalities:

```swift,no-build
ChatView(showModelManagement: $show, composerAccessory: {
    HStack {
        VisionInputButton()
        VoiceComposerAccessory(controller: controller)
    }
})
```

> Note: ``PhotoAttachmentButton`` is iOS-only and predates this component. New code should prefer ``VisionInputButton``, which compiles on both iOS and macOS.

## Tool Sources

``ImageGenerationToolSource`` and ``VideoGenerationToolSource`` conform to `SessionToolSource` and advertise `generate_image` and `generate_video` tools respectively to the language model. Register them via `ConversationRuntime.updateSessionToolSources(_:)` after the bootstrap and view model are wired:

```swift,no-build
let imageToolSource = ImageGenerationToolSource(viewModel: kit.viewModel)
await kit.bootstrap.conversationRuntime.updateSessionToolSources([imageToolSource])
```

Register both sources to enable the full generation surface:

```swift,no-build
let imageToolSource = ImageGenerationToolSource(viewModel: chatVM)
let videoToolSource = VideoGenerationToolSource(viewModel: chatVM)
await bootstrap.conversationRuntime.updateSessionToolSources([imageToolSource, videoToolSource])
```

Once registered, the model will call `generate_image` or `generate_video` autonomously when the user asks it to create visual content — the result appears inline as a chat message with no additional user interaction required.

### Image generation

``ImageGenerationToolSource`` delegates to ``ChatViewModel/generateImage(prompt:config:)`` when the model calls `generate_image`. The generated image surfaces in the conversation the same way as one triggered directly by the user.

### Video generation

``VideoGenerationToolSource`` delegates to ``ChatViewModel/generateVideo(prompt:config:)`` using a fire-and-forget detached `Task`. ``VideoGenerationToolSource/resolve(toolName:arguments:session:)`` returns immediately — video generation is long-running (typically 30–60 seconds) and must not block the conversation turn executor. Progress and the completed video surface through ``ChatViewModel/videoGenerationProgress`` exactly as if the user had triggered generation directly.

### Web search

``WebSearchToolSource`` delegates to ``ChatViewModel/searchWeb(query:)`` when the model calls `search_web`. Unlike image and video — which insert a placeholder message and surface results asynchronously — web search is request/response: ``WebSearchToolSource/resolve(toolName:arguments:session:)`` awaits the search and returns the result text directly to the model inside the same conversation turn.

Like the image/video tool sources, ``WebSearchToolSource`` is a thin forwarder with no network or cloud dependency. The actual HTTP call lives in the concrete ``WebSearchRuntime`` implementation (`DefaultWebSearchRuntime`, in `ManifoldCloudCore`), which the host wires via ``ChatViewModel/configure(webSearchRuntime:)``. This keeps `ManifoldUI` free of `URLSession` and backend-family imports.

## Registering tool sources

When importing `ManifoldKit` (the umbrella module), use the one-liner convenience:

```swift,no-build
// One call registers whichever generation services are wired in the bootstrap.
// Sources for nil services are silently skipped.
await kit.bootstrap.addGenerationToolSources(viewModel: kit.viewModel)
```

For apps that import `ManifoldPersistenceSwiftData` directly (without the umbrella), use `addToolSources(_:)`:

```swift,no-build
await kit.bootstrap.addToolSources([
    ImageGenerationToolSource(viewModel: kit.viewModel),
    VideoGenerationToolSource(viewModel: kit.viewModel),
    WebSearchToolSource(viewModel: kit.viewModel)
])
```

Both calls replace the more verbose `conversationRuntime.updateSessionToolSources(_:)` call.

### Prerequisites

Each tool source requires its corresponding generation runtime to be wired into the bootstrap before installation:

- ``ImageGenerationToolSource`` — requires an ``ImageGenerationRuntime`` wired via `ManifoldBootstrap.build(imageGenerationService:)`.
- ``VideoGenerationToolSource`` — requires a ``VideoGenerationRuntime`` wired into ``ChatViewModel``.
- ``WebSearchToolSource`` — requires a ``WebSearchRuntime`` (e.g. `DefaultWebSearchRuntime` from `ManifoldCloudCore`) wired via `ManifoldBootstrap(webSearchRuntime:)` or ``ChatViewModel/configure(webSearchRuntime:)``.

`addGenerationToolSources(viewModel:)` silently skips sources whose corresponding service is absent, so it is safe to call unconditionally — no conditional check required at the call site.

## Context Menu Items

``GenerativeContextMenuItems`` surfaces generation actions directly in the
long-press context menu of each chat bubble. Pass it to ``ChatView`` via the
`contextMenuItems` trailing closure:

```swift,no-build
ChatView(showModelManagement: $show) { message in
    GenerativeContextMenuItems(message: message, viewModel: viewModel)
}
```

Items appear conditionally based on the message content and which runtimes are
configured on the view model:

- **Generate Image from This** — shown when the message has text content and
  an ``ImageGenerationRuntime`` is wired via
  ``ChatViewModel/configure(imageRuntime:)``.
- **Generate Video from This** — shown when the message has text content and a
  ``VideoGenerationRuntime`` is wired via
  ``ChatViewModel/configure(videoRuntime:)``.
- **Remix Image** — shown when the message contains a generated image part and
  an ``ImageGenerationRuntime`` is configured. Re-triggers image generation
  using the original prompt (or the message text as a fallback).
- **Animate as Video** — shown when the message contains a generated image part
  and a ``VideoGenerationRuntime`` is configured. Submits the original image
  prompt for video generation in image-to-video mode.

``GenerativeContextMenuItems`` reads ``ChatViewModel/imageRuntime`` and
``ChatViewModel/videoRuntime`` at render time, so items appear and disappear
automatically if runtimes are added or removed at runtime — no additional
configuration is required beyond wiring the runtimes.

> Note: ``GenerativeContextMenuItems`` does not show menu items for runtimes
> that are absent. An app that wires only an ``ImageGenerationRuntime`` will
> never see the video items, and vice versa. This makes it safe to register
> ``GenerativeContextMenuItems`` unconditionally regardless of which generation
> surface your app supports.

## Spotlight Indexing

`SpotlightIndexer` indexes chat sessions in iOS/macOS Core Spotlight so users can find and open conversations from system search:

```swift,no-build
// After loading sessions:
await SpotlightIndexer.index(sessions: kit.sessionManager.sessions)

// On session list changes:
.onChange(of: kit.sessionManager.sessions) { _, sessions in
    Task { await SpotlightIndexer.index(sessions: sessions) }
}

// On sign-out:
SpotlightIndexer.deleteAll()

// Handle Spotlight tap (in App.onContinueUserActivity):
if let id = SpotlightIndexer.sessionID(from: userActivity) {
    // switch to that session
}
```
