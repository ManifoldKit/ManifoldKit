# ManifoldKit Video-Gen Quickstart

A one-page tutorial for adding cloud video generation to any Swift app. Unlike
on-device image generation, `VideoGenerationBackend` is cloud-only by design —
requests are submitted to a remote API, polled for progress, and the finished
video is downloaded to a local file. No model loading step; the service is
always "ready" from construction time.

> **Platform.** iOS 18+ / macOS 15+. Video generation requires a cloud backend
> — there is no on-device video model supported today. Bring your own backend
> conformer (or use one from `ManifoldCloud` when available).

---

## 1. Prerequisites

Add `ManifoldKit` to your consumer `Package.swift`. No extra traits are needed
for video generation — the `VideoGenerationBackend` protocol, config types, and
runtime all ship in `ManifoldInference` and `ManifoldRuntime`, which are in the
default dependency graph.

```swift,no-build
dependencies: [
    .package(
        url: "https://github.com/roryford/ManifoldKit.git",
        from: "0.45.0" // x-release-please-version
    ),
],
targets: [
    .target(
        name: "MyVideoApp",
        dependencies: [
            .product(name: "ManifoldKit", package: "ManifoldKit"),
            // For UI: also import ManifoldUI (already in ManifoldKit umbrella)
        ]
    ),
],
```

If you are building a non-SwiftUI CLI or server consumer, depend on
`ManifoldInference` and `ManifoldRuntime` individually instead of the umbrella.

---

## 2. Implement `VideoGenerationBackend`

`VideoGenerationBackend` is the protocol every cloud video service must
conform to. It lives in `ManifoldInference`. You supply one conformer per
service provider.

```swift,no-build
import Foundation
import ManifoldInference

/// Minimal stub — replace HTTP calls with your real API.
final class MyVideoBackend: VideoGenerationBackend {

    private var pollTask: Task<Void, Never>?

    /// Submits the job and begins polling. Throws on auth / rate-limit / network
    /// errors before the stream starts.
    func generate(
        prompt: String,
        config: VideoGenerationConfig
    ) async throws -> AsyncThrowingStream<VideoGenerationEvent, Error> {
        // 1. Submit to the cloud API. A real implementation would make an HTTP
        //    POST and extract a job ID from the response.
        let jobID = try await submitJob(prompt: prompt, config: config)

        return AsyncThrowingStream { continuation in
            // 2. Poll until done. The backend owns the poll loop; the runtime
            //    calls `cancel()` to tear it down.
            self.pollTask = Task.detached(priority: .userInitiated) {
                do {
                    continuation.yield(.queued)
                    while true {
                        try Task.checkCancellation()
                        let status = try await self.pollStatus(jobID: jobID)
                        switch status {
                        case .queued:
                            continuation.yield(.queued)
                        case .generating(let fraction):
                            continuation.yield(.generating(fractionComplete: fraction))
                        case .done(let remoteURL):
                            let localURL = try await self.download(from: remoteURL)
                            continuation.yield(.completed(localURL))
                            continuation.finish()
                            return
                        }
                        try await Task.sleep(for: .seconds(2))
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] _ in
                self?.pollTask?.cancel()
            }
        }
    }

    func cancel() async {
        pollTask?.cancel()
        await pollTask?.value
    }

    // MARK: - Stubs (replace with real HTTP)
    private func submitJob(prompt: String, config: VideoGenerationConfig) async throws -> String { "job-123" }
    private enum StatusResult { case queued, generating(Double), done(URL) }
    private func pollStatus(jobID: String) async throws -> StatusResult { .done(FileManager.default.temporaryDirectory.appendingPathComponent("out.mp4")) }
    private func download(from url: URL) async throws -> URL { url }
}
```

For cloud backends that ride `SSECloudBackend` (OpenAI-compatible endpoints,
Anthropic), use the `configure(baseURL:tokenProvider:modelName:)` overload on
the concrete subclass instead of writing a custom `VideoGenerationBackend`
conformer — the SSE envelope handles polling and retries for you.

---

## 3. Wire via `ManifoldBootstrap`

Pass your backend to `VideoGenerationService`, then hand the service to
`ManifoldBootstrap`. The bootstrap constructs `VideoGenerationRuntime`
automatically and exposes it via `bootstrap.videoGenerationRuntime`.

```swift,no-build
import ManifoldKit
import ManifoldInference

let backend = MyVideoBackend()
let videoService = VideoGenerationService(backend: backend)

let config = ManifoldConfiguration(bundleIdentifier: "com.example.MyVideoApp")
let bootstrap = try ManifoldBootstrap(
    configuration: config,
    videoGenerationService: videoService
)
```

---

## 4. Configure `ChatViewModel`

`ManifoldBootstrap` pre-wires the runtime but does not install it on
`ChatViewModel` automatically. Call `configure(videoRuntime:)` after
constructing the view model (or use `ManifoldKit.quickStart()` which does
this via `RuntimeConfiguration`):

```swift,no-build
// If you're using the full bootstrap:
if let videoRuntime = bootstrap.videoGenerationRuntime {
    chatViewModel.configure(videoRuntime: videoRuntime)
}
```

After this call `chatViewModel.videoRuntime` is non-nil and
`chatViewModel.videoGenerationProgress` starts populating as generations
progress.

---

## 5. Trigger generation and observe progress

```swift,no-build
import SwiftUI
import ManifoldUI
import ManifoldInference

@MainActor
func requestVideo(viewModel: ChatViewModel) async throws {
    let config = VideoGenerationConfig(
        duration: 5,                                          // seconds
        aspectRatio: VideoGenerationConfig.AspectRatio.landscape, // "16:9"
        width: nil,                                           // nil → backend default
        height: nil
    )

    // `generateVideo` returns after the backend accepts the submission.
    // Progress events arrive asynchronously through `videoGenerationProgress`.
    try await viewModel.generateVideo(
        prompt: "a sun rising over misty mountains, cinematic, 4K",
        config: config
    )
}
```

Observe progress in a SwiftUI view by reading
`chatViewModel.videoGenerationProgress`, a `[UUID: VideoGenerationProgress]`
dictionary keyed by the placeholder message ID emitted when generation starts:

```swift,no-build
struct VideoProgressIndicator: View {
    @Environment(ChatViewModel.self) var viewModel

    var body: some View {
        ForEach(viewModel.videoGenerationProgress.values.sorted(by: { $0.prompt < $1.prompt }), id: \.messageID) { progress in
            ProgressView(
                progress.prompt,
                value: progress.fractionComplete,
                total: 1.0
            )
        }
    }
}
```

---

## 6. Complete runnable example

Below is a self-contained CLI-style harness. Swap `MyVideoBackend` for a real
implementation and run it from any Swift target.

```swift,no-build
import Foundation
import ManifoldInference

@main
struct VideoGen {
    static func main() async throws {
        let backend = MyVideoBackend()
        let service = VideoGenerationService(backend: backend)

        // `generate` submits the job and begins polling.
        let config = VideoGenerationConfig(
            duration: 5,
            aspectRatio: VideoGenerationConfig.AspectRatio.landscape
        )
        let stream = try await service.generate(
            prompt: "a red fox bounding through a snowy forest",
            config: config
        )

        // Iterate the stream. The terminal `.completed(url)` event carries
        // a local file URL. The file is fully written before the event is yielded.
        for try await event in stream {
            switch event {
            case .queued:
                print("queued — waiting for backend to start generation")
            case .generating(let fraction):
                let pct = Int(fraction * 100)
                print("generating … \(pct)%")
            case .completed(let url):
                print("done: \(url.path)")
            }
        }
    }
}
```

---

## `VideoGenerationConfig` reference

| Field | Type | Default | Notes |
|---|---|---|---|
| `duration` | `Int` | `5` | Duration in seconds. Backend enforces min/max. |
| `aspectRatio` | `String` | `"16:9"` | Use `AspectRatio` constants or any string your backend accepts. |
| `width` | `Int?` | `nil` | Explicit pixel width. `nil` → backend default. |
| `height` | `Int?` | `nil` | Explicit pixel height. `nil` → backend default. |
| `sourceImageURL` | `URL?` | `nil` | Local file URL for image-to-video mode. |

`AspectRatio` constants: `landscape` (`"16:9"`), `portrait` (`"9:16"`),
`square` (`"1:1"`), `wide` (`"4:3"`), `tall` (`"3:4"`).

---

## `VideoGenerationEvent` reference

| Case | When |
|---|---|
| `.queued` | Request accepted; backend has not started generating yet. |
| `.generating(fractionComplete:)` | In progress. `fractionComplete` is 0.0–1.0; clamp before display. |
| `.completed(URL)` | Finished. `URL` is a local file URL; the file is fully written. |

If download fails after the cloud generation completes, the stream terminates
with a thrown error instead of emitting `.completed`.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `VideoGenerationServiceError.alreadyGenerating` | A generation is still in flight. Await or cancel the current generation before starting a new one. |
| `generateVideo` throws `.notConfigured` | `configure(videoRuntime:)` was not called on `ChatViewModel`. See §4. |
| Stream finishes without `.completed` and without throwing | The generation was cancelled (task cancellation or `cancel(messageID:)` from the runtime). |
| Backend hangs at `.queued` indefinitely | The poll interval may be too short for your quota tier, or the backend is rate-limiting. Implement exponential backoff in your poll loop. |
