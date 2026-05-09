#if Llama
import XCTest
@testable import ManifoldInference
@testable import ManifoldBackends
@testable import ManifoldLlama

final class LlamaXTCSamplerPlumbingTests: XCTestCase {

    func test_descriptorIsNilWhenXTCUnset() {
        let descriptor = LlamaGenerationDriver.XTCSamplerDescriptor(
            config: GenerationConfig(),
            fallbackSeed: 42
        )

        XCTAssertNil(descriptor)
    }

    func test_descriptorPreservesXTCOptions() throws {
        let options = LlamaXTCSamplerOptions(
            probability: 0.5,
            threshold: 0.20,
            minKeep: 3,
            seed: 9_001
        )
        let descriptor = try XCTUnwrap(LlamaGenerationDriver.XTCSamplerDescriptor(
            config: GenerationConfig(llamaXTC: options),
            fallbackSeed: 42
        ))

        XCTAssertEqual(descriptor.options, options)
        XCTAssertEqual(descriptor.resolvedSeed, 9_001)
    }

    func test_descriptorFallsBackToProvidedSeedWhenOptionsSeedIsNil() throws {
        let options = LlamaXTCSamplerOptions(probability: 0.5)
        let descriptor = try XCTUnwrap(LlamaGenerationDriver.XTCSamplerDescriptor(
            config: GenerationConfig(llamaXTC: options),
            fallbackSeed: 1_337
        ))

        XCTAssertEqual(descriptor.resolvedSeed, 1_337)
    }

    func test_capabilitiesAdvertiseXTCSampler() {
        let backend = LlamaBackend()

        XCTAssertTrue(backend.capabilities.supportedParameters.contains(.llamaXTC))
    }
}
#endif
