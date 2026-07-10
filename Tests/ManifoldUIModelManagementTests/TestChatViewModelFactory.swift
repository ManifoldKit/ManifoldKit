@preconcurrency import XCTest
import Foundation
import SwiftData
@testable import ManifoldUI
@testable import ManifoldUIModelManagement
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport
import ManifoldPersistenceTestSupport
// BackendInternals SPI: seam published for the companion split (#1749).
@_spi(BackendInternals) import ManifoldHardware
@_spi(BackendInternals) import ManifoldUI

/// Mirror of `Tests/ManifoldUITests/TestChatViewModelFactory.swift`.
///
/// Duplicated rather than shared so `ManifoldUIModelManagementTests` doesn't
/// need a `@testable` cross-target dependency on the UI test target. Keep the
/// two copies in sync — when one is updated, update the other in the same PR.

@MainActor
struct TestChatViewModelHarness {
    let vm: ChatViewModel
    let mock: MockInferenceBackend?
    let container: ModelContainer?
    let userDefaults: UserDefaults
    let modelsDirectory: URL

    private let userDefaultsSuiteName: String
    private let ownsUserDefaults: Bool
    private let ownsModelsDirectory: Bool

    init(
        vm: ChatViewModel,
        mock: MockInferenceBackend?,
        container: ModelContainer?,
        userDefaults: UserDefaults,
        userDefaultsSuiteName: String,
        ownsUserDefaults: Bool,
        modelsDirectory: URL,
        ownsModelsDirectory: Bool
    ) {
        self.vm = vm
        self.mock = mock
        self.container = container
        self.userDefaults = userDefaults
        self.userDefaultsSuiteName = userDefaultsSuiteName
        self.ownsUserDefaults = ownsUserDefaults
        self.modelsDirectory = modelsDirectory
        self.ownsModelsDirectory = ownsModelsDirectory
    }

    func cleanup() {
        if ownsUserDefaults {
            userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        }
        if ownsModelsDirectory {
            try? FileManager.default.removeItem(at: modelsDirectory)
        }
    }
}

@MainActor
func makeTestChatViewModel(
    mock: MockInferenceBackend? = nil,
    ramGB: UInt64 = 16,
    activateSession: Bool = false,
    configurePersistence: Bool = false,
    modelsDirectory: URL? = nil,
    userDefaults: UserDefaults? = nil
) throws -> TestChatViewModelHarness {
    let suiteName: String
    let resolvedDefaults: UserDefaults
    let ownsDefaults: Bool
    if let userDefaults {
        suiteName = ""
        resolvedDefaults = userDefaults
        ownsDefaults = false
    } else {
        suiteName = "ManifoldKitTests-\(UUID().uuidString)"
        guard let allocated = UserDefaults(suiteName: suiteName) else {
            throw TestFactoryError.userDefaultsSuiteAllocationFailed(suiteName)
        }
        resolvedDefaults = allocated
        ownsDefaults = true
    }

    let resolvedModelsDirectory = modelsDirectory ?? makeIsolatedModelsDirectory()
    let oneGB: UInt64 = 1_073_741_824

    let inference: InferenceService
    if let mock {
        mock.isModelLoaded = true
        inference = InferenceService(backend: mock, name: "Mock")
    } else {
        inference = InferenceService()
    }

    let vm = ChatViewModel(
        inferenceService: inference,
        deviceCapability: DeviceCapabilityService(physicalMemory: ramGB * oneGB),
        modelStorage: ModelStorageService(baseDirectory: resolvedModelsDirectory),
        memoryPressure: MemoryPressureHandler(),
        userDefaults: resolvedDefaults
    )

    var container: ModelContainer?
    if configurePersistence {
        let c = try makeInMemoryContainer()
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: c.mainContext))
        container = c
    }

    if activateSession {
        vm.activeSession = ChatSession(title: "Test Session")
    }

    return TestChatViewModelHarness(
        vm: vm,
        mock: mock,
        container: container,
        userDefaults: resolvedDefaults,
        userDefaultsSuiteName: suiteName,
        ownsUserDefaults: ownsDefaults,
        modelsDirectory: resolvedModelsDirectory,
        ownsModelsDirectory: modelsDirectory == nil
    )
}

enum TestFactoryError: Error, CustomStringConvertible {
    case userDefaultsSuiteAllocationFailed(String)

    var description: String {
        switch self {
        case .userDefaultsSuiteAllocationFailed(let name):
            return "Failed to allocate UserDefaults suite '\(name)'"
        }
    }
}
