#if Llama
import XCTest
@testable import BaseChatInference
@testable import BaseChatBackends

final class LlamaMirostatV2SamplerPlumbingTests: XCTestCase {

    func test_descriptorIsNilWhenMirostatUnset() {
        let descriptor = LlamaGenerationDriver.MirostatV2SamplerDescriptor(
            config: GenerationConfig(),
            fallbackSeed: 42
        )

        XCTAssertNil(descriptor)
    }

    func test_descriptorPreservesMirostatOptions() throws {
        let options = LlamaMirostatV2SamplerOptions(
            tau: 7.5,
            eta: 0.25,
            seed: 4_242
        )
        let descriptor = try XCTUnwrap(LlamaGenerationDriver.MirostatV2SamplerDescriptor(
            config: GenerationConfig(llamaMirostatV2: options),
            fallbackSeed: 42
        ))

        XCTAssertEqual(descriptor.options, options)
        XCTAssertEqual(descriptor.resolvedSeed, 4_242)
    }

    func test_descriptorFallsBackToProvidedSeedWhenOptionsSeedIsNil() throws {
        let options = LlamaMirostatV2SamplerOptions()
        let descriptor = try XCTUnwrap(LlamaGenerationDriver.MirostatV2SamplerDescriptor(
            config: GenerationConfig(llamaMirostatV2: options),
            fallbackSeed: 9_999
        ))

        XCTAssertEqual(descriptor.resolvedSeed, 9_999)
    }

    func test_capabilitiesAdvertiseMirostatV2Sampler() {
        let backend = LlamaBackend()

        XCTAssertTrue(backend.capabilities.supportedParameters.contains(.llamaMirostatV2))
    }
}
#endif
