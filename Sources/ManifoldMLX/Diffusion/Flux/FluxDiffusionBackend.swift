#if MLX

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ManifoldInference
import Hub
import MLX
import FluxSwift

// MARK: - Errors

public enum FluxDiffusionError: Error, LocalizedError {
    case notLoaded
    case noLatentsProduced
    case pngEncodingFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .notLoaded:
            return "No FLUX model loaded. Call loadModel(from:) first."
        case .noLatentsProduced:
            return "The denoising loop produced no latents."
        case .pngEncodingFailed(let url):
            return "Failed to write PNG to \(url.path)."
        }
    }
}

// MARK: - FluxDiffusionBackend

/// ``ImageGenerationBackend`` that drives FLUX.1 Schnell via `mzbac/flux.swift`.
///
/// ## Loading
///
/// `loadModel(from:)` tries two paths in order:
/// 1. `FLUX.loadQuantized(from:)` — for flux.swift's own 4-bit quantization format
///    (directory contains `metadata.json` written by `FLUX.saveQuantizedWeights`).
/// 2. `Flux1Schnell(hub:modelDirectory:) + loadWeights(from:)` — for standard FP16
///    safetensors weights following the diffusers directory layout.
///
/// ## Concurrency
///
/// Mirrors `MLXDiffusionBackend`'s NSLock + `@unchecked Sendable` pattern.
/// The denoising loop is a long-running synchronous sequence; wrapping it in a
/// detached `Task` keeps the main actor unblocked while the loop runs. All
/// mutable state is protected by `lock`.
public final class FluxDiffusionBackend: ImageGenerationBackend, @unchecked Sendable {

    private let lock = NSLock()
    private var _generator: (any TextToImageGenerator)?
    private var _isGenerating = false
    private var _stopRequested = false

    public init() {}

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
        // Try flux.swift's own quantized format first (requires metadata.json).
        let generator: any TextToImageGenerator
        let quantizedMetadata = url.appending(component: "metadata.json")
        if FileManager.default.fileExists(atPath: quantizedMetadata.path) {
            let flux = try await FLUX.loadQuantized(
                from: url.path,
                modelType: "schnell",
                hub: HubApi(useOfflineMode: true)
            )
            guard let ttig = flux as? any TextToImageGenerator else {
                throw FluxDiffusionError.notLoaded
            }
            generator = ttig
        } else {
            // Standard FP16 / BF16 diffusers layout.
            let hub = HubApi(useOfflineMode: true)
            let model = try Flux1Schnell(hub: hub, modelDirectory: url)
            try model.loadWeights(from: url, dtype: .float16)
            generator = model
        }

        withLock {
            _generator = generator
            _stopRequested = false
        }
    }

    public func generate(
        prompt: String,
        config: ImageGenerationConfig
    ) throws -> AsyncThrowingStream<ImageGenerationEvent, Error> {
        let hasModel = withLock { _generator != nil }
        guard hasModel else { throw FluxDiffusionError.notLoaded }
        withLock { _isGenerating = true; _stopRequested = false }

        return AsyncThrowingStream { [self] continuation in
            let task = Task.detached(priority: .userInitiated) { [self] in
                defer { self.withLock { self._isGenerating = false } }
                do {
                    guard let generator = self.withLock({ self._generator }) else {
                        throw FluxDiffusionError.notLoaded
                    }

                    var params = EvaluateParameters(
                        width: config.width,
                        height: config.height,
                        numInferenceSteps: config.steps,
                        seed: config.seed,
                        prompt: prompt
                    )
                    if let guidance = config.guidanceScale {
                        params.guidance = Float(guidance)
                    }

                    var denoiser = generator.generateLatents(parameters: params)
                    let totalSteps = params.numInferenceSteps
                    var lastLatent: MLXArray?

                    while let xt = denoiser.next() {
                        try Task.checkCancellation()
                        if self.withLock({ self._stopRequested }) { throw CancellationError() }
                        eval(xt)
                        lastLatent = xt
                        continuation.yield(.progress(step: denoiser.i, total: totalSteps))
                    }

                    guard let finalLatent = lastLatent else {
                        throw FluxDiffusionError.noLatentsProduced
                    }

                    let unpacked = Self.unpackLatents(
                        finalLatent, height: config.height, width: config.width
                    )
                    let decoded = generator.decode(xt: unpacked)
                    let url = try Self.savePNG(decoded, to: config.outputDirectory)
                    continuation.yield(.completed(url))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

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
            _stopRequested = false
            return had
        }
        if wasLoaded {
            MLX.GPU.set(cacheLimit: 0)
        }
    }

    // MARK: - Private helpers

    /// Unpacks FLUX packed latents from [1, h×w, 64] to [1, H/8, W/8, 16].
    ///
    /// The denoising transformer operates on 2×2 patch-packed latents. The VAE
    /// decoder expects spatial [H/8, W/8, 16] latents, so unpacking is required
    /// before decode. This is the inverse of the pack operation in flux.swift's
    /// `ImageToImageGenerator` extension.
    private static func unpackLatents(_ latents: MLXArray, height: Int, width: Int) -> MLXArray {
        let h = height / 16
        let w = width / 16
        // [1, h*w, 64] → [1, h, w, 16, 2, 2]
        let reshaped = latents.reshaped(1, h, w, 16, 2, 2)
        // Inverse of transposed(0,1,3,5,2,4) is transposed(0,1,4,2,5,3)
        let transposed = reshaped.transposed(0, 1, 4, 2, 5, 3)
        // [1, h, 2, w, 2, 16] → [1, H/8, W/8, 16]
        return transposed.reshaped(1, h * 2, w * 2, 16)
    }

    /// Converts a decoded MLXArray [1, H, W, 3] float32 in [0, 1] to a PNG on disk.
    ///
    /// Follows the same CGContext pattern as the vendored `StableDiffusion/Image.swift`
    /// (RGBA, `noneSkipLast`, `byteOrder32Big`) so both backends write identical-format PNGs.
    private static func savePNG(_ decoded: MLXArray, to directory: URL?) throws -> URL {
        let dir = directory ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appending(component: "\(UUID().uuidString).png")

        // [1, H, W, 3] → [H, W, 3] uint8, padded to RGBA (CGContext requires 4 bytes/pixel).
        let rgb = clip(decoded.squeezed() * 255, min: MLXArray(Int32(0)), max: MLXArray(Int32(255)))
            .asType(DType.uint8)
        let (H, W, _) = rgb.shape3
        let alpha = full([H, W, 1], values: UInt8(255), type: UInt8.self)
        let rgba = concatenated([rgb, alpha], axis: -1)    // [H, W, 4]
        eval(rgba)

        // Get bytes via asArray for a guaranteed contiguous copy.
        var bytes = rgba.asArray(UInt8.self)
        let C = 4

        return try bytes.withUnsafeMutableBytes { ptr in
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let ctx = CGContext(
                data: ptr.baseAddress, width: W, height: H,
                bitsPerComponent: 8, bytesPerRow: W * C, space: cs,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ), let cgImage = ctx.makeImage() else {
                throw FluxDiffusionError.pngEncodingFailed(dest)
            }
            guard let dst = CGImageDestinationCreateWithURL(
                dest as CFURL, UTType.png.identifier as CFString, 1, nil
            ) else {
                throw FluxDiffusionError.pngEncodingFailed(dest)
            }
            CGImageDestinationAddImage(dst, cgImage, nil)
            guard CGImageDestinationFinalize(dst) else {
                throw FluxDiffusionError.pngEncodingFailed(dest)
            }
            return dest
        }
    }
}

// MARK: - Registration

public extension ImageGenerationService {
    /// Registers the FLUX.1 Schnell backend for `.fluxSchnell` format.
    ///
    /// Call once at app startup before loading any image model. The factory
    /// creates a bare `FluxDiffusionBackend` instance; `ImageGenerationService`
    /// calls `loadModel(from:)` on it immediately after construction.
    @MainActor
    func registerFluxDiffusionBackend() {
        registerBackendFactory(for: .fluxSchnell) { _ in
            FluxDiffusionBackend()
        }
    }
}

#endif
