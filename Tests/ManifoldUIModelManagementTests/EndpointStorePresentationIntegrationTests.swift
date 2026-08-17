@preconcurrency import XCTest
import SwiftUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
@testable import ManifoldUI
import ManifoldUIModelManagement

#if canImport(AppKit)
import AppKit
#endif

/// Integration coverage for #2476: a production ``ChatView`` must carry the
/// host-provided endpoint store into API-configuration sheet content. A custom
/// EnvironmentValues key does not reliably cross that boundary by SwiftUI
/// inheritance alone.
@MainActor
/// Kept last alphabetically because this is the target's only real SwiftUI
/// sheet presentation; AppKit releases its presentation host at process
/// teardown, after the headless model-management render tests have run.
final class ZZZEndpointStorePresentationIntegrationTests: XCTestCase {

    #if canImport(AppKit)
    func test_chatViewDirectAPIConfigurationSheet_receivesUsableBootstrapEndpointStore() async throws {
        let runtime = try ManifoldBootstrap(
            configuration: ManifoldConfiguration(
                appName: "Endpoint Store Presentation Test",
                bundleIdentifier: "com.manifoldkit.endpoint-store-presentation-test"
            ),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )
        let chatViewModel = ChatViewModel(inferenceService: runtime.inferenceService)
        chatViewModel.configure(bootstrap: runtime)

        let observation = EndpointStoreObservation()
        let view = EndpointStoreChatViewHost(
            chatViewModel: chatViewModel,
            endpointStore: runtime.endpointStore,
            observation: observation
        )

        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 800, height: 600))
        window.makeKeyAndOrderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        defer { window.close() }

        XCTAssertTrue(
            waitUntil { observation.store != nil },
            "The production ChatView API-configuration sheet must mount its supplied content"
        )
        guard let observedStore = observation.store else { return }
        XCTAssertTrue(
            (observedStore as AnyObject) === (runtime.endpointStore as AnyObject),
            "Presented API-configuration content must receive the bootstrap endpoint store"
        )

        let endpoint = APIEndpointRecord(
            name: "Presentation Test Endpoint",
            provider: .ollama,
            modelName: "test-model"
        )
        try await observedStore.insertEndpoint(endpoint)
        let stored = try await runtime.endpointStore.fetchEndpoints()
        XCTAssertEqual(stored.map(\.id), [endpoint.id],
            "The store received by the presented content must remain usable for endpoint writes")

        // The macOS sheet currently inherits this custom key; the following
        // structural test is the cross-platform tripwire for ChatView's
        // explicit re-injection, including iPad's regular-width popover.
    }

    /// The macOS hosting harness can drive ChatView's sheet route above, but
    /// cannot create iPad's regular-width recovery popover. This production-
    /// linked tripwire pins every ChatView branch that must receive the same
    /// prepared closure: toolbar → Generation Settings, shell presentations,
    /// direct sheet/popover, and the error-recovery banner. Removing any one
    /// branch makes this test red; the sheet test above proves that prepared
    /// closure carries a usable, real in-memory store at runtime.
    func test_chatView_forwardsPreparedAPIConfigurationClosureToEveryRoute() throws {
        let source = try String(contentsOf: chatViewSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("chatAPIConfigurationContent(\n                apiConfigurationBuilder,\n                endpointStore: endpointStore"),
            "ChatView must prepare its host API configuration closure with endpointStore")

        let forwardingBranches = [
            (".toolbar {", ".chatShellPresentations(", "toolbar → Generation Settings"),
            (".chatShellPresentations(", ".chatAPIConfigurationPresentation(", "shell presentations"),
            (".chatAPIConfigurationPresentation(", "// Model-switcher presentation", "direct sheet / regular-width recovery popover"),
            ("ChatErrorRecoveryBanner(", "if viewModel.isLoading", "error-recovery banner"),
        ]
        for (start, end, route) in forwardingBranches {
            guard let branchRange = source.range(of: start),
                  let endRange = source.range(of: end, range: branchRange.upperBound..<source.endIndex) else {
                return XCTFail("ChatView no longer contains the \(route) branch")
            }
            let branchSource = source[branchRange.lowerBound..<endRange.lowerBound]
            XCTAssertTrue(branchSource.contains("apiConfiguration: apiConfiguration"),
                "ChatView's \(route) branch must receive the prepared closure")
        }

        // Sabotage-evidence: remove any `apiConfiguration: apiConfiguration`
        // forwarding call above, or pass `apiConfigurationBuilder` directly,
        // and this route-specific structural tripwire fails. The direct-sheet
        // integration test separately proves the closure's live store value.
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 2
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private var chatViewSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ManifoldUI/Views/Chat/ChatView.swift")
    }
    #endif
}

@MainActor
private final class EndpointStoreObservation {
    var store: (any EndpointStore)?
}

private struct EndpointStoreProbe: View {
    @Environment(\.endpointStore) private var endpointStore
    let observation: EndpointStoreObservation
    let onMounted: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                observation.store = endpointStore
                onMounted()
            }
    }
}

private struct EndpointStoreChatViewHost: View {
    let chatViewModel: ChatViewModel
    let endpointStore: any EndpointStore
    let observation: EndpointStoreObservation
    @State private var isAPIConfigurationPresented = true

    var body: some View {
        ChatView(showModelManagement: .constant(false)) {
            VStack {
                EndpointStoreProbe(
                    observation: observation,
                    onMounted: { isAPIConfigurationPresented = false }
                )
                APIConfigurationView()
            }
        }
        .presentingAPIConfigurationForTesting($isAPIConfigurationPresented)
        .environment(chatViewModel)
        .environment(\.endpointStore, endpointStore)
    }
}
