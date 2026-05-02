@preconcurrency import XCTest
import Foundation
import Observation
@testable import BaseChatUI
@testable import BaseChatInference
import BaseChatPersistenceSwiftData
import BaseChatTestSupport

/// Forwarding contract between ``ChatViewModel`` and ``ModelRegistry``.
///
/// `ChatViewModel`'s public API for `availableModels`, `selectedModel`, and
/// `refreshModels()` shifted from stored properties to computed forwarders
/// onto an internally-owned `ModelRegistry`. These tests pin the round-trip
/// behaviour so downstream consumers (Fireside, localclaw, IOS-AI-Server)
/// keep compiling and observing changes correctly while the deprecated
/// path is still in service.
///
/// The most load-bearing test here is
/// ``test_chatViewModel_selectedModel_observationPropagatesFromRegistry()``:
/// SwiftUI consumers register `onChange(of: chatViewModel.selectedModel)`
/// handlers that must fire when registry state changes via the new
/// explicit-init view path.
@MainActor
final class ChatViewModelRegistryForwardingTests: XCTestCase {

    private var harnesses: [TestChatViewModelHarness] = []

    override func tearDown() async throws {
        for harness in harnesses {
            harness.cleanup()
        }
        harnesses.removeAll()
        try await super.tearDown()
    }

    private func makeViewModel() throws -> ChatViewModel {
        let harness = try makeTestChatViewModel()
        harnesses.append(harness)
        return harness.vm
    }

    // MARK: - availableModels forwarding

    func test_availableModels_writeReadRoundTrip() throws {
        let vm = try makeViewModel()
        let model = ModelInfo.builtInFoundation

        // Write through ChatViewModel
        vm.availableModels = [model]
        XCTAssertEqual(vm.availableModels.first?.id, model.id)

        // Read through registry
        XCTAssertEqual(vm.modelRegistry.availableModels.first?.id, model.id)
    }

    func test_availableModels_writeOnRegistryReadsThroughChatViewModel() throws {
        let vm = try makeViewModel()
        let model = ModelInfo.builtInFoundation

        // Write directly to registry
        vm.modelRegistry.availableModels = [model]

        // Reads through ChatViewModel surface what registry holds
        XCTAssertEqual(vm.availableModels.first?.id, model.id)
    }

    // MARK: - selectedModel forwarding

    func test_selectedModel_writeOnChatViewModelMirrorsToRegistry() throws {
        let vm = try makeViewModel()
        let model = ModelInfo.builtInFoundation

        vm.selectedModel = model

        XCTAssertEqual(vm.modelRegistry.selectedModel?.id, model.id)
        XCTAssertEqual(vm.selectedModel?.id, model.id)
    }

    func test_selectedModel_writeOnRegistryReadsThroughChatViewModel() throws {
        let vm = try makeViewModel()
        let model = ModelInfo.builtInFoundation

        vm.modelRegistry.selectedModel = model

        XCTAssertEqual(vm.selectedModel?.id, model.id)
    }

    // MARK: - Observation propagation through computed forwarder

    /// Sabotage-verified test: the forwarding `selectedModel` getter must
    /// participate in the Observation framework's tracking so SwiftUI
    /// consumers re-render when the underlying registry value mutates.
    ///
    /// Sabotage check (run manually before committing):
    ///   1. In ChatViewModel.swift, replace the computed `selectedModel`
    ///      getter with a stored `selectedModel: ModelInfo? = nil` that
    ///      does NOT read `modelRegistry.selectedModel`.
    ///   2. Run this test — `onChange` must NOT fire for the registry write
    ///      (the test will then fail on the assertion below).
    ///   3. Restore the forwarding getter and re-run — the test passes.
    func test_chatViewModel_selectedModel_observationPropagatesFromRegistry() async throws {
        let vm = try makeViewModel()
        let model = ModelInfo.builtInFoundation

        let didFire = expectation(description: "Observation fired for chatViewModel.selectedModel")

        // Install one-shot tracker that watches `vm.selectedModel` (the
        // forwarder). It records the FIRST mutation only — subsequent
        // mutations would need a re-installed tracker, mirroring how
        // SwiftUI re-tracks per render.
        withObservationTracking {
            _ = vm.selectedModel
        } onChange: {
            didFire.fulfill()
        }

        // Mutate via the registry (the new explicit-init path). Observation
        // should fire because the tracker recorded a read of registry's
        // `selectedModel` while reading `vm.selectedModel`.
        vm.modelRegistry.selectedModel = model

        await fulfillment(of: [didFire], timeout: 1.0)
    }

    // MARK: - refreshModels delegation

    func test_refreshModels_delegatesToRegistry() throws {
        let vm = try makeViewModel()

        // Track refresh by observing availableModels mutation. The harness
        // models directory is empty, so the post-refresh count is 0 + any
        // foundation model. We assert the side effect happens at all.
        vm.foundationModelProvider = { true }
        vm.refreshModels()

        XCTAssertTrue(
            vm.availableModels.contains(where: { $0.modelType == .foundation }),
            "refreshModels() should have populated the registry through the foundationModelProvider"
        )
        XCTAssertTrue(
            vm.modelRegistry.availableModels.contains(where: { $0.modelType == .foundation }),
            "refreshModels() should mutate the registry directly"
        )
    }

    // MARK: - Endpoint sync — registry-driven write

    func test_selectedModelOnRegistry_clearsSelectedEndpoint() async throws {
        let vm = try makeViewModel()

        // Pre-condition: an endpoint is selected.
        let endpoint = APIEndpoint(name: "Test", provider: .openAI)
        vm.availableEndpoints = [endpoint]
        vm.selectedEndpoint = endpoint
        XCTAssertNotNil(vm.selectedEndpoint)

        // Writing to registry directly should fire the observer that
        // re-runs the endpoint-clear sync.
        vm.modelRegistry.selectedModel = ModelInfo.builtInFoundation

        // The onChange handler hops back to MainActor via a Task, so we
        // yield a couple of times to let it drain before asserting.
        await Task.yield()
        await Task.yield()

        XCTAssertNil(
            vm.selectedEndpoint,
            "selectedEndpoint should clear once the registry observer reapplies the sync"
        )
    }
}
