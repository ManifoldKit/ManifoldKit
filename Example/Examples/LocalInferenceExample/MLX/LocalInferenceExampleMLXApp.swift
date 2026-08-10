import SwiftUI
import SwiftData // needed for .modelContainer modifier type inference
import ManifoldKit
import ManifoldMLX

/// LocalInferenceExample — MLX via the `manifold-mlx` companion.
///
/// Demonstrates text generation *and* on-device image generation on Apple
/// Silicon. `ManifoldKit.quickStart(...)` has no `imageGenerationService`
/// parameter on any overload (see
/// `Sources/ManifoldUI/ManifoldUI.docc/Articles/GenerationComponents.md` §
/// "Registering tool sources" — tracked as #1903), so this app drops down to
/// the documented manual `ManifoldBootstrap.build(...)` recipe (AGENTS.md →
/// Part 1 → "Bootstrap recipe") instead of `quickStart`, mirroring its shape
/// (same default backend registrars, same session/model wiring) by hand.
///
/// - Important: **Never link `ManifoldLlama` into this target.** This app and
///   its sibling `LocalInferenceExample_Llama` are two separate XcodeGen
///   targets specifically so `ManifoldMLX` and `ManifoldLlama` are never
///   linked into the same binary — mixing the two companions in one process
///   trips the process-global `llama_backend_init` / Metal-in-simulator
///   hazard tracked as #982. See `../README.md`.
///
/// This app ships no model-download UI (`ManifoldUIModelManagement` is not
/// linked) — text models are discovered from `~/Documents/Models` (populated
/// by `hf download`, matching docs/QUICKSTART-CLI.md § 4) and the SDXL-Turbo
/// diffusion snapshot is discovered from a fixed path that
/// `scripts/example-local-inference.sh` populates before launch. Both are
/// opt-in "real download" steps driven by the human-run gate script, not by
/// this app.
@main
struct LocalInferenceExampleMLXApp: App {
    @State private var bootstrap: ManifoldBootstrap?
    @State private var viewModel: ChatViewModel?
    @State private var error: ManifoldKitError?
    @State private var showModelManagement = false

    var body: some Scene {
        WindowGroup {
            if let bootstrap, let viewModel {
                NavigationStack {
                    ChatView(showModelManagement: $showModelManagement)
                }
                .environment(viewModel)
                .modelContainer(bootstrap.modelContainer)
            } else if let error {
                ContentUnavailableView {
                    Label("Failed to start", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.errorDescription ?? "Unknown error")
                }
            } else {
                ProgressView("Starting…")
                    .task { await start() }
            }
        }
    }

    @MainActor
    private func start() async {
        do {
            let configuration = ManifoldConfiguration(
                appName: "Local Inference (MLX)",
                bundleIdentifier: "com.manifoldkit.local-inference-example-mlx"
            )

            // MLX ships on-device diffusion image generation
            // (ManifoldMLX/MLXDiffusionBackend.swift, `registerMLXDiffusionBackend()`).
            // Registering the factory before `ManifoldBootstrap.build` means the
            // bootstrap's `imageGenerationRuntime` seam is live the moment
            // `configure(bootstrap:)` runs below.
            let imageGenerationService = ImageGenerationService()
            imageGenerationService.registerMLXDiffusionBackend()

            let (progress, task) = ManifoldBootstrap.build(
                configuration: configuration,
                imageGenerationService: imageGenerationService
            )
            for await _ in progress {
                // No progress UI in this facade-free path — mirrors quickStart().
            }
            let bootstrap = try await task.value

            // Same default registrars `quickStart()` would install, plus MLX —
            // this app mirrors `quickStart(backends: [MLXBackends.self])`'s
            // registration shape by hand (see the type doc comment above).
            for registrar in ManifoldKit.defaultBackendRegistrars {
                registrar.register(with: bootstrap.inferenceService)
            }
            MLXBackends.register(with: bootstrap.inferenceService)

            // Populate recommendations reusing the proven MLX entries from
            // Example/Advanced/ManifoldDemoApp.swift.
            CuratedModel.all = Self.curatedMLXModels

            let vm = ChatViewModel(
                inferenceService: bootstrap.inferenceService,
                conversationRuntime: bootstrap.conversationRuntime
            )
            // Wires persistence, endpoint store, and — because
            // `imageGenerationService` was supplied above — the image runtime,
            // in one call (Sources/ManifoldUI/ViewModels/RuntimeConfiguration.swift).
            vm.configure(bootstrap: bootstrap)

            let sessions = SessionManagerViewModel()
            await sessions.configureAndLoad(bootstrap: bootstrap)
            if let restored = await sessions.selectInitialSession() {
                sessions.activeSession = restored
                await vm.switchToSession(restored)
            } else if let fresh = try? await sessions.createSession() {
                sessions.activeSession = fresh
                await vm.switchToSession(fresh)
            }

            // Text-model selection: no quickStart() here, so replicate its
            // policy by hand — refresh the registry (picks up anything under
            // ~/Documents/Models, e.g. from `hf download`), then dispatch the
            // first on-disk model a registered backend can load.
            do {
                try vm.modelRegistry.refresh()
            } catch {
                // Non-fatal — the empty state ("No model loaded") surfaces if
                // nothing is found, exactly like quickStart()'s own fallback.
            }
            if vm.selectedModel == nil,
               let compatible = vm.modelRegistry.availableModels.first(where: {
                   vm.modelRegistry.compatibility(for: $0.modelType).isSupported
               }) {
                vm.modelRegistry.selectModel(compatible)
                vm.dispatchSelectedLoad()
            }

            // Advertise `generate_image` to the model so it can call image
            // generation autonomously (GenerationComponents.md § Tool Sources).
            // ChatView already renders the resulting inline image — no new UI.
            await bootstrap.addToolSources([ImageGenerationToolSource(viewModel: vm)])

            // Auto-load a pre-downloaded SDXL-Turbo snapshot if present.
            if let info = Self.discoverSDXLTurbo() {
                do {
                    try await imageGenerationService.loadModel(info)
                } catch {
                    // Image generation stays unavailable; text chat still works.
                }
            }

            self.bootstrap = bootstrap
            self.viewModel = vm
        } catch let e as ManifoldKitError {
            error = e
        } catch {
            self.error = .from(error)
        }
    }

    // MARK: - Curated MLX models
    //
    // Reused verbatim from Example/Advanced/ManifoldDemoApp.swift's MLX
    // entries — proven repo IDs, prompt templates, and context sizes. (The
    // Advanced app's copy is being deleted in this same PR: those models are
    // unloadable there because Advanced links no local-inference companion.
    // This app is the new, actually-loadable home for them.)
    private static let curatedMLXModels: [CuratedModel] = [
        CuratedModel(
            id: "phi-4-mini-mlx",
            displayName: "Phi-4 Mini (MLX, 4-bit)",
            fileName: "Phi-4-mini-instruct-4bit",
            repoID: "mlx-community/Phi-4-mini-instruct-4bit",
            modelType: .mlx,
            approximateSizeBytes: 2_400_000_000,
            recommendedFor: [.small, .medium, .large, .xlarge],
            contextSize: 4096,
            promptTemplate: .phi,
            description: "Microsoft's compact reasoning model, optimized for Apple Silicon"
        ),
        CuratedModel(
            id: "llama-3.2-3b-mlx",
            displayName: "Llama 3.2 3B Instruct (MLX, 4-bit)",
            fileName: "Llama-3.2-3B-Instruct-4bit",
            repoID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            modelType: .mlx,
            approximateSizeBytes: 1_800_000_000,
            recommendedFor: [.small, .medium, .large, .xlarge],
            contextSize: 8192,
            promptTemplate: .llama3,
            description: "Meta's efficient 3B model with 8K context"
        ),
        CuratedModel(
            id: "qwen-2.5-7b-mlx",
            displayName: "Qwen 2.5 7B Instruct (MLX, 4-bit)",
            fileName: "Qwen2.5-7B-Instruct-4bit",
            repoID: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            modelType: .mlx,
            approximateSizeBytes: 4_500_000_000,
            recommendedFor: [.large, .xlarge],
            contextSize: 8192,
            promptTemplate: .chatML,
            description: "Strong multilingual model from Alibaba"
        ),
    ]

    // MARK: - SDXL-Turbo discovery

    /// `~/Documents/Models/ImageModels/stabilityai-sdxl-turbo` — where
    /// `scripts/example-local-inference.sh` places the SDXL-Turbo diffusers
    /// snapshot (`hf download stabilityai/sdxl-turbo`). `MLXDiffusionBackend
    /// .detectPreset` resolves this layout to `.presetSDXLTurbo` automatically
    /// from the presence of a `text_encoder_2/` subdirectory — validated by
    /// the companion's own `SDXLDiffusionIntegrationTests`.
    static var imageModelDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models/ImageModels/stabilityai-sdxl-turbo", isDirectory: true)
    }

    private static func discoverSDXLTurbo() -> ImageModelInfo? {
        let dir = imageModelDirectory
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("model_index.json").path) else {
            return nil
        }
        return ImageModelInfo(
            id: "stabilityai/sdxl-turbo",
            name: "SDXL Turbo",
            directoryURL: dir,
            format: .mlxDiffusion,
            fileSize: Int64(directorySize(dir)),
            huggingFaceRepoID: "stabilityai/sdxl-turbo"
        )
    }

    /// Best-effort recursive byte count. Display metadata only — never
    /// load-bearing for `loadModel(_:)`, so a failed enumeration just yields 0.
    private static func directorySize(_ url: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += UInt64(size)
        }
        return total
    }
}
