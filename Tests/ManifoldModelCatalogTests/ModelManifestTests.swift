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
            .logitBias, .stopSequences, .repeatPenalty,
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SamplingParameterSet.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - ModelManifest.unknown

    func test_unknownManifest_isConservative() {
        let manifest = ModelManifest.unknown(modelIdentifier: "mystery-model")

        XCTAssertEqual(manifest.contextWindow, 8192,
                       "Unknown manifests should default to 8k context — modern minimum, safer than over-trimming")
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
