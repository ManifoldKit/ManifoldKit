// QuickStartSeed — opt-in first-launch model download for quickStart().
//
// Background: quickStart() wires a full chat runtime but on a fresh device
// with no Apple Intelligence and no on-disk models the selection policy returns
// nil and the composer reads "No model loaded". This file adds an opt-in path
// so a developer can get from zero to a live, generating chat with one call.
//
// Design contract:
//   - The zero-argument quickStart() is byte-for-byte unchanged.
//   - The new surface is a second overload: quickStart(seed:), where `seed` is
//     a QuickStartSeed value. The caller specifies which model to seed and an
//     optional progress closure; ManifoldKit handles the rest.
//   - Trait contract: seeding requires HuggingFace + at least one local backend
//     (Llama or MLX). When those traits are absent the seed parameter is a
//     no-op: quickStart(seed:) behaves exactly like quickStart() and the host
//     receives a clear thrown error if it calls seedIfNeeded() directly.
//
// The implementation uses `BackgroundDownloadManaging` (protocol in
// ManifoldModelCatalog) so the concrete BackgroundDownloadManager (ManifoldHuggingFace,
// #if HuggingFace) is referenced only inside the HuggingFace block. Hosts
// that import ManifoldKit without HuggingFace still compile; they just never
// have the seed path activate.

import Foundation
import ManifoldInference

// MARK: - QuickStartSeed

/// Configures an opt-in model seed for ``ManifoldKit/ManifoldKit/quickStart(seed:)``.
///
/// When a ``QuickStartSeed`` is supplied, `quickStart` downloads a curated
/// small model **before** the selection policy runs — so on first launch the
/// composer is live and generating, not stuck at "No model loaded".
///
/// ### Trait requirements
///
/// Seeding requires the `HuggingFace` SwiftPM trait (default-on) **and** at
/// least one local backend trait (`Llama` or `MLX`). When the `HuggingFace`
/// trait is absent the seed is silently skipped (no download, no error) because
/// there is no download machinery available. When `HuggingFace` is compiled in
/// but no local backend is present the download would succeed but no backend
/// could load the file — in that case the download is also skipped.
///
/// ### Skip conditions
///
/// The seed is skipped automatically when any of the following is true:
/// - A model is already selectable (Foundation available, or a local model on
///   disk). Never downloads redundantly.
/// - `HuggingFace` trait is absent.
/// - No local backend trait (`Llama`, `MLX`) is compiled in.
/// - The device has no internet connectivity (the error is silently swallowed so
///   the app still launches with the "No model" empty state rather than crashing).
///
/// ### Usage
///
/// ```swift
/// let kit = try await ManifoldKit.quickStart(
///     seed: .recommendedSmallModel { progress in
///         print("Downloading starter model: \(Int(progress * 100))%")
///     }
/// )
/// ```
///
/// The progress closure fires on the main actor with values in `[0, 1]`.
/// Omit it when you don't need progress UI:
///
/// ```swift
/// let kit = try await ManifoldKit.quickStart(seed: .recommendedSmallModel())
/// ```
public struct QuickStartSeed: Sendable {
    // MARK: - Curated model definition

    /// The identifier used to find the seed download in `activeDownloads`.
    let modelID: String
    let repoID: String
    let fileName: String
    let displayName: String
    let modelType: ModelType
    let sizeBytes: UInt64
    let promptTemplate: PromptTemplate
    /// Optional progress callback. Receives values in [0, 1] on `@MainActor`.
    let onProgress: (@Sendable @MainActor (Double) -> Void)?

    // MARK: - Factory

    /// The ManifoldKit-curated starter model: Qwen3-0.6B-Instruct Q4_K_M (~400 MB).
    ///
    /// Qwen3-0.6B fits comfortably in 1 GB of physical RAM and runs at
    /// acceptable speed on the iPhone 16 / M-series Mac range that represents
    /// the typical ManifoldKit developer device. Q4_K_M gives a reasonable
    /// quality / size trade-off without requiring a second "projector" file.
    ///
    /// The model is downloaded from the `bartowski/Qwen3-0.6B-GGUF` HuggingFace
    /// repo — a widely-used, well-maintained GGUF quantization set.
    ///
    /// - Parameter onProgress: Optional closure called on the main actor each
    ///   time download progress updates. Receives a value in `[0, 1]` where
    ///   `1.0` means complete. Pass `nil` (the default) when you don't need a
    ///   progress indicator.
    /// - Returns: A ``QuickStartSeed`` configured for Qwen3-0.6B.
    public static func recommendedSmallModel(
        onProgress: (@Sendable @MainActor (Double) -> Void)? = nil
    ) -> QuickStartSeed {
        QuickStartSeed(
            modelID: "bartowski/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q4_K_M.gguf",
            repoID: "bartowski/Qwen3-0.6B-GGUF",
            fileName: "Qwen3-0.6B-Q4_K_M.gguf",
            displayName: "Qwen3 0.6B (Q4_K_M)",
            modelType: .gguf,
            sizeBytes: 416_000_000,
            promptTemplate: .chatML,
            onProgress: onProgress
        )
    }
}

// MARK: - SeedModelError

/// Errors that ``QuickStartSeed`` seeding can surface.
///
/// These are deliberately narrow — most conditions (no connectivity, no local
/// backend) are silently skipped by `quickStart(seed:)` rather than throwing,
/// so the app still launches. The error cases here reflect programmer-visible
/// configuration mistakes.
public enum SeedModelError: Error, LocalizedError, Sendable {
    /// The HuggingFace trait is not compiled in, so there is no download
    /// machinery. This error is only thrown when the host explicitly calls the
    /// `seedIfNeeded` seam directly; `quickStart(seed:)` skips silently.
    case huggingFaceTraitNotAvailable

    public var errorDescription: String? {
        switch self {
        case .huggingFaceTraitNotAvailable:
            return """
                QuickStartSeed requires the HuggingFace SwiftPM trait. \
                Add \"HuggingFace\" to your traits array, or use the default \
                trait set (which includes it). If you want a cloud-only or \
                FoundationOnly build, the seed path is simply unavailable — \
                present ModelManagementSheet instead.
                """
        }
    }
}

// MARK: - Internal download helper

/// Drives a single seed download, waiting for completion (or failure) in-place.
///
/// Called from `_quickStart` after the bootstrap + backend registration phase
/// and before the selection-policy phase. Returns `true` if a model was
/// downloaded and the registry should be refreshed; `false` when the seed was
/// skipped.
///
/// - Parameters:
///   - seed: The seed configuration.
///   - storageService: Used to detect existing on-disk models and resolve the
///     destination URL after download. Injected so tests can pass a
///     scratch-directory instance.
///   - downloadManager: The download manager used to start the transfer.
///     Injected so tests can pass a `MockDownloadManager`.
/// Drives a single seed download, waiting for completion (or failure) in-place.
///
/// This function is the concrete inner loop for the seed path. It is always
/// compiled in (regardless of the `HuggingFace` trait) so that tests can inject
/// a `MockDownloadManager` without needing the real trait. The caller
/// (`_quickStart`) is responsible for ensuring a real `BackgroundDownloadManager`
/// is only created when `#if HuggingFace`.
///
/// Returns `true` if a model was downloaded successfully; `false` for all
/// skip / failure conditions (never throws — the app must launch regardless).
///
/// - Parameters:
///   - seed: The seed configuration.
///   - storageService: Used to detect existing on-disk models.
///   - downloadManager: The download manager. Injected so tests can pass a
///     `MockDownloadManager`.
@MainActor
func _performSeedDownload(
    seed: QuickStartSeed,
    storageService: ModelStorageService,
    downloadManager: any BackgroundDownloadManaging
) async -> Bool {
    // Skip when any model is already on disk — never download redundantly.
    let existing = storageService.discoverModels()
    guard existing.isEmpty else {
        Log.quickStart.info("quickStart(seed:): \(existing.count, privacy: .public) model(s) already on disk — seed skipped")
        return false
    }

    // Build the direct download URL from the HuggingFace CDN pattern.
    // The `https://huggingface.co/<repo>/resolve/main/<file>` shape is the
    // canonical LFS download URL and is stable across Hub SDK versions.
    guard let downloadURL = URL(string:
        "https://huggingface.co/\(seed.repoID)/resolve/main/\(seed.fileName)"
    ) else {
        Log.quickStart.error("quickStart(seed:): failed to construct download URL — seed skipped")
        return false
    }

    Log.quickStart.info("quickStart(seed:): starting seed download of \(seed.displayName, privacy: .public)")

    let model = DownloadableModel(
        repoID: seed.repoID,
        fileName: seed.fileName,
        displayName: seed.displayName,
        modelType: seed.modelType,
        sizeBytes: seed.sizeBytes,
        promptTemplate: seed.promptTemplate
    )

    let state: DownloadState
    do {
        state = try await downloadManager.startDownload(
            model,
            plan: .singleFile(url: downloadURL)
        )
    } catch {
        Log.quickStart.warning("quickStart(seed:): download start failed (\(error.localizedDescription, privacy: .public)) — seed skipped, app launches without pre-seeded model")
        return false
    }

    // Poll the DownloadState for completion. BackgroundDownloadManager updates
    // `status` on @MainActor, so we spin with Task.yield() here.
    // Bounded at 5 minutes: a stalled connection shouldn't hang the launch
    // indefinitely. After timeout the app launches in empty-state.
    let deadline = Date().addingTimeInterval(5 * 60)
    while Date() < deadline {
        switch state.status {
        case .completed:
            Log.quickStart.info("quickStart(seed:): seed download completed — \(seed.displayName, privacy: .public) ready")
            return true
        case .failed(let errorMessage):
            Log.quickStart.warning("quickStart(seed:): seed download failed: \(errorMessage, privacy: .public) — app launches without pre-seeded model")
            return false
        case .cancelled:
            Log.quickStart.info("quickStart(seed:): seed download was cancelled — app launches without pre-seeded model")
            return false
        case .queued, .downloading:
            if let onProgress = seed.onProgress {
                if case .downloading(let progress, _, _) = state.status {
                    onProgress(progress)
                }
            }
            await Task.yield()
        }
    }

    Log.quickStart.warning("quickStart(seed:): seed download timed out after 5 min — proceeding without model")
    return false
}
