import Foundation
@testable import BaseChatUI
@testable import BaseChatCore
@testable import BaseChatInference

@MainActor
final class ConsumerRuntimeHarness {
    enum Error: Swift.Error {
        case userDefaultsSuiteAllocationFailed(String)
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let runtime: BaseChatRuntime
    let chatViewModel: ChatViewModel
    let sessionManager: SessionManagerViewModel
    let userDefaults: UserDefaults
    let modelsDirectory: URL

    private let originalConfiguration: BaseChatConfiguration
    private let userDefaultsSuiteName: String

    init(
        inferenceService: InferenceService,
        toolApprovalGate: UIToolApprovalGate? = nil,
        foundationModelProvider: (@MainActor () -> Bool)? = nil
    ) throws {
        let suiteName = "BaseChatConsumerRuntimeHarness-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw Error.userDefaultsSuiteAllocationFailed(suiteName)
        }

        let directory = try Self.makeModelsDirectory()
        let configuration = BaseChatConfiguration(
            appName: "Consumer Runtime Harness",
            bundleIdentifier: "com.basechatkit.consumer-runtime-harness.\(UUID().uuidString)"
        )

        originalConfiguration = BaseChatConfiguration.shared
        userDefaults = defaults
        userDefaultsSuiteName = suiteName
        modelsDirectory = directory
        runtime = try BaseChatRuntime(
            configuration: configuration,
            inferenceService: inferenceService,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        let chatViewModel = ChatViewModel(
            inferenceService: runtime.inferenceService,
            modelStorage: ModelStorageService(baseDirectory: directory),
            toolApprovalGate: toolApprovalGate,
            userDefaults: defaults
        )
        chatViewModel.foundationModelProvider = foundationModelProvider
        chatViewModel.configure(runtime: runtime)
        self.chatViewModel = chatViewModel

        let sessionManager = SessionManagerViewModel()
        sessionManager.configure(runtime: runtime)
        self.sessionManager = sessionManager
    }

    func cleanup() {
        chatViewModel.stopGeneration()
        runtime.inferenceService.unloadModel()
        BaseChatConfiguration.shared = originalConfiguration
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        try? FileManager.default.removeItem(at: modelsDirectory)
    }

    @discardableResult
    func createAndActivateSession(title: String = "New Chat") throws -> ChatSessionRecord {
        let session = try sessionManager.createSession(title: title)
        switchToSession(session)
        return session
    }

    func switchToSession(_ session: ChatSessionRecord) {
        sessionManager.activeSession = session
        chatViewModel.switchToSession(session)
    }

    func persistedMessages(for session: ChatSessionRecord) throws -> [ChatMessageRecord] {
        try runtime.persistence.fetchMessages(for: session.id)
    }

    func persistedSessions() throws -> [ChatSessionRecord] {
        try runtime.persistence.fetchSessions()
    }

    private static func makeModelsDirectory() throws -> URL {
        let directory = repoRoot
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("consumer-runtime-harness", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
