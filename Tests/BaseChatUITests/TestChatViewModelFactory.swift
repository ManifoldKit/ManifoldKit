@preconcurrency import XCTest
import Foundation
import SwiftData
@testable import BaseChatUI
import BaseChatRuntime
import BaseChatPersistenceSwiftData
@testable import BaseChatInference
import BaseChatTestSupport

/// Shared `ChatViewModel` test factory. Replaces ~10 copies of the same
/// `private func makeViewModel(...)` / `private func makeViewModelWithMock(...)`
/// helper that diverged file-by-file across `Tests/BaseChatUITests/`.
///
/// Lives in the UI test target (not `BaseChatTestSupport`) because
/// `BaseChatTestSupport` deliberately does not depend on `BaseChatUI` — that
/// dependency would force the four non-UI test targets that import
/// `BaseChatTestSupport` (`BaseChatCoreTests`, `BaseChatInferenceTests`,
/// `BaseChatInferenceSwiftTestingTests`, `BaseChatTestSupportTests`) to also
/// pull in `BaseChatUI` transitively, slowing every CI run.
///
/// ## Carve-outs (intentionally NOT migrated)
///
/// Several test files have bespoke `makeViewModel*` helpers and stay local:
/// - `LoadDispatchCoordinationTests` — accepts a `configureService:` closure
/// - `ChatViewModelLoadPlanWiringTests` — registers backend factories on the load-plan environment
/// - `StreamingFailureTests` — bespoke backend instance + `configure(persistence:)`
/// - `ChatExportIntegrationTests` — bespoke `configure(persistence:)`
/// - The 3-tuple `(vm, mock, handler)` variant in `MemoryAndConcurrencyTests`
/// - `ChatViewModelCacheLifecycleTests` 3-tuple variant
/// - `ChatViewModelIntentDispatchTests` (constructs a no-isolated-storage VM)
///
/// ## Required teardown
///
/// Tests must call `harness.cleanup()` in their `tearDown` to release the
/// per-test `UserDefaults` suite. Per memory `userdefaults_standard_parallel_flake`,
/// production code touching `UserDefaults` must accept an injected instance —
/// using `UserDefaults.standard` from tests races with parallel runs.

@MainActor
struct TestChatViewModelHarness {
    /// The view model under test.
    let vm: ChatViewModel

    /// The pre-loaded mock backend (or `nil` when `mockLoaded == false` and
    /// no backend was wired). Tests that need to mutate `tokensToYield`
    /// access it through this handle.
    let mock: MockInferenceBackend?

    /// In-memory SwiftData container backing the persistence provider.
    /// Held by the harness so the container is not released mid-test —
    /// SwiftData traps if a context is accessed after its container deallocates.
    let container: ModelContainer?

    /// Per-test isolated `UserDefaults` suite — protects parallel test runs
    /// from racing on global keys like `hasCompletedFirstLaunch`.
    let userDefaults: UserDefaults

    /// Disk-backed temp directory for `ModelStorageService`. Removed by
    /// `cleanup()` only when the harness allocated it (i.e. the caller did
    /// not pass a pre-existing directory). Tests that share one directory
    /// across multiple harnesses must clean it up themselves.
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

    /// Releases the per-test `UserDefaults` suite (if owned) and removes
    /// the scratch models directory (if owned). Call from `tearDown`.
    func cleanup() {
        if ownsUserDefaults {
            userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        }
        if ownsModelsDirectory {
            try? FileManager.default.removeItem(at: modelsDirectory)
        }
    }
}

/// Builds a `ChatViewModel` with per-test isolated state for `UserDefaults`,
/// model storage, and (optionally) SwiftData persistence.
///
/// - Parameters:
///   - mock: When non-nil, the mock backend is wired into a fresh
///     `InferenceService(backend:name:)` and pre-loaded
///     (`mock.isModelLoaded = true`). Pass `nil` to build a VM with the
///     default `InferenceService()` (no backend loaded).
///   - ramGB: Physical-memory value the device-capability service reports.
///     Defaults to 16 GB — matches what every existing test passed.
///   - activateSession: When `true`, sets `vm.activeSession` to a fresh
///     `ChatSessionRecord(title: "Test Session")`. Tests that call
///     `sendMessage`/`regenerate`/`edit` need an active session.
///   - configurePersistence: When `true`, allocates an in-memory
///     `ModelContainer` and calls `vm.configure(persistence:)`. When `false`,
///     the harness's `container` is `nil`.
///   - modelsDirectory: Optional pre-existing scratch directory to use as
///     the `ModelStorageService` base directory. Defaults to a fresh
///     per-call temp directory. Pass an explicit value when multiple
///     harnesses in one test need to share the same directory (e.g. tests
///     that write fixtures via `createFakeGGUF` and then expect the VM's
///     `refreshModels()` to discover them).
///   - userDefaults: Optional pre-existing isolated `UserDefaults` suite.
///     Defaults to a fresh per-call suite. Pass an explicit value when a
///     test mutates the same suite directly (e.g. seeding the
///     `hasCompletedFirstLaunch` flag) and then constructs a VM that must
///     observe the seeded value.
///
/// - Returns: A `TestChatViewModelHarness`. Tests must call
///   `harness.cleanup()` in `tearDown`.
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
        // Caller-supplied — they own teardown.
        suiteName = ""
        resolvedDefaults = userDefaults
        ownsDefaults = false
    } else {
        suiteName = "BaseChatKitTests-\(UUID().uuidString)"
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
        vm.activeSession = ChatSessionRecord(title: "Test Session")
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
