# Background Task Support

Continue in-flight generation turns after your app moves to background.

## Overview

iOS 26 introduces `BGContinuedProcessingTask`, allowing a user-triggered inference
turn to complete after the app moves to background. Cleanly cancelling any
still-in-flight turns when that continued-processing window expires is a
plain `ConversationRuntime` capability — no extra type to construct.

> Note: ManifoldKit also ships an internal helper, `ConversationRuntimeBackgroundBridge`,
> that wraps the same call for `BGContinuedProcessingTask.expirationHandler`'s
> synchronous signature. It is `package`-visibility only (2026-07 residual
> sweep, D.3) — zero host apps across all six consumer repos constructed it,
> so it is not part of the public surface. The recipe below reproduces its
> one line of logic directly; no host-facing capability was lost. See
> `docs/MIGRATION-api-demotions-0.71.md` § D.2+D.3.

## Setup

### 1. Register the task identifier

Add `BGTaskSchedulerPermittedIdentifiers` to your `Info.plist` with a
string of your choosing, for example:

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.example.myapp.continueGeneration</string>
</array>
```

### 2. Submit the task

`BGContinuedProcessingTask.expirationHandler` is synchronous, but
``ConversationRuntime/cancelAllTurns()`` is `async` — fire a detached task to
close the gap. The runtime is captured strongly because expiration MUST
complete; a `[weak conversationRuntime]` capture could let the runtime be
released before cancellation finishes, silently dropping in-flight turns.

```swift,no-build
import BackgroundTasks
import ManifoldRuntime

func applicationDidEnterBackground() {
    let task = BGContinuedProcessingTask(identifier: "com.example.myapp.continueGeneration")
    task.expirationHandler = { [conversationRuntime] in
        Task.detached {
            await conversationRuntime.cancelAllTurns()
        }
    }
    BGTaskScheduler.shared.submit(task, toQueue: nil)
}
```

### 3. Backend selection

Background GPU access is iPad-only. Check `BGTaskScheduler.supportedResources`
before relying on the MLX backend (from the `manifold-mlx` companion package):

```swift,no-build
if #available(iOS 26, *), BGTaskScheduler.supportedResources.contains(.gpu) {
    // GPU available — the MLX backend (manifold-mlx companion package) runs at full speed
} else {
    // iPhone or unsupported iPad: GPU unavailable.
    // The llama.cpp backend (manifold-llama companion package, CPU) degrades ~4–5× vs. foreground MLX.
    // Consider not submitting the task on iPhone if speed is critical.
}
```

## macOS

macOS apps retain GPU access when backgrounded without any special entitlement.
No `BGContinuedProcessingTask` setup is needed on macOS.
