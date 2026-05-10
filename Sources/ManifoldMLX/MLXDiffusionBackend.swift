#if MLX

import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import ManifoldInference
import Hub
import MLX
import StableDiffusion

// MARK: - Errors

public enum MLXDiffusionError: Error, LocalizedError {
    case unsupportedModelLayout(URL)
    case insufficientMemory([ImageModelLoadPlan.Reason])
    case notLoaded
    case pngEncodingFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .unsupportedModelLayout(let url):
            return "Unrecognised diffusion layout at '\(url.lastPathComponent)'. Expected SD 2.1 Base or SDXL Turbo weights."
        case .insufficientMemory(let reasons):
            return "Insufficient memory: \(reasons.map { "\($0)" }.joined(separator: ", "))"
        case .notLoaded:
            return "No model loaded. Call loadModel(from:) first."
        case .pngEncodingFailed(let url):
            return "Failed to write PNG to \(url.path)."
        }
    }
}

// MARK: - MLXDiffusionBackend

/// An ``ImageGenerationBackend`` that drives on-device diffusion inference
/// via the `mlx-swift-examples` StableDiffusion library.
///
/// ## Supported layouts (auto-detected from directory contents)
///
/// - `stabilityai/stable-diffusion-2-1-base` — 512×512, single text encoder
/// - `stabilityai/sdxl-turbo` — 1024×1024, dual text encoder
///
/// Other layouts throw ``MLXDiffusionError/unsupportedModelLayout``.
///
/// ## PR 5 ↔ PR 6 alignment note
///
/// `HuggingFaceService.downloadDiffusionModel` stores weights with a slug-based
/// directory name (e.g. `stabilityai__sdxl-turbo`). The StableDiffusion library
/// resolves files via `HubApi.localRepoLocation`, which expects the Hub
/// convention `<downloadBase>/models/stabilityai/sdxl-turbo`. `loadModel(from:)`
/// bridges this via a temporary symlink. A follow-up PR can eliminate the
/// symlink by adopting Hub's directory convention in the download path.
///
/// ## Concurrency
///
/// Mirrors ``LlamaBackend``'s NSLock + `@unchecked Sendable` pattern. The
/// denoising loop is a long-running synchronous call (~6–10 s on Apple Silicon);
/// using an `Actor` would hold isolation across that span and block
/// `stopGeneration()` / `unloadModel()` from the main actor.
public final class MLXDiffusionBackend: ImageGenerationBackend, @unchecked Sendable {

    private let lock = NSLock()
    private var _generator: (any TextToImageGenerator)?
    private var _preset: StableDiffusionConfiguration?
    private var _isGenerating = false
    private var _stopRequested = false

    public init() {}

    // MARK: - Sync lock helper
    //
    // NSLock.lock() / .unlock() are marked @available(*, noasync) in Swift 6.
    // Wrapping them in a synchronous method avoids the diagnostic at call
    // sites in async functions — the restriction only fires at direct call
    // sites, not transitively through a sync helper.
    @discardableResult
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    // MARK: - ImageGenerationBackend

    public var isLoaded: Bool {
        withLock { _generator != nil }
    }

    public var isGenerating: Bool {
        withLock { _isGenerating }
    }

    public func loadModel(from url: URL) async throws {
        let preset = try Self.detectPreset(at: url)
        let inputs = try Self.loadPlanInputs(at: url, preset: preset)
        let plan = ImageModelLoadPlan.compute(inputs: inputs)
        if case .deny = plan.verdict {
            throw MLXDiffusionError.insufficientMemory(plan.reasons)
        }

        // Bridge slug-based download path to Hub's expected directory layout.
        let (hubBase, cleanup) = try Self.makeHubBridge(for: preset, pointing: url)
        defer { cleanup() }

        let hub = HubApi(downloadBase: hubBase, useOfflineMode: true)
        guard let generator = try preset.textToImageGenerator(
            hub: hub, configuration: .init(quantize: true)
        ) else {
            throw MLXDiffusionError.unsupportedModelLayout(url)
        }

        withLock {
            _generator = generator
            _preset = preset
            _stopRequested = false
        }
    }

    public func generate(
        prompt: String,
        config: ImageGenerationConfig
    ) throws -> AsyncThrowingStream<ImageGenerationEvent, Error> {
        // Capture generator + preset under lock before creating the stream.
        // Only `self` is captured into the @Sendable Task closure (the class
        // is @unchecked Sendable); generator/preset are re-read inside the task.
        let hasModel = withLock { _generator != nil && _preset != nil }
        guard hasModel else { throw MLXDiffusionError.notLoaded }
        withLock { _isGenerating = true; _stopRequested = false }

        return AsyncThrowingStream { [self] continuation in
            // Strong capture: generation owns a logical unit of work; weak
            // capture would silently drop events on dealloc.
            let task = Task.detached(priority: .userInitiated) { [self] in
                defer { self.withLock { self._isGenerating = false } }
                do {
                    // Re-read under lock — unloadModel() could have run, but
                    // _isGenerating=true prevents concurrent unload on the
                    // same thread. Guard anyway for safety.
                    guard let generator = self.withLock({ self._generator }),
                          let preset   = self.withLock({ self._preset }) else {
                        throw MLXDiffusionError.notLoaded
                    }
                    let params = Self.makeParams(prompt: prompt, config: config, preset: preset)
                    var iterator = generator.generateLatents(parameters: params)
                    let totalSteps = iterator.underestimatedCount

                    var step = 0
                    var lastLatent: MLXArray?

                    while let latent = iterator.next() {
                        try Task.checkCancellation()
                        let stopped = self.withLock { self._stopRequested }
                        if stopped { throw CancellationError() }

                        // Force evaluation here to bound peak memory: without this, MLX
                        // accumulates the full N-step compute graph before running anything.
                        MLX.eval(latent)
                        step += 1
                        lastLatent = latent
                        continuation.yield(.progress(step: step, total: totalSteps))
                    }

                    guard let finalLatent = lastLatent else {
                        continuation.finish()
                        return
                    }

                    // Get a VAE-only decoder closure, then flush the GPU activation
                    // cache built up during denoising before the decode step starts.
                    // This prevents UNet activations and VAE activations from
                    // competing for GPU memory simultaneously.
                    let decode = generator.detachedDecoder()
                    MLX.GPU.set(cacheLimit: 0)

                    let decoded = decode(finalLatent)
                    // decode() returns float32 in [0, 1]; Image expects uint8 [0, 255].
                    let frame = decoded.ndim == 4 ? decoded[0] : decoded
                    let imageURL = try Self.savePNG(Image((frame * 255).asType(.uint8)), to: config.outputDirectory)
                    continuation.yield(.completed(imageURL))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            // Both cancellation paths:
            // 1. task.cancel() — cooperative; checked via Task.checkCancellation().
            // 2. stopGeneration() via _stopRequested — checked per-iteration.
            //
            // Note: onTermination(.cancelled) from a downstream consumer
            // cancellation is unreliable in Swift's AsyncThrowingStream (stdlib
            // limitation — see PR 2 review note). External stopGeneration() is
            // the load-bearing path for runtime-driven cancellation.
            continuation.onTermination = { @Sendable [self] _ in
                task.cancel()
                self.stopGeneration()
            }
        }
    }

    public func stopGeneration() {
        withLock { _stopRequested = true }
    }

    public func unloadModel() {
        let wasLoaded = withLock {
            let had = _generator != nil
            _generator = nil
            _preset = nil
            _stopRequested = false
            return had
        }
        // Only touch the GPU cache if Metal was actually used — calling
        // MLX.GPU.set(cacheLimit:) before any MLX work triggers Metal
        // initialisation and crashes in test environments.
        if wasLoaded {
            MLX.GPU.set(cacheLimit: 0)
        }
    }

    // MARK: - Private helpers

    static func detectPreset(at url: URL) throws -> StableDiffusionConfiguration {
        let fm = FileManager.default
        // SDXL has a second text encoder; SD 2.1 does not.
        if fm.fileExists(atPath: url.appending(component: "text_encoder_2").path) {
            return .presetSDXLTurbo
        }
        guard fm.fileExists(atPath: url.appending(component: "unet").path) else {
            throw MLXDiffusionError.unsupportedModelLayout(url)
        }
        return .presetStableDiffusion21Base
    }

    private static func loadPlanInputs(
        at url: URL,
        preset: StableDiffusionConfiguration
    ) throws -> ImageModelLoadPlan.Inputs {
        func bytes(at relativePath: String) -> Int64 {
            let path = url.appending(component: relativePath).path
            return (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
        }
        let unet   = bytes(at: "unet/diffusion_pytorch_model.safetensors")
        let vae    = bytes(at: "vae/diffusion_pytorch_model.safetensors")
        let te1    = bytes(at: "text_encoder/model.safetensors")
        let te2    = bytes(at: "text_encoder_2/model.safetensors")
        // Activation working set: latent area × float16 bytes × safety factor.
        let isXL   = preset.id.contains("sdxl")
        let latent: Int64 = isXL ? 128 * 128 : 64 * 64
        let activation = latent * 2 * 8  // float16, ×8 safety
        let available  = max(0, Int64(ProcessInfo.processInfo.physicalMemory) - 1_073_741_824)
        return ImageModelLoadPlan.Inputs(
            unetWeightBytes:        unet,
            vaeWeightBytes:         vae,
            textEncoderWeightBytes: te1 + te2,
            activationMemoryBytes:  activation,
            availableMemoryBytes:   available,
            targetWidth:  isXL ? 1024 : 512,
            targetHeight: isXL ? 1024 : 512
        )
    }

    /// Creates a temporary symlink so Hub's path resolution finds the
    /// weights in our slug-based download directory.
    ///
    /// Hub resolves: `<hubBase>/models/<repoID>` where slashes in repoID
    /// are directory separators. We symlink that path to `modelDir`.
    private static func makeHubBridge(
        for preset: StableDiffusionConfiguration,
        pointing modelDir: URL
    ) throws -> (hubBase: URL, cleanup: () -> Void) {
        let tmpBase = FileManager.default.temporaryDirectory
            .appending(component: "BCKDiffusion-\(UUID().uuidString)")
        // preset.id e.g. "stabilityai/sdxl-turbo" → two path components
        let target = tmpBase.appending(component: "models").appending(component: preset.id)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: modelDir)
        return (tmpBase, { try? FileManager.default.removeItem(at: tmpBase) })
    }

    private static func makeParams(
        prompt: String,
        config: ImageGenerationConfig,
        preset: StableDiffusionConfiguration
    ) -> EvaluateParameters {
        let defaults = preset.defaultParameters()
        return EvaluateParameters(
            cfgWeight: config.guidanceScale ?? defaults.cfgWeight,
            steps: config.steps,
            latentSize: [config.height / 8, config.width / 8],
            seed: config.seed ?? defaults.seed,
            prompt: prompt
        )
    }

    private static func savePNG(_ image: Image, to directory: URL?) throws -> URL {
        let dir = directory ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appending(component: "\(UUID().uuidString).png")
        try image.save(url: dest)
        return dest
    }
}

// MARK: - Factory registration

public extension ImageGenerationService {
    /// Registers the built-in MLX diffusion backend for `.mlxDiffusion` format.
    ///
    /// Hosts that want a custom factory skip this and register their own via
    /// ``ImageGenerationService/registerBackendFactory(for:factory:)``.
    @MainActor
    func registerMLXDiffusionBackend() {
        registerBackendFactory(for: .mlxDiffusion) { info in
            let backend = MLXDiffusionBackend()
            try await backend.loadModel(from: info.directoryURL)
            return backend
        }
    }
}

#endif
