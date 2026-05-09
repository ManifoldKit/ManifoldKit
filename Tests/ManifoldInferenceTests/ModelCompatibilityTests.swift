import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

// MARK: - ModelCompatibilityResult Tests

final class ModelCompatibilityResultTests: XCTestCase {

    func test_supported_isSupported_returnsTrue() {
        let result = ModelCompatibilityResult.supported
        XCTAssertTrue(result.isSupported)
    }

    func test_unsupported_isSupported_returnsFalse() {
        let result = ModelCompatibilityResult.unsupported(reason: "No backend")
        XCTAssertFalse(result.isSupported)
    }

    func test_supported_unavailableReason_returnsNil() {
        let result = ModelCompatibilityResult.supported
        XCTAssertNil(result.unavailableReason)
    }

    func test_unsupported_unavailableReason_returnsReason() {
        let result = ModelCompatibilityResult.unsupported(reason: "Requires llama.cpp")
        XCTAssertEqual(result.unavailableReason, "Requires llama.cpp")
    }

    func test_supported_equatability() {
        XCTAssertEqual(ModelCompatibilityResult.supported, .supported)
    }

    func test_unsupported_equatability_sameReason() {
        let a = ModelCompatibilityResult.unsupported(reason: "foo")
        let b = ModelCompatibilityResult.unsupported(reason: "foo")
        XCTAssertEqual(a, b)
    }

    func test_unsupported_equatability_differentReason() {
        let a = ModelCompatibilityResult.unsupported(reason: "foo")
        let b = ModelCompatibilityResult.unsupported(reason: "bar")
        XCTAssertNotEqual(a, b)
    }

    func test_supported_notEqualToUnsupported() {
        let a = ModelCompatibilityResult.supported
        let b = ModelCompatibilityResult.unsupported(reason: "foo")
        XCTAssertNotEqual(a, b)
    }

    // Sabotage check: if we swap the isSupported logic, this test fails.
    // (Remove the sabotage comment before committing — it's the logic verification.)
    func test_supported_isSupported_sabotageVerification() {
        let supported = ModelCompatibilityResult.supported
        let unsupported = ModelCompatibilityResult.unsupported(reason: "x")
        // If both returned the same value, these assertions would conflict.
        XCTAssertTrue(supported.isSupported)
        XCTAssertFalse(unsupported.isSupported)
    }
}

// MARK: - InferenceService Compatibility Tests

@MainActor
final class InferenceServiceCompatibilityTests: XCTestCase {

    // MARK: - No factories registered (empty service)

    func test_emptyService_modelType_returnsUnsupported() {
        let service = InferenceService()
        let result = service.compatibility(for: .gguf)
        XCTAssertFalse(result.isSupported)
    }

    func test_emptyService_provider_returnsUnsupported() {
        let service = InferenceService()
        let result = service.compatibility(for: .claude)
        XCTAssertFalse(result.isSupported)
    }

    func test_emptyService_canLoad_modelType_returnsFalse() {
        let service = InferenceService()
        XCTAssertFalse(service.canLoad(modelType: .gguf))
        XCTAssertFalse(service.canLoad(modelType: .mlx))
        XCTAssertFalse(service.canLoad(modelType: .foundation))
    }

    func test_emptyService_canLoad_provider_returnsFalse() {
        let service = InferenceService()
        XCTAssertFalse(service.canLoad(provider: .openAI))
        XCTAssertFalse(service.canLoad(provider: .claude))
    }

    func test_emptyService_unavailableReason_modelType_isNonNil() {
        let service = InferenceService()
        XCTAssertNotNil(service.unavailableReason(for: .gguf))
        XCTAssertNotNil(service.unavailableReason(for: .mlx))
        XCTAssertNotNil(service.unavailableReason(for: .foundation))
    }

    func test_emptyService_unavailableReason_provider_isNonNil() {
        let service = InferenceService()
        XCTAssertNotNil(service.unavailableReason(for: .claude))
    }

    // MARK: - After declaring support

    func test_afterDeclareSupport_modelType_returnsSupported() {
        let service = InferenceService()
        service.declareSupport(for: .gguf)
        XCTAssertTrue(service.canLoad(modelType: .gguf))
        XCTAssertEqual(service.compatibility(for: .gguf), .supported)
    }

    func test_afterDeclareSupport_otherModelType_remainsUnsupported() {
        let service = InferenceService()
        service.declareSupport(for: .gguf)
        // Only GGUF was declared; MLX should still be unsupported.
        XCTAssertFalse(service.canLoad(modelType: .mlx))
    }

    func test_afterDeclareSupport_provider_returnsSupported() {
        let service = InferenceService()
        service.declareSupport(for: .openAI)
        XCTAssertTrue(service.canLoad(provider: .openAI))
        XCTAssertEqual(service.compatibility(for: .openAI), .supported)
    }

    func test_afterDeclareSupport_unavailableReason_returnsNil() {
        let service = InferenceService()
        service.declareSupport(for: .mlx)
        XCTAssertNil(service.unavailableReason(for: .mlx))
    }

    func test_declareSupport_multipleTimes_doesNotBreak() {
        let service = InferenceService()
        service.declareSupport(for: .gguf)
        service.declareSupport(for: .gguf)
        XCTAssertTrue(service.canLoad(modelType: .gguf))
    }

    func test_declareSupport_allModelTypes_allReturnSupported() {
        let service = InferenceService()
        for type_ in [ModelType.gguf, .mlx, .foundation] {
            service.declareSupport(for: type_)
        }
        XCTAssertTrue(service.canLoad(modelType: .gguf))
        XCTAssertTrue(service.canLoad(modelType: .mlx))
        XCTAssertTrue(service.canLoad(modelType: .foundation))
    }

    func test_declareSupport_allProviders_allReturnSupported() {
        let service = InferenceService()
        for provider in APIProvider.allCases {
            service.declareSupport(for: provider)
        }
        for provider in APIProvider.allCases {
            XCTAssertTrue(service.canLoad(provider: provider), "\(provider) should be supported")
        }
    }

    // MARK: - registeredBackendSnapshot

    func test_registeredBackendSnapshot_empty_returnsEmptySets() {
        let service = InferenceService()
        let snapshot = service.registeredBackendSnapshot()
        XCTAssertTrue(snapshot.localModelTypes.isEmpty)
        XCTAssertTrue(snapshot.cloudProviders.isEmpty)
    }

    func test_registeredBackendSnapshot_afterDeclarations_containsDeclaredTypes() {
        let service = InferenceService()
        service.declareSupport(for: .gguf)
        service.declareSupport(for: .openAI)

        let snapshot = service.registeredBackendSnapshot()
        XCTAssertTrue(snapshot.localModelTypes.contains(.gguf))
        XCTAssertFalse(snapshot.localModelTypes.contains(.mlx))
        XCTAssertTrue(snapshot.cloudProviders.contains(.openAI))
        XCTAssertFalse(snapshot.cloudProviders.contains(.claude))
    }

    // MARK: - Unsupported reason strings contain useful info

    func test_unavailableReason_gguf_mentionsLlama() {
        let service = InferenceService()
        let reason = service.unavailableReason(for: .gguf)!
        XCTAssertTrue(reason.lowercased().contains("llama"),
                      "GGUF unavailable reason should mention llama.cpp. Got: \(reason)")
    }

    func test_unavailableReason_mlx_mentionsMLX() {
        let service = InferenceService()
        let reason = service.unavailableReason(for: .mlx)!
        XCTAssertTrue(reason.lowercased().contains("mlx"),
                      "MLX unavailable reason should mention MLX. Got: \(reason)")
    }

    func test_unavailableReason_foundation_mentionsiOS26() {
        let service = InferenceService()
        let reason = service.unavailableReason(for: .foundation)!
        XCTAssertTrue(reason.contains("26"),
                      "Foundation unavailable reason should mention iOS/macOS 26. Got: \(reason)")
    }
}

// MARK: - EnabledBackends Tests

final class EnabledBackendsTests: XCTestCase {

    func test_empty_supportsNothing() {
        let backends = EnabledBackends()
        XCTAssertFalse(backends.supportsGGUF)
        XCTAssertFalse(backends.supportsMLX)
        XCTAssertFalse(backends.supportsFoundation)
        XCTAssertFalse(backends.supportsLocalInference)
        XCTAssertFalse(backends.supportsCloudInference)
    }

    func test_withGGUF_supportsGGUFAndLocal() {
        let backends = EnabledBackends(localModelTypes: [.gguf])
        XCTAssertTrue(backends.supportsGGUF)
        XCTAssertFalse(backends.supportsMLX)
        XCTAssertTrue(backends.supportsLocalInference)
        XCTAssertFalse(backends.supportsCloudInference)
    }

    func test_withMLX_supportsMLXAndLocal() {
        let backends = EnabledBackends(localModelTypes: [.mlx])
        XCTAssertFalse(backends.supportsGGUF)
        XCTAssertTrue(backends.supportsMLX)
        XCTAssertTrue(backends.supportsLocalInference)
    }

    func test_withFoundation_supportsFoundation() {
        let backends = EnabledBackends(localModelTypes: [.foundation])
        XCTAssertTrue(backends.supportsFoundation)
        XCTAssertTrue(backends.supportsLocalInference)
    }

    func test_withCloudProvider_supportsCloudInference() {
        let backends = EnabledBackends(cloudProviders: [.openAI])
        XCTAssertFalse(backends.supportsLocalInference)
        XCTAssertTrue(backends.supportsCloudInference)
    }

    func test_fullBuild_supportsEverything() {
        let backends = EnabledBackends(
            localModelTypes: [.gguf, .mlx, .foundation],
            cloudProviders: Set(APIProvider.allCases)
        )
        XCTAssertTrue(backends.supportsGGUF)
        XCTAssertTrue(backends.supportsMLX)
        XCTAssertTrue(backends.supportsFoundation)
        XCTAssertTrue(backends.supportsLocalInference)
        XCTAssertTrue(backends.supportsCloudInference)
    }

    func test_equality_emptyInstances() {
        XCTAssertEqual(EnabledBackends(), EnabledBackends())
    }

    func test_equality_sameContent() {
        let a = EnabledBackends(localModelTypes: [.gguf], cloudProviders: [.claude])
        let b = EnabledBackends(localModelTypes: [.gguf], cloudProviders: [.claude])
        XCTAssertEqual(a, b)
    }

    func test_inequality_differentContent() {
        let a = EnabledBackends(localModelTypes: [.gguf])
        let b = EnabledBackends(localModelTypes: [.mlx])
        XCTAssertNotEqual(a, b)
    }

    // Sabotage check: supportsLocalInference should be false when set is empty.
    func test_supportsLocalInference_sabotageCheck() {
        let empty = EnabledBackends(localModelTypes: [])
        let withLocal = EnabledBackends(localModelTypes: [.gguf])
        XCTAssertFalse(empty.supportsLocalInference)
        XCTAssertTrue(withLocal.supportsLocalInference)
    }
}

// MARK: - FrameworkCapabilityService Tests

@MainActor
final class FrameworkCapabilityServiceTests: XCTestCase {

    // MARK: - Initial state

    func test_initialState_enabledBackends_isEmpty() {
        let service = InferenceService()
        let capService = FrameworkCapabilityService(inferenceService: service)
        XCTAssertFalse(capService.enabledBackends.supportsLocalInference)
        XCTAssertFalse(capService.enabledBackends.supportsCloudInference)
    }

    // MARK: - refresh() picks up newly declared backends

    func test_refresh_afterDeclareSupportGGUF_enabledBackendsReflectsIt() {
        let service = InferenceService()
        let capService = FrameworkCapabilityService(inferenceService: service)

        service.declareSupport(for: .gguf)
        capService.refresh()

        XCTAssertTrue(capService.enabledBackends.supportsGGUF)
        XCTAssertFalse(capService.enabledBackends.supportsMLX)
    }

    func test_refresh_noDeclarations_enabledBackendsEmpty() {
        let service = InferenceService()
        let capService = FrameworkCapabilityService(inferenceService: service)
        capService.refresh()
        XCTAssertFalse(capService.enabledBackends.supportsLocalInference)
    }

    func test_refresh_withAllProviders_cloudSupportTrue() {
        let service = InferenceService()
        let capService = FrameworkCapabilityService(inferenceService: service)
        for provider in APIProvider.allCases {
            service.declareSupport(for: provider)
        }
        capService.refresh()
        XCTAssertTrue(capService.enabledBackends.supportsCloudInference)
    }

    // MARK: - Compatibility delegation

    func test_compatibility_delegatesToInferenceService() {
        let service = InferenceService()
        let capService = FrameworkCapabilityService(inferenceService: service)

        service.declareSupport(for: .mlx)
        XCTAssertEqual(capService.compatibility(for: .mlx), .supported)
        XCTAssertFalse(capService.compatibility(for: .gguf).isSupported)
    }

    func test_canLoad_modelType_delegatesToInferenceService() {
        let service = InferenceService()
        let capService = FrameworkCapabilityService(inferenceService: service)
        service.declareSupport(for: .gguf)

        XCTAssertTrue(capService.canLoad(modelType: .gguf))
        XCTAssertFalse(capService.canLoad(modelType: .mlx))
    }

    func test_canLoad_provider_delegatesToInferenceService() {
        let service = InferenceService()
        let capService = FrameworkCapabilityService(inferenceService: service)
        service.declareSupport(for: .claude)

        XCTAssertTrue(capService.canLoad(provider: .claude))
        XCTAssertFalse(capService.canLoad(provider: .openAI))
    }

    func test_unavailableReason_supported_returnsNil() {
        let service = InferenceService()
        let capService = FrameworkCapabilityService(inferenceService: service)
        service.declareSupport(for: .gguf)

        XCTAssertNil(capService.unavailableReason(for: .gguf))
    }

    func test_unavailableReason_unsupported_returnsNonNil() {
        let service = InferenceService()
        let capService = FrameworkCapabilityService(inferenceService: service)

        XCTAssertNotNil(capService.unavailableReason(for: .gguf))
    }

    // Sabotage check: refresh() must actually update enabledBackends.
    func test_refresh_calledTwice_isIdempotent() {
        let service = InferenceService()
        let capService = FrameworkCapabilityService(inferenceService: service)
        service.declareSupport(for: .gguf)
        capService.refresh()
        capService.refresh()
        XCTAssertTrue(capService.enabledBackends.supportsGGUF,
                      "enabledBackends should still reflect GGUF support after double refresh")
    }
}
