import XCTest
@testable import ManifoldModelCatalog

final class ModelManifestTests: XCTestCase {

    // MARK: - SamplingParameterSet

    func test_samplingParameterSet_optionSetSemantics() {
        let combined: SamplingParameterSet = [.temperature, .topP]
        XCTAssertTrue(combined.contains(.temperature))
        XCTAssertTrue(combined.contains(.topP))
        XCTAssertFalse(combined.contains(.topK))

        let single: SamplingParameterSet = [.presencePenalty]
        XCTAssertTrue(single.contains(.presencePenalty))
        XCTAssertFalse(single.contains(.frequencyPenalty))
    }

    func test_samplingParameterSet_codableRoundTrip() throws {
        let original: SamplingParameterSet = [
            .temperature, .topP, .topK,
            .presencePenalty, .frequencyPenalty,
            .stopSequences, .repeatPenalty,
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SamplingParameterSet.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - ModelManifest.unknown

    func test_unknownManifest_isConservative() {
        let manifest = ModelManifest.unknown(modelIdentifier: "mystery-model")

        XCTAssertNil(manifest.contextWindow,
                     "An unknown manifest must report absence, not a plausible number — a fabricated window is indistinguishable from a measured one, so every consumer trims against a fiction")
        XCTAssertFalse(manifest.supportsTools)
        XCTAssertFalse(manifest.supportsThinking)
        XCTAssertNil(manifest.thinkingMarkers)
        XCTAssertFalse(manifest.supportsSeed)
        XCTAssertEqual(manifest.supportedSamplingParameters, [.temperature, .topP],
                       "Unknown manifests should only advertise the universal sampling pair")
        XCTAssertEqual(manifest.modelIdentifier, "mystery-model")
        XCTAssertEqual(manifest.producerKind, .local)
    }

    func test_unknownManifest_carriesProducerKind() {
        let cloud = ModelManifest.unknown(modelIdentifier: "x", producerKind: .cloud)
        XCTAssertEqual(cloud.producerKind, .cloud)

        let lan = ModelManifest.unknown(modelIdentifier: "y", producerKind: .lan)
        XCTAssertEqual(lan.producerKind, .lan)
    }

    /// The defect this optionality exists to make impossible: while `unknown()`
    /// fabricated `8192`, a model that genuinely has an 8k window was byte-for-byte
    /// indistinguishable from one the backend could not introspect. Every
    /// "is this known?" check therefore had to compare against the literal —
    /// which is exactly what `ClaudeBackend` did across a module boundary.
    func test_genuine8kWindow_isDistinguishableFromUnknown() {
        let genuinely8k = ModelManifest(
            contextWindow: 8192,
            supportsTools: true,
            supportsThinking: false,
            thinkingMarkers: nil,
            supportsSeed: true,
            supportedSamplingParameters: [.temperature, .topP],
            modelIdentifier: "gpt-4",
            producerKind: .cloud
        )
        let unknown = ModelManifest.unknown(modelIdentifier: "gpt-4", producerKind: .cloud)

        XCTAssertEqual(genuinely8k.contextWindow, 8192)
        XCTAssertNil(unknown.contextWindow)
        XCTAssertNotEqual(genuinely8k.contextWindow, unknown.contextWindow,
                          "A measured 8k window and an un-introspected model must not collapse to the same value — that collision is the whole bug")
    }

    /// `nil` must survive encode/decode. If it round-tripped back as a number,
    /// any consumer reading a persisted manifest would resurrect the sentinel.
    func test_modelManifest_codableRoundTrip_unknownContextWindow() throws {
        let original = ModelManifest.unknown(modelIdentifier: "mystery", producerKind: .cloud)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ModelManifest.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.contextWindow,
                     "An unknown context window must stay unknown across a Codable round trip")
    }

    // MARK: - Codable

    func test_modelManifest_codableRoundTrip() throws {
        let original = ModelManifest(
            contextWindow: 32_768,
            supportsTools: true,
            supportsThinking: true,
            thinkingMarkers: .qwen3,
            supportsSeed: true,
            supportedSamplingParameters: [.temperature, .topP, .topK],
            modelIdentifier: "qwen3-7b",
            producerKind: .local
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ModelManifest.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.thinkingMarkers, .qwen3)
        XCTAssertEqual(decoded.contextWindow, 32_768)
    }

    func test_modelManifest_codableRoundTrip_nilMarkers() throws {
        let original = ModelManifest(
            contextWindow: 200_000,
            supportsTools: true,
            supportsThinking: false,
            thinkingMarkers: nil,
            supportsSeed: true,
            supportedSamplingParameters: [.temperature, .topP],
            modelIdentifier: "gpt-4o",
            producerKind: .cloud
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ModelManifest.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.thinkingMarkers)
    }
}
