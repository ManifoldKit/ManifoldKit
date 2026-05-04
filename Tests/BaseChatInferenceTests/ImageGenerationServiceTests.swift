import XCTest
import Foundation
@testable import BaseChatInference

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
    private final class MockBackend: ImageGenerationBackend, @unchecked Sendable {
        var isLoaded: Bool = false
        var isGenerating: Bool = false

        // Counters / event scripts. Mutated only on the main actor since the
        // service is `@MainActor` and tests await all transitions.
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
}
