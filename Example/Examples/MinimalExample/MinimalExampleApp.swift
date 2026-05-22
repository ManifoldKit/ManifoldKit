import SwiftUI
import SwiftData // needed for .modelContainer modifier type inference
import ManifoldKit
import ManifoldUI

/// The simplest possible ManifoldKit app.
///
/// `ManifoldKit.quickStart()` collapses the historical three-object dance
/// (`ManifoldBootstrap` + `DefaultBackends.register` + `ChatViewModel`) into
/// a single async call. Adopters who need a custom inference service, a
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
                ContentUnavailableView(
                    "Failed to start",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error.errorDescription ?? "Unknown error")
                )
            } else {
                ProgressView("Starting…")
                    .task { await start() }
            }
        }
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
