import XCTest
import Foundation
@testable import ManifoldInference

/// Tests for ``ImageGenerationService``: the registration + lifecycle surface
/// for the image-generation path. Mirrors the role
/// ``ImageGenerationFoundationsTests`` plays for the value types — locks down
/// the public shape against a stub backend before any real conformer ships.
@MainActor
final class ImageGenerationServiceTests: XCTestCase {

    // MARK: - Test Doubles

    /// Mock conformer used to drive the service's lifecycle without standing
    /// up a real diffusion runtime. Per-test instances are fine because the
    /// service holds the only strong reference; tests reach into `events` /
    /// `loadCount` / `unloadCount` via the captured factory closure.
    ///
    /// ### Thread-safety
    ///
    /// `loadModel` runs off-actor on a `Task.detached` (the service hops
    /// the load into the background), and `generate(prompt:config:)` is
    /// invoked synchronously on the main actor before the service starts
    /// iterating its returned stream off-actor. `stopGeneration` /
    /// `unloadModel` are called on the main actor by the service. Tests
    /// only sample these counters after `await`-ing the corresponding
    /// service entrypoint (`loadModel` / `unload` / a fully drained
    /// `generate` stream), so each read happens-after the matching write
    /// via that suspension point — sequential consistency is therefore
    /// guaranteed without an explicit lock. The class is marked
    /// `@unchecked Sendable` only to satisfy the protocol's `Sendable`
    /// requirement; the mock has no concurrent writers in any of the
    /// tests below.
    private final class MockBackend: ImageGenerationBackend, @unchecked Sendable {
        var isLoaded: Bool = false
        var isGenerating: Bool = false

        var loadCount: Int = 0
        var unloadCount: Int = 0
        var stopCount: Int = 0
        var loadShouldThrow: Error?
        var generateShouldThrow: Error?
        var scriptedEvents: [ImageGenerationEvent] = []

        func loadModel(from url: URL) async throws {
            loadCount += 1
            if let err = loadShouldThrow { throw err }
            isLoaded = true
        }

        func generate(
            prompt: String,
            config: ImageGenerationConfig
        ) throws -> AsyncThrowingStream<ImageGenerationEvent, Error> {
            if let err = generateShouldThrow { throw err }
            isGenerating = true
            let events = scriptedEvents
            return AsyncThrowingStream { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }

        func stopGeneration() {
            stopCount += 1
            isGenerating = false
        }

        func unloadModel() {
            unloadCount += 1
            isLoaded = false
        }
    }

    private func makeInfo(id: String = "stabilityai/sdxl-turbo") -> ImageModelInfo {
        ImageModelInfo(
            id: id,
            name: id,
            directoryURL: URL(fileURLWithPath: "/tmp/\(id)"),
            format: .mlxDiffusion,
            fileSize: 4_200_000_000
        )
    }

    // MARK: - 1. Happy-path load

    func test_loadModel_happyPath_transitionsIdleToLoaded() async throws {
        let service = ImageGenerationService()
        let mock = MockBackend()
        let info = makeInfo()

        service.registerBackendFactory(for: .mlxDiffusion) { _ in mock }

        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(service.loadedModel)

        try await service.loadModel(info)

        XCTAssertEqual(service.state, .loaded(info))
        XCTAssertEqual(service.loadedModel, info)
        XCTAssertEqual(mock.loadCount, 1)
        XCTAssertTrue(mock.isLoaded)
    }

    // MARK: - 2. No factory registered

    func test_loadModel_noFactory_throwsNoFactoryRegistered() async {
        let service = ImageGenerationService()
        let info = makeInfo()

        do {
            try await service.loadModel(info)
            XCTFail("expected throw")
        } catch let error as ImageGenerationServiceError {
            XCTAssertEqual(error, .noFactoryRegistered(format: .mlxDiffusion))
        } catch {
            XCTFail("expected ImageGenerationServiceError, got \(error)")
        }

        // State must return to idle even though we transitioned through
        // nothing — caller should be able to register a factory and retry.
        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(service.loadedModel)
    }

    // MARK: - 3. Load while loaded unloads prior

    /// Sabotage target: this test exercises the `unload-then-load` swap. If
    /// the implementation skips the unload step, `priorMock.unloadCount` will
    /// be 0 and the test fails — sabotage check confirmed during development.
    func test_loadModel_whileLoaded_unloadsPriorThenLoadsNew() async throws {
        let service = ImageGenerationService()
        let priorMock = MockBackend()
        let nextMock = MockBackend()
        let priorInfo = makeInfo(id: "stabilityai/sd-1.5")
        let nextInfo = makeInfo(id: "stabilityai/sdxl-turbo")

        // Register a factory that returns whichever mock matches the request
        // (keyed by ID so order doesn't matter).
        service.registerBackendFactory(for: .mlxDiffusion) { info in
            info.id == priorInfo.id ? priorMock : nextMock
        }

        try await service.loadModel(priorInfo)
        XCTAssertEqual(service.state, .loaded(priorInfo))
        XCTAssertEqual(priorMock.unloadCount, 0)

        try await service.loadModel(nextInfo)

        XCTAssertEqual(priorMock.unloadCount, 1, "prior backend must be unloaded before new load")
        XCTAssertEqual(nextMock.loadCount, 1)
        XCTAssertEqual(service.state, .loaded(nextInfo))
        XCTAssertEqual(service.loadedModel, nextInfo)
    }

    // MARK: - 4. Generate without loaded throws

    func test_generate_withoutLoadedModel_streamThrowsNotLoaded() async {
        let service = ImageGenerationService()

        let stream = service.generate(prompt: "hello", config: ImageGenerationConfig())

        do {
            for try await _ in stream {
                XCTFail("expected stream to finish with error before yielding")
            }
            XCTFail("expected stream to throw")
        } catch let error as ImageGenerationServiceError {
            XCTAssertEqual(error, .notLoaded)
        } catch {
            XCTFail("expected ImageGenerationServiceError.notLoaded, got \(error)")
        }
    }

    // MARK: - 5. Generate happy path

    func test_generate_happyPath_forwardsEventsAndRestoresLoadedState() async throws {
        let service = ImageGenerationService()
        let mock = MockBackend()
        let info = makeInfo()
        let outURL = URL(fileURLWithPath: "/tmp/out.png")
        mock.scriptedEvents = [
            .progress(step: 1, total: 4),
            .progress(step: 2, total: 4),
            .progress(step: 3, total: 4),
            .progress(step: 4, total: 4),
            .completed(outURL),
        ]

        service.registerBackendFactory(for: .mlxDiffusion) { _ in mock }
        try await service.loadModel(info)

        let stream = service.generate(
            prompt: "a teal turtle",
            config: ImageGenerationConfig(steps: 4, width: 512, height: 512)
        )

        var events: [ImageGenerationEvent] = []
        for try await event in stream {
            events.append(event)
        }

        XCTAssertEqual(events.count, 5)
        if case .completed(let url) = events.last {
            XCTAssertEqual(url, outURL)
        } else {
            XCTFail("last event should be .completed")
        }

        // After the stream finishes the service must return to .loaded so
        // the next generate call doesn't have to re-load the model.
        XCTAssertEqual(service.state, .loaded(info))
        XCTAssertEqual(service.loadedModel, info)
    }

    // MARK: - 6. Unload returns service to idle

    func test_unload_afterLoad_returnsServiceToIdle() async throws {
        let service = ImageGenerationService()
        let mock = MockBackend()
        let info = makeInfo()

        service.registerBackendFactory(for: .mlxDiffusion) { _ in mock }
        try await service.loadModel(info)
        XCTAssertEqual(service.state, .loaded(info))

        await service.unload()

        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(service.loadedModel)
        XCTAssertEqual(mock.unloadCount, 1)
        XCTAssertFalse(mock.isLoaded)
    }

    // MARK: - 7. Generate while not in .loaded(info) treats stream as notLoaded

    /// Race regression: if the service's state changed between
    /// `service.generate(...)` snapshotting `loadedModel` and the wrapper
    /// observing the state again, generate must not stomp the newer state
    /// with `.generating(info)` for the old model. The race is only
    /// reachable from arbitrary actors interleaving on `await`-points;
    /// here we simulate it by mutating state via `unload()` on a separate
    /// task between the `loadModel` await and the `generate` snapshot.
    /// What we can deterministically assert in a single-actor test is that
    /// once `unload()` returns and we then call `generate`, the stream
    /// fails with `.notLoaded` — no backend call leaks through.
    func test_generate_afterUnload_streamThrowsNotLoaded() async throws {
        let service = ImageGenerationService()
        let mock = MockBackend()
        let info = makeInfo()

        service.registerBackendFactory(for: .mlxDiffusion) { _ in mock }
        try await service.loadModel(info)
        await service.unload()

        let stream = service.generate(prompt: "x", config: ImageGenerationConfig())

        do {
            for try await _ in stream {
                XCTFail("stream must not yield after unload")
            }
            XCTFail("stream must throw")
        } catch let error as ImageGenerationServiceError {
            XCTAssertEqual(error, .notLoaded)
        } catch {
            XCTFail("expected ImageGenerationServiceError.notLoaded, got \(error)")
        }
    }

    // MARK: - 8. Consumer drops the stream early → state restores to .loaded

    /// Backend whose stream yields events on a real per-event delay so a
    /// consumer can drop the iterator mid-stream (with events still queued),
    /// forcing the `onTermination(.cancelled)` cleanup path. The default
    /// `MockBackend` finishes synchronously, leaving no early-drop window.
    private final class SlowMockBackend: ImageGenerationBackend, @unchecked Sendable {
        var isLoaded: Bool = false
        var isGenerating: Bool = false
        let events: [ImageGenerationEvent]
        let delayPerEventNs: UInt64

        init(events: [ImageGenerationEvent], delayPerEventNs: UInt64) {
            self.events = events
            self.delayPerEventNs = delayPerEventNs
        }

        func loadModel(from url: URL) async throws { isLoaded = true }

        func generate(
            prompt: String,
            config: ImageGenerationConfig
        ) throws -> AsyncThrowingStream<ImageGenerationEvent, Error> {
            isGenerating = true
            let events = self.events
            let delay = self.delayPerEventNs
            return AsyncThrowingStream { continuation in
                let task = Task<Void, Never> {
                    for event in events {
                        if Task.isCancelled { break }
                        do {
                            try await Task.sleep(nanoseconds: delay)
                        } catch {
                            break
                        }
                        if Task.isCancelled { break }
                        continuation.yield(event)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        func stopGeneration() { isGenerating = false }
        func unloadModel() { isLoaded = false }
    }

    /// Regression: when the consumer drops the stream after the first event
    /// (with more events still queued), the service's must-complete
    /// state-restore must still run and return the service to `.loaded`. Before
    /// the `[weak self]` → strong-`self` fix the restore could be dropped,
    /// leaving the service stuck in `.generating`.
    func test_generate_consumerDropsEarly_restoresLoadedState() async throws {
        let outURL = URL(fileURLWithPath: "/tmp/out.png")
        let mock = SlowMockBackend(
            events: [
                .progress(step: 1, total: 5),
                .progress(step: 2, total: 5),
                .progress(step: 3, total: 5),
                .progress(step: 4, total: 5),
                .completed(outURL),
            ],
            delayPerEventNs: 20_000_000  // 20ms
        )
        let info = makeInfo()
        let service = ImageGenerationService()
        service.registerBackendFactory(for: .mlxDiffusion) { _ in mock }
        try await service.loadModel(info)

        let stream = service.generate(prompt: "x", config: ImageGenerationConfig())

        // Consume one event then drop the iterator. onTermination(.cancelled)
        // cancels the forwarding task, whose strong-self cleanup must run.
        for try await _ in stream {
            break
        }

        // Cleanup hops back to the main actor asynchronously; poll-settle.
        try await pollUntilState(service, equals: .loaded(info), timeoutNs: 2_000_000_000)
        XCTAssertEqual(service.state, .loaded(info), "service must return to .loaded after the consumer drops the stream early")
        XCTAssertEqual(service.loadedModel, info)
    }

    /// Sabotage-provable regression for the dealloc race. The bug: the
    /// forwarding `Task.detached` captured `[weak self]`, so when the only
    /// strong reference to the service is dropped mid-stream the task does NOT
    /// keep it alive — the service deallocates and `await self?.restoreLoadedState(...)`
    /// no-ops, dropping the cleanup. The fix strong-captures `self`, so the task
    /// retains the service until it finishes; the service must therefore still
    /// be alive while a generation is in flight even after every external strong
    /// reference is released.
    func test_generate_consumerDropsEarly_taskRetainsServiceUntilCleanup() async throws {
        let mock = SlowMockBackend(
            events: [
                .progress(step: 1, total: 3),
                .progress(step: 2, total: 3),
                .completed(URL(fileURLWithPath: "/tmp/out.png")),
            ],
            delayPerEventNs: 500_000_000  // 500ms — task reliably in-flight at the assert
        )
        let info = makeInfo()

        weak var weakService: ImageGenerationService?
        var stream: AsyncThrowingStream<ImageGenerationEvent, Error>?

        do {
            let service = ImageGenerationService()
            service.registerBackendFactory(for: .mlxDiffusion) { _ in mock }
            try await service.loadModel(info)
            weakService = service
            stream = service.generate(prompt: "x", config: ImageGenerationConfig())
            XCTAssertEqual(service.state, .generating(info))
            // `service` leaves scope here — the forwarding task is the only
            // remaining potential owner (iff it strong-captured self).
        }

        XCTAssertNotNil(
            weakService,
            "forwarding task must retain the service while a generation is in flight (regressed under [weak self])"
        )

        withExtendedLifetime(stream) {}
        stream = nil
    }

    /// Polls `service.state` until it equals `expected` or the timeout elapses.
    private func pollUntilState(
        _ service: ImageGenerationService,
        equals expected: ImageGenerationService.State,
        timeoutNs: UInt64
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNs
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if service.state == expected { return }
            try await Task.sleep(nanoseconds: 5_000_000)  // 5ms
        }
    }
}
