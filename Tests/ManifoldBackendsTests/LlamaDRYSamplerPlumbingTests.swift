#if Llama
import XCTest
import ManifoldInference
import ManifoldBackends
@_spi(Testing) import ManifoldLlama

final class LlamaDRYSamplerPlumbingTests: XCTestCase {

    func test_descriptorIsNilWhenDRYUnset() {
        let descriptor = LlamaGenerationDriver.DRYSamplerDescriptor(
            config: GenerationConfig(),
            nCtxTrain: 4096
        )

        XCTAssertNil(descriptor)
    }

    func test_descriptorPreservesDRYOptionsAndTrainingContext() throws {
        let options = LlamaDRYSamplerOptions(
            multiplier: 0.8,
            base: 1.9,
            allowedLength: 4,
            penaltyLastN: 512,
            sequenceBreakers: ["\n", "</s>"]
        )
        let descriptor = try XCTUnwrap(LlamaGenerationDriver.DRYSamplerDescriptor(
            config: GenerationConfig(llamaDRY: options),
            nCtxTrain: 8192
        ))

        XCTAssertEqual(descriptor.nCtxTrain, 8192)
        XCTAssertEqual(descriptor.options, options)
    }

    func test_capabilitiesAdvertiseDRYSampler() {
        let backend = LlamaBackend()

        XCTAssertTrue(backend.capabilities.supportedParameters.contains(.llamaDRY))
    }
}
#endif

