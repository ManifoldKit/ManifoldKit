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
//   - Gating contract: seeding requires a registered backend that can load
//     the seed's model type — checked at runtime against InferenceService, so
//     companion registrars passed to quickStart(backends:) count. (The GGUF
//     starter seed needs manifold-llama's LlamaBackends.) When no compatible
//     backend is registered the seed parameter is a logged no-op. The
//     download machinery itself is always compiled in since v0.48 (PR C2 —
//     the HuggingFace trait is retired).
//
// The implementation uses `BackgroundDownloadManaging` (protocol in
// ManifoldModelCatalog); tests inject a MockDownloadManager through the same
// seam.

import Foundation
import ManifoldInference

// MARK: - QuickStartSeed

/// Configures an opt-in model seed for ``ManifoldKit/quickStart(configuration:seed:)``.
///
/// When a ``QuickStartSeed`` is supplied, `quickStart` downloads a curated
/// small model **before** the selection policy runs — so on first launch the
/// composer is live and generating, not stuck at "No model loaded".
///
/// ### Requirements
///
/// Seeding requires a *registered* backend capable of loading the seed's
/// model type. The check is made against the live
/// `InferenceService` registration state — not compile-time
/// traits — so a Llama-capable backend injected at runtime via
/// ``ManifoldKit/quickStart(backends:configuration:seed:)``
/// (from the manifold-llama companion package) enables the GGUF seed.
///
/// ### Skip conditions
///
/// The seed is skipped automatically (logged, never thrown) when any of the
/// following is true:
/// - A model is already selectable (Foundation available, or a local model on
///   disk). Never downloads redundantly.
/// - No registered backend can load the seed's model type.
/// - The device has no internet connectivity (the error is silently swallowed so
///   the app still launches with the "No model" empty state rather than crashing).
///
/// ### Usage
///
/// ```swift
/// import ManifoldLlama
///
/// let kit = try await ManifoldKit.quickStart(
///     backends: [LlamaBackends.self],
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
/// let kit = try await ManifoldKit.quickStart(
///     backends: [LlamaBackends.self],
///     seed: .recommendedSmallModel()
/// )
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

    /// The ManifoldKit-curated starter model: Qwen3-0.6B-Instruct Q4_K_M (~484 MB).
    ///
    /// Qwen3-0.6B fits comfortably in 1 GB of physical RAM and runs at
    /// acceptable speed on the iPhone 16 / M-series Mac range that represents
    /// the typical ManifoldKit developer device. Q4_K_M gives a reasonable
    /// quality / size trade-off without requiring a second "projector" file.
    ///
    /// The model is downloaded from the `bartowski/Qwen_Qwen3-0.6B-GGUF` HuggingFace
    /// repo — a widely-used, well-maintained GGUF quantization set. (This value was
    /// previously `bartowski/Qwen3-0.6B-GGUF` — unprefixed — which does not resolve.
    /// There is no evidence it ever did: the prefixed repo used here was created in
    /// April 2025, over a year before the unprefixed ID was written in, and every
    /// other unprefixed `bartowski` repo this file uses is still live, so a rename
    /// does not fit either. See #2453.)
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
            modelID: "bartowski/Qwen_Qwen3-0.6B-GGUF/Qwen_Qwen3-0.6B-Q4_K_M.gguf",
            repoID: "bartowski/Qwen_Qwen3-0.6B-GGUF",
            fileName: "Qwen_Qwen3-0.6B-Q4_K_M.gguf",
            displayName: "Qwen3 0.6B (Q4_K_M)",
            modelType: .gguf,
            sizeBytes: 484_220_320,
            promptTemplate: .chatML,
            onProgress: onProgress
        )
    }

    // MARK: - Device-aware seed selection

    /// Curated GGUF starter candidates the device-aware seed picker ranks over.
    ///
    /// These are widely-used `bartowski` Q4_K_M quantizations spanning the small →
    /// mid size range so a 64 GB M-series machine and a base iPhone land on
    /// different seeds. `recommendedSmallModel()`'s Qwen3-0.6B is the floor and is
    /// *always* in this set, so the picker can never return nothing runnable.
    ///
    /// Sizes are approximate download bytes (Q4_K_M). They feed the scorer's
    /// `ModelLoadPlan`-backed fit dimension, so an over-budget candidate is
    /// collapsed below every runnable one and the floor wins by construction.
    static let seedCandidates: [QuickStartSeed] = [
        // Floor — the existing recommendedSmallModel(). ~0.5 GB, runs anywhere.
        QuickStartSeed(
            modelID: "bartowski/Qwen_Qwen3-0.6B-GGUF/Qwen_Qwen3-0.6B-Q4_K_M.gguf",
            repoID: "bartowski/Qwen_Qwen3-0.6B-GGUF",
            fileName: "Qwen_Qwen3-0.6B-Q4_K_M.gguf",
            displayName: "Qwen3 0.6B (Q4_K_M)",
            modelType: .gguf,
            sizeBytes: 484_220_320,
            promptTemplate: .chatML,
            onProgress: nil
        ),
        // ~2.5 GB — comfortable on a modern phone / base Mac.
        QuickStartSeed(
            modelID: "bartowski/Qwen_Qwen3-4B-GGUF/Qwen_Qwen3-4B-Q4_K_M.gguf",
            repoID: "bartowski/Qwen_Qwen3-4B-GGUF",
            fileName: "Qwen_Qwen3-4B-Q4_K_M.gguf",
            displayName: "Qwen3 4B (Q4_K_M)",
            modelType: .gguf,
            sizeBytes: 2_497_280_960,
            promptTemplate: .chatML,
            onProgress: nil
        ),
        // ~4.9 GB — a capable 8B for machines with headroom.
        QuickStartSeed(
            modelID: "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf",
            repoID: "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF",
            fileName: "Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf",
            displayName: "Llama 3.1 8B (Q4_K_M)",
            modelType: .gguf,
            sizeBytes: 4_920_739_232,
            promptTemplate: .llama3,
            onProgress: nil
        ),
        // ~9.0 GB — frontier-ish local pick for high-memory M-series.
        QuickStartSeed(
            modelID: "bartowski/Qwen2.5-14B-Instruct-GGUF/Qwen2.5-14B-Instruct-Q4_K_M.gguf",
            repoID: "bartowski/Qwen2.5-14B-Instruct-GGUF",
            fileName: "Qwen2.5-14B-Instruct-Q4_K_M.gguf",
            displayName: "Qwen2.5 14B (Q4_K_M)",
            modelType: .gguf,
            sizeBytes: 8_988_110_976,
            promptTemplate: .chatML,
            onProgress: nil
        ),
    ]

    /// The Qwen3-0.6B floor — the seed returned when no larger candidate fits the
    /// device. Always the first entry in ``seedCandidates``.
    static var floorSeed: QuickStartSeed { seedCandidates[0] }

    /// Picks a first-launch seed model tailored to the host device.
    ///
    /// Ranks ``seedCandidates`` with ``ModelFitScorer`` under the host's
    /// ``DeviceProfile`` (memory + memory bandwidth) for the given use case, then
    /// returns the best-ranked candidate that will actually run. A 64 GB M-series
    /// machine lands on a larger, more capable model than a base iPhone; when no
    /// candidate larger than the floor fits, the Qwen3-0.6B floor is returned — so
    /// the call never yields a model the device can't load.
    ///
    /// This is *additive*: ``recommendedSmallModel(onProgress:)`` still returns the
    /// fixed 0.6B floor for callers that want the historical behaviour.
    ///
    /// - Parameters:
    ///   - useCase: Biases the scorer's dimension weights. Defaults to `.general`.
    ///   - device: The device profile to rank against. Defaults to the real host
    ///     (`.current`); tests inject a fixed profile for determinism.
    ///   - foundationAvailable: Whether Apple Foundation Models is usable. When
    ///     `true` the caller already has a zero-download Tier-0 model and would
    ///     normally skip seeding entirely; the seed picker still returns the floor
    ///     so a forced seed is well-defined. Defaults to `false` (no FM).
    ///   - onProgress: Optional main-actor progress closure forwarded to the
    ///     chosen seed (see ``recommendedSmallModel(onProgress:)``).
    /// - Returns: A device-appropriate ``QuickStartSeed``.
    public static func recommended(
        useCase: ModelUseCase = .general,
        device: DeviceProfile = .current,
        foundationAvailable: Bool = false,
        onProgress: (@Sendable @MainActor (Double) -> Void)? = nil
    ) -> QuickStartSeed {
        let scorer = ModelFitScorer()
        let candidates: [ModelSelectionCandidate] = seedCandidates.map {
            .downloadable($0.asDownloadableModel())
        }
        let ranked = scorer.rank(
            candidates: candidates,
            useCase: useCase,
            device: device,
            foundationAvailable: foundationAvailable
        )

        // Find the best-ranked candidate that will actually run on this device.
        // `rank` already sinks `.deny`/over-budget candidates to the bottom, but we
        // also gate on `willRun` so a device that can run *nothing but* the floor
        // (or, hypothetically, not even that) deterministically gets the floor.
        let chosen = ranked.first(where: { $0.1.willRun })?.0

        let seed: QuickStartSeed
        if case .downloadable(let model) = chosen,
           let match = seedCandidates.first(where: { $0.modelID == model.id }) {
            seed = match
        } else {
            seed = floorSeed
        }

        return seed.withProgress(onProgress)
    }

    // MARK: - Conversions

    /// Materialises this seed as a ``DownloadableModel`` for scoring / download.
    func asDownloadableModel() -> DownloadableModel {
        DownloadableModel(
            repoID: repoID,
            fileName: fileName,
            displayName: displayName,
            modelType: modelType,
            sizeBytes: sizeBytes,
            promptTemplate: promptTemplate
        )
    }

    /// Returns a copy of this seed with `onProgress` replaced (no-op when `nil`
    /// and the seed already has no callback). Used by ``recommended(...)`` so the
    /// caller's progress closure rides the device-chosen candidate.
    func withProgress(_ onProgress: (@Sendable @MainActor (Double) -> Void)?) -> QuickStartSeed {
        guard onProgress != nil else { return self }
        return QuickStartSeed(
            modelID: modelID,
            repoID: repoID,
            fileName: fileName,
            displayName: displayName,
            modelType: modelType,
            sizeBytes: sizeBytes,
            promptTemplate: promptTemplate,
            onProgress: onProgress
        )
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
/// This function is the concrete inner loop for the seed path. Tests inject
/// a `MockDownloadManager`; production callers get a real
/// `BackgroundDownloadManager` (always compiled in since v0.48, PR C2).
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
        // Seed downloads deliberately use `.singleFile` directly and skip
        // `downloadPlan(for:)`'s checksum resolution: a QuickStartSeed is a
        // developer-specified, trusted model baked into the app, not a
        // user-chosen catalog entry, so there is no untrusted manifest to
        // verify against here.
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
