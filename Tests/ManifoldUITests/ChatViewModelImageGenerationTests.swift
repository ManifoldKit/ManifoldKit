@preconcurrency import XCTest
import Foundation
import os
@testable import ManifoldUI
@testable import ManifoldRuntime
@testable import ManifoldInference

/// Coverage for ``ChatViewModel`` image-generation entry surface — runtime
/// install, command forwarding, and event-to-progress mapping.
@MainActor
final class ChatViewModelImageGenerationTests: XCTestCase {

    // MARK: - In-memory MessageStore

    @MainActor
    final class TestMessageStore: MessageStore {
        private(set) var messages: [UUID: ChatMessage] = [:]

        func insertMessage(_ message: ChatMessage) async throws {
            messages[message.id] = message
        }
        func updateMessage(_ message: ChatMessage) async throws {
            guard messages[message.id] != nil else {
                throw ChatPersistenceError.messageNotFound(message.id)
            }
            messages[message.id] = message
        }
        func deleteMessage(_ messageID: UUID) async throws {
            messages.removeValue(forKey: messageID)
        }
        func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] {
            messages.values.filter { $0.sessionID == sessionID }.sorted { $0.timestamp < $1.timestamp }
        }
        func deleteMessages(for sessionID: UUID) async throws {
            messages = messages.filter { $0.value.sessionID != sessionID }
        }
        func addPostWriteHook(_ hook: any MessageStorePostWriteHook) {}
    }

    // MARK: - Mock backend (driven by a configurable plan)

    final class MockImageBackend: ImageGenerationBackend, @unchecked Sendable {
        struct Plan: Sendable {
            var events: [ImageGenerationEvent] = []
            var trailingError: (any Error)?
            var delayPerEventNs: UInt64 = 1_000_000
        }

        private struct State: Sendable {
            var isLoaded = true
            var isGenerating = false
            var plan = Plan()
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        var isLoaded: Bool { state.withLock { $0.isLoaded } }
        var isGenerating: Bool { state.withLock { $0.isGenerating } }

        func setPlan(_ plan: Plan) { state.withLock { $0.plan = plan } }

        func loadModel(from url: URL) async throws { state.withLock { $0.isLoaded = true } }

        func generate(
            prompt: String,
            config: ImageGenerationConfig
        ) throws -> AsyncThrowingStream<ImageGenerationEvent, Error> {
            let plan: Plan = state.withLock { snap in
                snap.isGenerating = true
                return snap.plan
            }
            return AsyncThrowingStream { continuation in
                let task = Task<Void, Never> { [self] in
                    for event in plan.events {
                        if Task.isCancelled { break }
                        try? await Task.sleep(nanoseconds: plan.delayPerEventNs)
                        if Task.isCancelled { break }
                        continuation.yield(event)
                    }
                    if let trailingError = plan.trailingError, !Task.isCancelled {
                        continuation.finish(throwing: trailingError)
                    } else {
                        continuation.finish()
                    }
                    self.state.withLock { $0.isGenerating = false }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        func stopGeneration() { state.withLock { $0.isGenerating = false } }
        func unloadModel() { state.withLock { $0.isLoaded = false } }
    }

    // MARK: - Builders

    private func makeRuntime(backend: MockImageBackend) async throws -> (ImageGenerationRuntime, TestMessageStore) {
        let service = ImageGenerationService()
        let captured = backend
        service.registerBackendFactory(for: .mlxDiffusion) { _ in captured }
        let info = ImageModelInfo(
            id: "test-model",
            name: "Test Model",
            directoryURL: URL(fileURLWithPath: NSTemporaryDirectory()),
            format: .mlxDiffusion,
            fileSize: 1
        )
        try await service.loadModel(info)
        let store = TestMessageStore()
        let runtime = ImageGenerationRuntime(service: service, messageStore: store)
        return (runtime, store)
    }

    private func makeViewModel() -> ChatViewModel {
        ChatViewModel(
            inferenceService: InferenceService(),
            userDefaults: UserDefaults(suiteName: "ChatViewModelImageGenerationTests-\(UUID().uuidString)")!
        )
    }

    /// Spin until `predicate(vm.imageGenerationProgress[messageID])` becomes
    /// `true`, or fail after `timeout`. The progress dict is updated from a
    /// detached `@MainActor` task so we yield in a tight loop rather than
    /// using a one-shot expectation — events arrive in batches.
    private func awaitProgress(
        _ vm: ChatViewModel,
        for messageID: UUID,
        until predicate: (ImageGenerationProgress) -> Bool,
        timeout: TimeInterval = 5.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if let progress = vm.imageGenerationProgress[messageID], predicate(progress) {
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for progress predicate on \(messageID)", file: file, line: line)
    }

    // MARK: - Test 1: not configured

    func test_generateImage_withoutConfiguredRuntime_throwsNotConfigured() async {
        let vm = makeViewModel()
        vm.activeSession = ChatSession(title: "Test")
        do {
            _ = try await vm.generateImage(prompt: "x", config: ImageGenerationConfig())
            XCTFail("Expected throw")
        } catch let error as ChatViewModelImageError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Test 2: no active conversation

    func test_generateImage_withoutActiveSession_throwsNoActiveConversation() async throws {
        let backend = MockImageBackend()
        let (runtime, _) = try await makeRuntime(backend: backend)
        let vm = makeViewModel()
        vm.configure(imageRuntime: runtime)
        // No session set — activeSessionID is nil.
        XCTAssertNil(vm.activeSessionID)
        do {
            _ = try await vm.generateImage(prompt: "x", config: ImageGenerationConfig())
            XCTFail("Expected throw")
        } catch let error as ChatViewModelImageError {
            XCTAssertEqual(error, .noActiveConversation)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Test 3: happy path

    func test_generateImage_happyPath_populatesProgress() async throws {
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ivm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }

        let imageURL = outDir.appendingPathComponent("out.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

        let backend = MockImageBackend()
        backend.setPlan(.init(events: [
            .progress(step: 1, total: 4),
            .progress(step: 2, total: 4),
            .progress(step: 3, total: 4),
            .progress(step: 4, total: 4),
            .completed(imageURL)
        ]))

        let (runtime, _) = try await makeRuntime(backend: backend)
        let vm = makeViewModel()
        vm.configure(imageRuntime: runtime)
        vm.activeSession = ChatSession(title: "Image Test")

        let messageID = try await vm.generateImage(
            prompt: "a cat",
            config: ImageGenerationConfig(steps: 4, width: 64, height: 64, outputDirectory: outDir)
        )

        // First, started should arrive (step 0).
        await awaitProgress(vm, for: messageID) { p in
            p.prompt == "a cat" && !p.isComplete
        }

        // Wait for terminal completion.
        await awaitProgress(vm, for: messageID) { $0.isComplete && $0.error == nil }

        let final = vm.imageGenerationProgress[messageID]
        XCTAssertNotNil(final)
        XCTAssertEqual(final?.prompt, "a cat")
        XCTAssertTrue(final?.isComplete ?? false)
        XCTAssertNil(final?.error)
    }

    // MARK: - Test 4: failed generation

    func test_generateImage_failure_surfacesErrorInProgress() async throws {
        struct BoomError: LocalizedError { var errorDescription: String? { "boom" } }

        let backend = MockImageBackend()
        backend.setPlan(.init(events: [.progress(step: 1, total: 4)], trailingError: BoomError()))

        let (runtime, _) = try await makeRuntime(backend: backend)
        let vm = makeViewModel()
        vm.configure(imageRuntime: runtime)
        vm.activeSession = ChatSession(title: "Fail Test")

        let messageID = try await vm.generateImage(
            prompt: "broken",
            config: ImageGenerationConfig(steps: 4, width: 64, height: 64)
        )

        await awaitProgress(vm, for: messageID) { $0.isComplete && $0.error != nil }
        XCTAssertEqual(vm.imageGenerationProgress[messageID]?.error, "boom")
    }

    // MARK: - Test 5: cancel

    func test_cancelImageGeneration_marksProgressComplete() async throws {
        let backend = MockImageBackend()
        // Long-running plan so we can cancel mid-flight.
        backend.setPlan(.init(
            events: (1...20).map { .progress(step: $0, total: 20) },
            delayPerEventNs: 20_000_000  // 20ms each
        ))

        let (runtime, _) = try await makeRuntime(backend: backend)
        let vm = makeViewModel()
        vm.configure(imageRuntime: runtime)
        vm.activeSession = ChatSession(title: "Cancel Test")

        let messageID = try await vm.generateImage(
            prompt: "slow",
            config: ImageGenerationConfig(steps: 20, width: 64, height: 64)
        )

        // Wait for at least one progress event.
        await awaitProgress(vm, for: messageID) { !$0.isComplete }

        await vm.cancelImageGeneration(messageID: messageID)
        await awaitProgress(vm, for: messageID) { $0.isComplete && $0.error == nil }
    }

    // MARK: - Test 6: reconfigure cancels prior subscription

    func test_configure_reconfigureCancelsPriorSubscription() async throws {
        let backend1 = MockImageBackend()
        backend1.setPlan(.init(events: [.progress(step: 1, total: 4)]))
        let (runtime1, _) = try await makeRuntime(backend: backend1)

        let backend2 = MockImageBackend()
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ivm-reconf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }
        let imageURL = outDir.appendingPathComponent("out.png")
        try Data([0x89]).write(to: imageURL)
        backend2.setPlan(.init(events: [
            .progress(step: 1, total: 1),
            .completed(imageURL)
        ]))
        let (runtime2, _) = try await makeRuntime(backend: backend2)

        let vm = makeViewModel()
        vm.configure(imageRuntime: runtime1)
        // Capture the first drain task to assert it's been cancelled after
        // reconfigure.
        let firstDrain = vm.imageRuntimeEventDrainTask
        XCTAssertNotNil(firstDrain)

        vm.configure(imageRuntime: runtime2)
        XCTAssertTrue(firstDrain?.isCancelled ?? false, "Prior drain task should be cancelled")
        XCTAssertNotNil(vm.imageRuntimeEventDrainTask)
        XCTAssertNotIdentical(
            vm.imageRuntime as AnyObject,
            runtime1 as AnyObject
        )

        vm.activeSession = ChatSession(title: "Reconf Test")
        let messageID = try await vm.generateImage(
            prompt: "second",
            config: ImageGenerationConfig(steps: 1, width: 64, height: 64, outputDirectory: outDir)
        )

        // The new runtime's events feed the dict.
        await awaitProgress(vm, for: messageID) { $0.isComplete && $0.error == nil }
    }
}
