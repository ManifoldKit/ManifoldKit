#if canImport(FoundationModels)
import XCTest
import ManifoldTestSupport
@testable import ManifoldInference
@testable import ManifoldFoundation

/// True end-to-end behavioral proof for ManifoldKit#2354: `.guided` structured
/// output against a REAL, live Apple Intelligence session — not
/// `BackendContractChecks.claimWithoutBehaviouralAssertion`. This is the test
/// `FoundationBackendContractTests` (universal contract, no hardware) points
/// to as the actual proof behind `supportsGuidedStructuredOutput: true`,
/// mirroring how `supportsToolCalling`'s real proof lives in the E2E tier
/// rather than the always-run contract suite.
///
/// Automatically skipped where Foundation Models are unavailable (requires
/// macOS 26+ / iOS 26+ with Apple Intelligence enabled and downloaded).
@available(macOS 26, iOS 26, *)
@MainActor
final class FoundationGuidedStructuredOutputE2ETests: XCTestCase {

    /// Minimal concrete target type. `SchemaProviding` is exactly what
    /// `respond<T>()`'s generic constraint requires — no macro, no special
    /// Foundation-specific conformance.
    private struct Weather: Decodable, Sendable, SchemaProviding, Equatable {
        let city: String
        let conditions: String

        static var jsonSchema: JSONSchemaValue {
            .object([
                "type": .string("object"),
                "properties": .object([
                    "city": .object(["type": .string("string")]),
                    "conditions": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("city"), .string("conditions")]),
            ])
        }
    }

    private var service: InferenceService!

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(HardwareRequirements.hasFoundationModels, "Requires macOS 26+ / iOS 26+")
        try XCTSkipUnless(FoundationBackend.isAvailable, "Apple Intelligence not available on this device")
        let ready = await FoundationBackend.probeIsReady()
        try XCTSkipUnless(ready, "Apple Intelligence not ready — ensure it is enabled and downloaded in System Settings > Apple Intelligence & Siri")

        let inferenceService = InferenceService()
        inferenceService.registerBackendFactory { modelType in
            switch modelType {
            case .foundation: return FoundationBackend()
            default: return nil
            }
        }
        try await inferenceService.loadModel(from: .builtInFoundation, plan: .systemManaged(requestedContextSize: 4096))
        service = inferenceService
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    /// The core behavioral proof: a real guided round-trip decodes into the
    /// concrete target type, AND the router actually selected `.guided` for
    /// this request — not a silent fallback to `.jsonPrompting`, which would
    /// pass a naive "did it decode" check while the capability claim stayed
    /// just as inert as before #2354.
    func test_respond_guidedRoundTrip_decodesIntoConcreteType_viaGuidedStrategy() async throws {
        let result = try await service.respond(
            Weather.self,
            to: "The weather in Paris is sunny today. Extract the city and conditions."
        )

        XCTAssertEqual(result.value.city, "Paris")
        XCTAssertFalse(result.value.conditions.isEmpty)
        XCTAssertEqual(
            result.strategy, .guided(Weather.self),
            "FoundationBackend advertises supportsGuidedStructuredOutput: true — the router must actually select .guided, not silently degrade"
        )
    }
}
#endif
