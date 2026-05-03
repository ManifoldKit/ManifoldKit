import XCTest
import Foundation
import CoreFoundation
@testable import BaseChatInference

/// Foundational tests for the image-generation surface introduced alongside
/// ``ImageGenerationBackend``. Covers value-type Codable behaviour for the
/// runtime config, runtime↔snapshot conversion identity, and a tiny mock
/// conformer that proves ``ImageGenerationBackend`` compiles as
/// `AnyObject + Sendable`.
///
/// No backend implementation lives in BCK; these tests exist to lock the
/// shapes in place so downstream consumers can rely on them.
final class ImageGenerationFoundationsTests: XCTestCase {

    // MARK: - ImageGenerationConfig Codable round-trip

    func test_imageGenerationConfig_codableRoundtrip() throws {
        let config = ImageGenerationConfig(
            steps: 30,
            width: 1024,
            height: 1024,
            seed: 1234,
            guidanceScale: 7.5
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ImageGenerationConfig.self, from: data)

        XCTAssertEqual(decoded.steps, config.steps)
        XCTAssertEqual(decoded.width, config.width)
        XCTAssertEqual(decoded.height, config.height)
        XCTAssertEqual(decoded.seed, config.seed)
        XCTAssertEqual(decoded.guidanceScale, config.guidanceScale)
        XCTAssertEqual(decoded.resolution.width, 1024)
        XCTAssertEqual(decoded.resolution.height, 1024)
    }

    func test_imageGenerationConfig_codableRoundtrip_nilOptionals() throws {
        // seed and guidanceScale are optional; their absence must round-trip
        // as `nil` rather than smuggling backend-specific defaults onto the
        // wire.
        let config = ImageGenerationConfig(steps: 4, width: 512, height: 512)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ImageGenerationConfig.self, from: data)

        XCTAssertNil(decoded.seed)
        XCTAssertNil(decoded.guidanceScale)
        XCTAssertEqual(decoded.steps, 4)
    }

    func test_imageGenerationConfig_cgSizeInit() {
        let config = ImageGenerationConfig(
            steps: 8,
            resolution: CGSize(width: 768, height: 1024),
            seed: 7,
            guidanceScale: nil
        )
        XCTAssertEqual(config.width, 768)
        XCTAssertEqual(config.height, 1024)
    }

    // MARK: - Snapshot ↔ runtime conversion identity

    func test_imageGenerationConfigSnapshot_roundtripsViaConfig() {
        let original = ImageGenerationConfigSnapshot(
            steps: 12,
            width: 640,
            height: 384,
            seed: 9999,
            guidanceScale: 4.5
        )

        let viaConfig = ImageGenerationConfigSnapshot(from: original.toConfig())

        XCTAssertEqual(viaConfig, original,
            "snapshot → config → snapshot must be identity")
    }

    func test_imageGenerationConfigSnapshot_codableRoundtrip() throws {
        let snapshot = ImageGenerationConfigSnapshot(
            steps: 20,
            width: 1024,
            height: 1024,
            seed: 1,
            guidanceScale: 6.0
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ImageGenerationConfigSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot,
            "snapshot must round-trip through Codable intact")
    }

    func test_imageGenerationConfig_initFromConfig_capturesAllFields() {
        let config = ImageGenerationConfig(
            steps: 50,
            width: 2048,
            height: 2048,
            seed: 42,
            guidanceScale: 8.0
        )

        let snapshot = ImageGenerationConfigSnapshot(from: config)

        XCTAssertEqual(snapshot.steps, 50)
        XCTAssertEqual(snapshot.width, 2048)
        XCTAssertEqual(snapshot.height, 2048)
        XCTAssertEqual(snapshot.seed, 42)
        XCTAssertEqual(snapshot.guidanceScale, 8.0)
    }

    // MARK: - ImageGenerationBackend protocol existence

    /// A trivial conformer used only to prove the protocol shape compiles.
    /// No real generation happens; the test asserts the conformer exists,
    /// is `AnyObject`-bound (reference type), and is `Sendable`.
    private final class StubImageGenerationBackend: ImageGenerationBackend, @unchecked Sendable {
        var isLoaded: Bool = false
        var isGenerating: Bool = false

        func loadModel(from url: URL) async throws { isLoaded = true }

        func generate(
            prompt: String,
            config: ImageGenerationConfig
        ) throws -> AsyncThrowingStream<ImageGenerationEvent, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.progress(step: 1, total: config.steps))
                continuation.yield(.completed(URL(fileURLWithPath: "/tmp/stub.png")))
                continuation.finish()
            }
        }

        func stopGeneration() { isGenerating = false }
        func unloadModel() { isLoaded = false }
    }

    func test_imageGenerationBackend_referenceTypeAndSendable() {
        let backend: any ImageGenerationBackend = StubImageGenerationBackend()
        XCTAssertFalse(backend.isLoaded, "freshly constructed stub must report isLoaded == false")
        XCTAssertFalse(backend.isGenerating, "freshly constructed stub must report isGenerating == false")

        // Sendable check: this closure captures `backend` and dispatches
        // it to a detached task. If `ImageGenerationBackend` ever lost
        // `Sendable`, this would be a compile error.
        let sendableProbe: @Sendable () -> Bool = { backend.isLoaded }
        XCTAssertFalse(sendableProbe())
    }

    func test_imageGenerationBackend_streamsProgressAndCompletion() async throws {
        let backend = StubImageGenerationBackend()
        try await backend.loadModel(from: URL(fileURLWithPath: "/tmp/stub-model"))

        let stream = try backend.generate(
            prompt: "hello",
            config: ImageGenerationConfig(steps: 4, width: 64, height: 64)
        )

        var events: [ImageGenerationEvent] = []
        for try await event in stream {
            events.append(event)
        }

        XCTAssertEqual(events.count, 2)

        guard case .progress(let step, let total) = events[0] else {
            return XCTFail("first event should be .progress")
        }
        XCTAssertEqual(step, 1)
        XCTAssertEqual(total, 4)

        guard case .completed(let url) = events[1] else {
            return XCTFail("second event should be .completed")
        }
        XCTAssertEqual(url.path, "/tmp/stub.png")
    }
}
