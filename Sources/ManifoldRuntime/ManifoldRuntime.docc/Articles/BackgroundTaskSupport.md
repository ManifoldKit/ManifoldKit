# Background Task Support

Continue in-flight generation turns after your app moves to background.

## Overview

iOS 26 introduces `BGContinuedProcessingTask`, allowing a user-triggered inference
turn to complete after the app moves to background. ManifoldKit provides
``ConversationRuntimeBackgroundBridge`` to bridge the synchronous expiration handler
into ``ConversationRuntime``'s async cancellation path.

## Setup

### 1. Register the task identifier

Add `BGTaskSchedulerPermittedIdentifiers` to your `Info.plist`:

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.manifoldkit.runtime.continueGeneration</string>
</array>
```

Or use `ManifoldBackgroundTaskIdentifiers.continueGeneration` as the string.

### 2. Submit the task

```swift,no-build
import BackgroundTasks
import ManifoldRuntime

func applicationDidEnterBackground() {
    let task = BGContinuedProcessingTask(identifier: ManifoldBackgroundTaskIdentifiers.continueGeneration)
    let bridge = ConversationRuntimeBackgroundBridge(runtime: conversationRuntime)
    task.expirationHandler = { bridge.handleExpiration() }
    BGTaskScheduler.shared.submit(task, toQueue: nil)
}
```

### 3. Backend selection

Background GPU access is iPad-only. Check availability before relying on ``MLXBackend``:

```swift,no-build
if #available(iOS 26, *), ConversationRuntimeBackgroundBridge.backgroundGPUAvailable {
    // GPU available — MLXBackend will run at full speed
} else {
    // iPhone or unsupported iPad: GPU unavailable.
    // ManifoldLlama (CPU) degrades ~4–5× vs. foreground MLX.
    // Consider not submitting the task on iPhone if speed is critical.
}
```

## macOS

macOS apps retain GPU access when backgrounded without any special entitlement.
No `BGContinuedProcessingTask` setup is needed on macOS.
