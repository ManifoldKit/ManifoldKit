@preconcurrency import XCTest
import Foundation
import os
@testable import ManifoldUI
@testable import ManifoldRuntime
@testable import ManifoldInference

/// Coverage for ``ArchitectViewModel`` folding image- and video-generation
/// runtime events into the same `eventLog` the conversation runtime feeds.
///
/// The Architect (Glass Box) timeline taps each runtime's `addEventTap()`
/// multicast stream; these tests drive real ``ImageGenerationRuntime`` /
/// ``VideoGenerationRuntime`` instances through mock backends and assert the
/// resulting rows carry the right category and preserve ordering.
@MainActor
final class ArchitectViewModelGenerationEventsTests: XCTestCase {

    // MARK: - In-memory MessageStore

    @MainActor
    final class TestMessageStore: MessageStore {
        private(set) var messages: [UUID: ChatMessageRecord] = [:]

        func insertMessage(_ message: ChatMessageRecord) async throws {
            messages[message.id] = message
        }
        func updateMessage(_ message: ChatMessageRecord) async throws {
            guard messages[message.id] != nil else {
                throw ChatPersistenceError.messageNotFound(message.id)
            }
            messages[message.id] = message
        }
        func deleteMessage(_ messageID: UUID) async throws {
            messages.removeValue(forKey: messageID)
        }
        func fetchMessages(for sessionID: UUID) async throws -> [ChatMessageRecord] {
            messages.values.filter { $0.sessionID == sessionID }.sorted { $0.timestamp < $1.timestamp }
        }
        func deleteMessages(for sessionID: UUID) async throws {
            messages = messages.filter { $0.value.sessionID != sessionID }
        }
        func addPostWriteHook(_ hook: any MessageStorePostWriteHook) {}
    }

    // MARK: - Mock image backend

    final class MockImageBackend: ImageGenerationBackend, @unchecked Sendable {
        struct Plan: Sendable {
            var events: [ImageGenerationEvent] = []
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
                    continuation.finish()
                    self.state.withLock { $0.isGenerating = false }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        func stopGeneration() { state.withLock { $0.isGenerating = false } }
        func unloadModel() { state.withLock { $0.isLoaded = false } }
    }

    // MARK: - Mock video backend

    final class MockVideoBackend: VideoGenerationBackend, @unchecked Sendable {
        struct Plan: Sendable {
            var events: [VideoGenerationEvent] = []
            var delayPerEventNs: UInt64 = 1_000_000
        }
        private let lock = OSAllocatedUnfairLock(initialState: Plan())
        func setPlan(_ plan: Plan) { lock.withLock { $0 = plan } }

        func generate(
            prompt: String,
            config: VideoGenerationConfig
        ) async throws -> AsyncThrowingStream<VideoGenerationEvent, Error> {
            let plan = lock.withLock { $0 }
            return AsyncThrowingStream { continuation in
                let task = Task<Void, Never> {
                    for event in plan.events {
                        if Task.isCancelled { break }
                        try? await Task.sleep(nanoseconds: plan.delayPerEventNs)
                        if Task.isCancelled { break }
                        continuation.yield(event)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        func cancel() async {}
    }

    // MARK: - Builders

    private func makeConversationRuntime() -> ConversationRuntime {
        ConversationRuntime(
            messageStore: TestMessageStore(),
            inferenceService: InferenceService()
        )
    }

    private func makeImageRuntime(backend: MockImageBackend) async throws -> ImageGenerationRuntime {
        let service = ImageGenerationService()
        let captured = backend
        service.registerBackendFactory(for: .mlxDiffusion) { _ in captured }
        let info = ImageModelInfo(
            id: "img-model",
            name: "Image Model",
            directoryURL: URL(fileURLWithPath: NSTemporaryDirectory()),
            format: .mlxDiffusion,
            fileSize: 1
        )
        try await service.loadModel(info)
        return ImageGenerationRuntime(service: service, messageStore: TestMessageStore())
    }

    private func makeVideoRuntime(backend: MockVideoBackend) -> VideoGenerationRuntime {
        VideoGenerationRuntime(
            service: VideoGenerationService(backend: backend),
            messageStore: TestMessageStore(),
            modelIdentifier: { "video-model" }
        )
    }

    /// Spin until `predicate(vm.eventLog)` becomes true, or fail after timeout.
    private func awaitLog(
        _ vm: ArchitectViewModel,
        until predicate: ([ArchitectEventEntry]) -> Bool,
        timeout: TimeInterval = 5.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if predicate(vm.eventLog) { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for eventLog predicate", file: file, line: line)
    }

    // MARK: - Test 1: image events fold in with the right category

    func test_imageEvents_foldIntoEventLog_withImageCategory() async throws {
        let imageURL = URL(fileURLWithPath: "/tmp/arch-img-\(UUID().uuidString).png")
        let backend = MockImageBackend()
        backend.setPlan(.init(events: [
            .progress(step: 1, total: 2),
            .progress(step: 2, total: 2),
            .completed(imageURL)
        ]))
        let imageRuntime = try await makeImageRuntime(backend: backend)

        let vm = ArchitectViewModel(
            runtime: makeConversationRuntime(),
            imageRuntime: imageRuntime,
            videoRuntime: nil
        )
        vm.startRecording()

        _ = try await imageRuntime.generate(
            prompt: "a fox",
            config: ImageGenerationConfig(steps: 2, width: 64, height: 64),
            in: UUID()
        )

        await awaitLog(vm) { log in
            log.contains { $0.label == "image.completed" }
        }

        let imageEntries = vm.eventLog.filter { $0.category == .imageGeneration }
        XCTAssertTrue(imageEntries.contains { $0.label == "image.started" })
        XCTAssertTrue(imageEntries.contains { $0.label == "image.progress" })
        XCTAssertTrue(imageEntries.contains { $0.label == "image.completed" })
        // None of the image rows should be miscategorised as conversation events.
        XCTAssertTrue(imageEntries.allSatisfy { $0.kind == nil && $0.event == nil })
        // The started row's summary should carry the prompt.
        let started = imageEntries.first { $0.label == "image.started" }
        XCTAssertEqual(started?.summary, "\"a fox\"")
    }

    // MARK: - Test 2: video events fold in with the right category

    func test_videoEvents_foldIntoEventLog_withVideoCategory() async throws {
        let videoURL = URL(fileURLWithPath: "/tmp/arch-vid-\(UUID().uuidString).mp4")
        let backend = MockVideoBackend()
        backend.setPlan(.init(events: [
            .queued,
            .generating(fractionComplete: 0.5),
            .completed(videoURL)
        ]))
        let videoRuntime = makeVideoRuntime(backend: backend)

        let vm = ArchitectViewModel(
            runtime: makeConversationRuntime(),
            imageRuntime: nil,
            videoRuntime: videoRuntime
        )
        vm.startRecording()

        _ = try await videoRuntime.generate(
            prompt: "a wave",
            config: VideoGenerationConfig(duration: 5, aspectRatio: VideoGenerationConfig.AspectRatio.landscape),
            in: UUID()
        )

        await awaitLog(vm) { log in
            log.contains { $0.label == "video.completed" }
        }

        let videoEntries = vm.eventLog.filter { $0.category == .videoGeneration }
        XCTAssertTrue(videoEntries.contains { $0.label == "video.started" })
        XCTAssertTrue(videoEntries.contains { $0.label == "video.progress" })
        XCTAssertTrue(videoEntries.contains { $0.label == "video.completed" })
        XCTAssertTrue(videoEntries.allSatisfy { $0.kind == nil && $0.event == nil })
    }

    // MARK: - Test 3: ordering preserved + monotonic index across sources

    func test_imageThenVideo_preservesOrderingAndMonotonicIndex() async throws {
        let imageBackend = MockImageBackend()
        imageBackend.setPlan(.init(events: [
            .progress(step: 1, total: 1),
            .completed(URL(fileURLWithPath: "/tmp/arch-img-\(UUID().uuidString).png"))
        ]))
        let imageRuntime = try await makeImageRuntime(backend: imageBackend)

        let videoBackend = MockVideoBackend()
        videoBackend.setPlan(.init(events: [
            .generating(fractionComplete: 1.0),
            .completed(URL(fileURLWithPath: "/tmp/arch-vid-\(UUID().uuidString).mp4"))
        ]))
        let videoRuntime = makeVideoRuntime(backend: videoBackend)

        let vm = ArchitectViewModel(
            runtime: makeConversationRuntime(),
            imageRuntime: imageRuntime,
            videoRuntime: videoRuntime
        )
        vm.startRecording()

        // Drive image to completion first, then video — ordering in eventLog
        // should reflect arrival order.
        _ = try await imageRuntime.generate(
            prompt: "first",
            config: ImageGenerationConfig(steps: 1, width: 64, height: 64),
            in: UUID()
        )
        await awaitLog(vm) { log in log.contains { $0.label == "image.completed" } }

        _ = try await videoRuntime.generate(
            prompt: "second",
            config: VideoGenerationConfig(duration: 5, aspectRatio: VideoGenerationConfig.AspectRatio.landscape),
            in: UUID()
        )
        await awaitLog(vm) { log in log.contains { $0.label == "video.completed" } }

        // Indices are unique and strictly increasing in append order.
        let indices = vm.eventLog.map(\.index)
        XCTAssertEqual(indices, indices.sorted(), "indices must be monotonic in append order")
        XCTAssertEqual(Set(indices).count, indices.count, "indices must be unique across sources")

        // The last image row precedes the first video row.
        guard
            let lastImageIdx = vm.eventLog.lastIndex(where: { $0.category == .imageGeneration }),
            let firstVideoIdx = vm.eventLog.firstIndex(where: { $0.category == .videoGeneration })
        else {
            return XCTFail("expected both image and video entries in the log")
        }
        XCTAssertLessThan(lastImageIdx, firstVideoIdx, "image events should precede video events")
    }

    // MARK: - Test 4: nil-safe — chat-only host installs no generation taps

    func test_nilGenerationRuntimes_recordsWithoutCrash() async throws {
        let vm = ArchitectViewModel(
            runtime: makeConversationRuntime(),
            imageRuntime: nil,
            videoRuntime: nil
        )
        vm.startRecording()
        XCTAssertTrue(vm.isRecording)
        // No generation runtimes wired and no turn driven — the log stays empty.
        XCTAssertTrue(vm.eventLog.isEmpty)
        vm.stopRecording()
        XCTAssertFalse(vm.isRecording)
    }

    // MARK: - Test 5: failed image event is flagged as an error row

    func test_imageFailure_marksEntryAsError() async throws {
        struct BoomError: LocalizedError { var errorDescription: String? { "kaboom" } }

        let backend = MockImageBackend()
        // Drive a started event then let the runtime fail (empty completion path
        // surfaces as `.failed` once the stream ends without `.completed`).
        backend.setPlan(.init(events: [.progress(step: 1, total: 2)]))
        let imageRuntime = try await makeImageRuntime(backend: backend)

        let vm = ArchitectViewModel(
            runtime: makeConversationRuntime(),
            imageRuntime: imageRuntime,
            videoRuntime: nil
        )
        vm.startRecording()

        _ = try await imageRuntime.generate(
            prompt: "doomed",
            config: ImageGenerationConfig(steps: 2, width: 64, height: 64),
            in: UUID()
        )

        await awaitLog(vm) { log in
            log.contains { $0.label == "image.failed" }
        }
        let failed = vm.eventLog.first { $0.label == "image.failed" }
        XCTAssertEqual(failed?.category, .imageGeneration)
        XCTAssertTrue(failed?.isError ?? false, "failed image row must be flagged isError")
    }
}
