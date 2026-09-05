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
final class EndpointStorePresentationIntegrationTests: XCTestCase {

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

    func test_chatAPIConfigurationContent_overridesOuterStoreWithForwardedStore() throws {
        let forwardedRuntime = try makeRuntime(suffix: "forwarded")
        let outerRuntime = try makeRuntime(suffix: "outer")
        let observation = EndpointStoreObservation()
        let content = chatAPIConfigurationContent(
            {
                EndpointStoreProbe(observation: observation, onMounted: {})
            },
            endpointStore: forwardedRuntime.endpointStore
        )
        .environment(\.endpointStore, outerRuntime.endpointStore)

        render(content, until: { observation.store != nil })

        XCTAssertTrue(
            (observation.store as AnyObject?) === (forwardedRuntime.endpointStore as AnyObject),
            "The helper must override an inherited store with the store captured by ChatView"
        )
    }

    func test_sabotage_omittingHelperInjection_exposesOuterStoreInstead() throws {
        let forwardedRuntime = try makeRuntime(suffix: "sabotage-forwarded")
        let outerRuntime = try makeRuntime(suffix: "sabotage-outer")
        let observation = EndpointStoreObservation()
        let content = EndpointStoreProbe(observation: observation, onMounted: {})
            .environment(\.endpointStore, outerRuntime.endpointStore)

        render(content, until: { observation.store != nil })

        XCTAssertTrue(
            (observation.store as AnyObject?) === (outerRuntime.endpointStore as AnyObject)
        )
        XCTAssertFalse(
            (observation.store as AnyObject?) === (forwardedRuntime.endpointStore as AnyObject),
            "Without explicit helper injection, the presented builder cannot receive the forwarded store"
        )
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

        XCTAssertEqual(Self.missingForwardingRoutes(in: source), [])
    }

    func test_sabotage_forwardingTripwireRejectsOriginalBuilderOnEveryRoute() throws {
        let source = try String(contentsOf: chatViewSourceURL, encoding: .utf8)
        let sabotaged = source.replacingOccurrences(
            of: "apiConfiguration: apiConfiguration\n",
            with: "apiConfiguration: apiConfigurationBuilder\n"
        )

        XCTAssertEqual(
            Set(Self.missingForwardingRoutes(in: sabotaged)),
            Set([
                "toolbar → Generation Settings",
                "shell presentations",
                "direct sheet / regular-width recovery popover",
                "error-recovery banner",
            ])
        )
    }

    private static func missingForwardingRoutes(in source: String) -> [String] {
        let forwardingBranches = [
            (".toolbar {", ".chatShellPresentations(", "toolbar → Generation Settings"),
            (".chatShellPresentations(", ".chatAPIConfigurationPresentation(", "shell presentations"),
            (".chatAPIConfigurationPresentation(", "// Model-switcher presentation", "direct sheet / regular-width recovery popover"),
            ("ChatErrorRecoveryBanner(", "if viewModel.isLoading", "error-recovery banner"),
        ]
        var missingRoutes: [String] = []
        for (start, end, route) in forwardingBranches {
            guard let branchRange = source.range(of: start),
                  let endRange = source.range(of: end, range: branchRange.upperBound..<source.endIndex) else {
                missingRoutes.append(route)
                continue
            }
            let branchSource = source[branchRange.lowerBound..<endRange.lowerBound]
            let forwardsPreparedClosure = branchSource.split(whereSeparator: \.isNewline).contains {
                String($0).trimmingCharacters(in: .whitespaces) == "apiConfiguration: apiConfiguration"
            }
            if !forwardsPreparedClosure {
                missingRoutes.append(route)
            }
        }
        return missingRoutes
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

    private func makeRuntime(suffix: String) throws -> ManifoldBootstrap {
        try ManifoldBootstrap(
            configuration: ManifoldConfiguration(
                appName: "Endpoint Store Presentation Test \(suffix)",
                bundleIdentifier: "com.manifoldkit.endpoint-store-presentation-test.\(suffix)"
            ),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )
    }

    private func render<Content: View>(
        _ content: Content,
        until condition: @escaping () -> Bool
    ) {
        let controller = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 200, height: 100))
        window.makeKeyAndOrderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(waitUntil(condition))
        window.close()
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
