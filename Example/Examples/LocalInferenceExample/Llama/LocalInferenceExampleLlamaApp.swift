import SwiftUI
import SwiftData // needed for .modelContainer modifier type inference
import ManifoldKit
import ManifoldLlama

/// LocalInferenceExample — llama.cpp / GGUF via the `manifold-llama` companion.
///
/// Uses the documented `quickStart(backends:seed:)` recipe (docs/QUICKSTART.md
/// "Seeding a starter model") almost verbatim: on first launch, with no model
/// already on disk, ManifoldKit downloads the curated Qwen3-0.6B-Instruct
/// GGUF (~400 MB) before the chat surface appears, so the app is live and
/// generating with zero model-management UI.
///
/// - Important: **Never link `ManifoldMLX` into this target.** This app and
///   its sibling `LocalInferenceExample_MLX` exist as two separate XcodeGen
///   targets specifically so `ManifoldLlama` and `ManifoldMLX` are never
///   linked into the same binary — mixing the two companions in one process
///   trips the process-global `llama_backend_init` / Metal-in-simulator
///   hazard tracked as #982. See `../README.md`.
@main
struct LocalInferenceExampleLlamaApp: App {
    @State private var result: QuickStartResult?
    @State private var error: ManifoldKitError?
    @State private var showModelManagement = false
    @State private var downloadProgress: Double = 0

    var body: some Scene {
        WindowGroup {
            if let result {
                NavigationStack {
                    ChatView(showModelManagement: $showModelManagement)
                }
                .environment(result.viewModel)
                .modelContainer(result.bootstrap.modelContainer)
            } else if let error {
                ContentUnavailableView {
                    Label("Failed to start", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.errorDescription ?? "Unknown error")
                } actions: {
                    Button("Reset app data") { resetAndRestart() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView(value: downloadProgress)
                        .frame(width: 240)
                    Text(
                        downloadProgress > 0
                            ? "Downloading Qwen3-0.6B starter model… \(Int(downloadProgress * 100))%"
                            : "Starting…"
                    )
                    .foregroundStyle(.secondary)
                }
                .padding()
                .task { await start() }
            }
        }
    }

    @MainActor
    private func resetAndRestart() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            self.error = nil
            return
        }
        let storeDir = appSupport.appendingPathComponent("com.manifoldkit.local-inference-example-llama")
        for name in ["store.sqlite", "store.sqlite-shm", "store.sqlite-wal"] {
            do {
                try FileManager.default.removeItem(at: storeDir.appendingPathComponent(name))
            } catch CocoaError.fileNoSuchFile {
                // already absent — fine
            } catch {
                // best-effort; start() will surface any real failure
            }
        }
        self.error = nil
    }

    @MainActor
    private func start() async {
        do {
            result = try await ManifoldKit.quickStart(
                backends: [LlamaBackends.self],
                configuration: ManifoldConfiguration(
                    appName: "Local Inference (llama.cpp)",
                    bundleIdentifier: "com.manifoldkit.local-inference-example-llama"
                ),
                seed: .recommendedSmallModel { progress in
                    downloadProgress = progress
                }
            )
        } catch let e as ManifoldKitError {
            error = e
        } catch {
            self.error = .from(error)
        }
    }
}
