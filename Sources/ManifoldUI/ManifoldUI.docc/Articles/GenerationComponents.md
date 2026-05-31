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

## Registering tool sources

Use `ManifoldBootstrap.addToolSources(_:)` to register generation tool sources after `quickStart()`:

```swift,no-build
await kit.bootstrap.addToolSources([
    ImageGenerationToolSource(viewModel: kit.viewModel),
    VideoGenerationToolSource(viewModel: kit.viewModel)
])
```

This replaces the more verbose `conversationRuntime.updateSessionToolSources(_:)` call.

### Prerequisites

Both tool sources require their corresponding generation runtimes to be wired into the bootstrap before installation:

- ``ImageGenerationToolSource`` — requires an ``ImageGenerationRuntime`` wired via `ManifoldBootstrap.build(imageGenerationService:)`.
- ``VideoGenerationToolSource`` — requires a ``VideoGenerationRuntime`` wired into ``ChatViewModel``.

If a generation runtime is absent, the tool source is safe to register — the underlying `ChatViewModel` call will surface an error through ``ChatViewModel/backgroundTaskError`` rather than crashing.

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
