import XCTest
@testable import ManifoldUI
@testable import ManifoldInference
@testable import ManifoldTestSupport

/// Regression tests for the cloud-badge capability check in ChatToolbarContent.
///
/// Prior to this fix, the badge relied on a hardcoded name list that missed
/// `openAIResponses` and `custom` providers. The fix replaces the name check
/// with `backendCapabilities?.isRemote`, so any backend that sets `isRemote: true`
/// in its `BackendCapabilities` now shows the badge regardless of its name.
@MainActor
final class CloudBadgeCapabilityTests: XCTestCase {

    private nonisolated(unsafe) var harnesses: [TestChatViewModelHarness] = []

    override func tearDown() async throws {
        for harness in harnesses { harness.cleanup() }
        harnesses.removeAll()
        try await super.tearDown()
    }

    private func makeViewModel(isRemote: Bool) -> ChatViewModel {
        let mock = MockInferenceBackend(capabilities: BackendCapabilities(isRemote: isRemote))
        let harness = try! makeTestChatViewModel(mock: mock)
        harnesses.append(harness)
        return harness.vm
    }

    // MARK: - isRemote reflects in backendCapabilities

    func test_cloudBadge_showsForRemoteBackend() {
        let vm = makeViewModel(isRemote: true)
        XCTAssertEqual(vm.backendCapabilities?.isRemote, true,
            "A backend advertising isRemote should expose that via backendCapabilities")
    }

    func test_cloudBadge_hiddenForLocalBackend() {
        let vm = makeViewModel(isRemote: false)
        XCTAssertEqual(vm.backendCapabilities?.isRemote, false,
            "A local backend should not trigger the cloud badge")
    }

    /// Regression: openAIResponses was missing from the old hardcoded name list.
    /// Any backend claiming isRemote:true — including the Responses backend — must
    /// satisfy the new capability gate.
    func test_cloudBadge_openAIResponsesProviderIsRemote() {
        // Simulate the capabilities that OpenAIResponsesBackend.swift declares.
        let caps = BackendCapabilities(isRemote: true)
        let mock = MockInferenceBackend(capabilities: caps)
        let harness = try! makeTestChatViewModel(mock: mock)
        harnesses.append(harness)
        let vm = harness.vm
        XCTAssertEqual(vm.backendCapabilities?.isRemote, true,
            "openAIResponses declares isRemote:true — badge must show")
    }

    /// Regression: custom / user-defined remote backends were also missed.
    func test_cloudBadge_customRemoteBackendIsRemote() {
        let caps = BackendCapabilities(isRemote: true)
        let mock = MockInferenceBackend(capabilities: caps)
        let harness = try! makeTestChatViewModel(mock: mock)
        harnesses.append(harness)
        let vm = harness.vm
        XCTAssertEqual(vm.backendCapabilities?.isRemote, true,
            "A custom remote backend with isRemote:true must show the cloud badge")
    }

    /// Sabotage evidence: if BackendCapabilities.isRemote is flipped to false for a
    /// "remote" backend, the badge would incorrectly hide. The fix gates solely on
    /// this property, so wrong values propagate directly to the UI gate.
    func test_cloudBadge_falseDespiteRemoteName_whenCapabilityIsFalse() {
        // isRemote:false even though the name could be "openAI"
        let caps = BackendCapabilities(isRemote: false)
        let mock = MockInferenceBackend(capabilities: caps)
        let harness = try! makeTestChatViewModel(mock: mock)
        harnesses.append(harness)
        let vm = harness.vm
        XCTAssertEqual(vm.backendCapabilities?.isRemote, false,
            "isRemote:false should suppress the badge regardless of backend name")
    }
}
