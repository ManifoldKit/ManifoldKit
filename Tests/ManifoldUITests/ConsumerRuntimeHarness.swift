import Foundation
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference

@MainActor
final class ConsumerRuntimeHarness {
    enum Error: Swift.Error {
        case userDefaultsSuiteAllocationFailed(String)
    }

    let runtime: ManifoldBootstrap
    let chatViewModel: ChatViewModel
    let sessionManager: SessionManagerViewModel
    let userDefaults: UserDefaults
    let modelsDirectory: URL

    private let originalConfiguration: ManifoldConfiguration
    private let userDefaultsSuiteName: String

    convenience init(
        inferenceService: InferenceService,
        toolApprovalGate: UIToolApprovalGate? = nil,
        foundationModelProvider: (@MainActor () -> Bool)? = nil
    ) throws {
        try self.init(
            inferenceService: inferenceService,
            toolApprovalGate: toolApprovalGate,
            foundationModelProvider: foundationModelProvider,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )
    }

    /// Test-only initializer that lets a caller inject a throwing
    /// `makeModelContainer` closure, which exercises the rollback/cleanup
    /// path when bootstrap fails partway through.
    ///
    /// `temporaryDirectory` defaults to `FileManager.default.temporaryDirectory`.
    /// Tests that inspect the cleanup path should pass a private directory so
    /// their assertions are not polluted by sibling tests running in parallel
    /// under `--parallel` execution — each harness dir is a child of this root,
    /// so an isolated root keeps assertions narrow.
    init(
        inferenceService: InferenceService,
        toolApprovalGate: UIToolApprovalGate? = nil,
        foundationModelProvider: (@MainActor () -> Bool)? = nil,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        makeModelContainer: @MainActor () throws -> ModelContainer
    ) throws {
        // Capture the live configuration before any mutation so the catch path
        // can roll ManifoldConfiguration.shared back to it untouched.
        let originalConfiguration = ManifoldConfiguration.shared

        let suiteName = "ManifoldConsumerRuntimeHarness-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw Error.userDefaultsSuiteAllocationFailed(suiteName)
        }

        let directory = temporaryDirectory
            .appendingPathComponent("consumer-runtime-harness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let configuration = ManifoldConfiguration(
            appName: "Consumer Runtime Harness",
            bundleIdentifier: "com.manifoldkit.consumer-runtime-harness.\(UUID().uuidString)"
        )

        do {
            let runtime = try ManifoldBootstrap(
                configuration: configuration,
                inferenceService: inferenceService,
                makeModelContainer: makeModelContainer
            )

            let chatViewModel = ChatViewModel(
                inferenceService: runtime.inferenceService,
                modelStorage: ModelStorageService(
                    baseDirectory: directory,
                    includeUserDocumentsFallback: false
                ),
                toolApprovalGate: toolApprovalGate,
                userDefaults: defaults,
                conversationRuntime: runtime.conversationRuntime
            )
            chatViewModel.foundationModelProvider = foundationModelProvider
            chatViewModel.configure(bootstrap: runtime)

            let sessionManager = SessionManagerViewModel()
            sessionManager.configure(bootstrap: runtime)

            self.originalConfiguration = originalConfiguration
            self.userDefaults = defaults
            self.userDefaultsSuiteName = suiteName
            self.modelsDirectory = directory
            self.runtime = runtime
            self.chatViewModel = chatViewModel
            self.sessionManager = sessionManager
        } catch {
            // Bootstrap failed after we mutated process-wide state — the
            // ManifoldBootstrap initializer rolls ManifoldConfiguration.shared
            // back itself, but we still own the UserDefaults suite + temp
            // directory we allocated above.
            ManifoldConfiguration.shared = originalConfiguration
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func cleanup() {
        chatViewModel.stopGeneration()
        runtime.inferenceService.unloadModel()
        ManifoldConfiguration.shared = originalConfiguration
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        try? FileManager.default.removeItem(at: modelsDirectory)
    }

    @discardableResult
    func createAndActivateSession(title: String = "New Chat") async throws -> ChatSessionRecord {
        let session = try await sessionManager.createSession(title: title)
        await switchToSession(session)
        return session
    }

    func switchToSession(_ session: ChatSessionRecord) async {
        sessionManager.activeSession = session
        await chatViewModel.switchToSession(session)
    }

    func persistedMessages(for session: ChatSessionRecord) async throws -> [ChatMessageRecord] {
        try await runtime.persistence.fetchMessages(for: session.id)
    }

    func persistedSessions() async throws -> [ChatSessionRecord] {
        try await runtime.persistence.fetchSessions()
    }
}
