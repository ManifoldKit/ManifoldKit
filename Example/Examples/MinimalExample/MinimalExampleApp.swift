import SwiftUI
import SwiftData // needed for .modelContainer modifier type inference
import ManifoldKit

/// The simplest possible ManifoldKit app.
///
/// `ManifoldKit.quickStart()` collapses the historical three-object dance
/// (`ManifoldBootstrap` + per-family backend registration + `ChatViewModel`)
/// into a single async call. Adopters who need a custom inference service, a
/// custom model container, or non-default backends should drop down to
/// `ManifoldBootstrap.build` directly — that path is unchanged.
///
/// Errors from any step surface as ``ManifoldKitError``.
@main
struct MinimalExampleApp: App {
    @State private var result: QuickStartResult?
    @State private var error: ManifoldKitError?
    @State private var showModelManagement = false

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
                ProgressView("Starting…")
                    .task { await start() }
            }
        }
    }

    @MainActor
    private func resetAndRestart() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let storeDir = appSupport.appendingPathComponent("com.manifoldkit.minimal-example")
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
                configuration: ManifoldConfiguration(
                    appName: "Minimal Chat",
                    bundleIdentifier: "com.manifoldkit.minimal-example"
                )
            )
        } catch let e as ManifoldKitError {
            error = e
        } catch {
            self.error = .from(error)
        }
    }
}
