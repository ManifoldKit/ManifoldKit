import XCTest
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldInference
@testable import ManifoldBackends

/// Tests for `DefaultBackends` static capability queries and the
/// `declareSupport` wiring through `InferenceService`.
///
/// These run in CI without hardware — no backend is instantiated.
@MainActor
final class DefaultBackendsCapabilityTests: XCTestCase {

    // MARK: - Static supportedModelTypes

    func test_supportedModelTypes_isSubsetOfAllModelTypes() {
        // Every value in supportedModelTypes must be a valid ModelType.
        // This catches accidental duplicates or phantom values.
        let supported = DefaultBackends.supportedModelTypes
        let valid: Set<ModelType> = [.gguf, .mlx, .foundation]
        XCTAssertTrue(supported.isSubset(of: valid),
                      "supportedModelTypes contains unexpected values: \(supported.subtracting(valid))")
    }

    func test_canLoad_modelType_matchesSupportedModelTypes() {
        // canLoad(modelType:) must agree with supportedModelTypes.
        for type_ in [ModelType.gguf, .mlx, .foundation] {
            let expected = DefaultBackends.supportedModelTypes.contains(type_)
            XCTAssertEqual(DefaultBackends.canLoad(modelType: type_), expected,
                           "canLoad(modelType: \(type_)) disagrees with supportedModelTypes")
        }
    }

    func test_canLoad_provider_matchesCompiledContract() {
        let compiled = DefaultBackends.compiledBackends
        for provider in APIProvider.allCases {
            let expected = compiled.cloudProviders.contains(provider)
            XCTAssertEqual(
                DefaultBackends.canLoad(provider: provider),
                expected,
                "Expected \(provider) support to match the compiled contract"
            )
        }
    }

    func test_compiledBackends_passthroughsMatchStaticQueries() {
        XCTAssertEqual(DefaultBackends.buildProfile, DefaultBackends.compiledBackends.buildProfile)
        XCTAssertEqual(DefaultBackends.enabledTraits, DefaultBackends.compiledBackends.traits)
        XCTAssertEqual(DefaultBackends.supportedModelTypes, DefaultBackends.compiledBackends.localModelTypes)
    }

    // MARK: - register(with:) populates declareSupport

    func test_register_declaresCloudProvidersOnService() {
        let service = InferenceService()
        DefaultBackends.register(with: service)

        // Cloud providers compiled into this build must be declared after
        // registration. Providers gated out by `Ollama` / `CloudSaaS` traits
        // intentionally stay un-declared.
        for provider in APIProvider.availableInBuild {
            XCTAssertTrue(service.canLoad(provider: provider),
                          "Expected \(provider) to be declared after DefaultBackends.register")
        }
    }

    func test_register_declaresLocalModelTypesConsistentlyWithStaticQuery() {
        let service = InferenceService()
        DefaultBackends.register(with: service)

        // Every model type in the static list must also be declared on the service.
        for type_ in DefaultBackends.supportedModelTypes {
            XCTAssertTrue(service.canLoad(modelType: type_),
                          "ModelType \(type_) is in supportedModelTypes but not declared on service")
        }
    }

    func test_register_doesNotDeclareUnsupportedModelTypes() {
        let service = InferenceService()
        DefaultBackends.register(with: service)

        // Model types not in the static list must not be declared on the service.
        let unsupported = Set<ModelType>([.gguf, .mlx, .foundation])
            .filter { !DefaultBackends.supportedModelTypes.contains($0) }

        for type_ in unsupported {
            XCTAssertFalse(service.canLoad(modelType: type_),
                           "ModelType \(type_) should not be declared but is")
        }
    }

    // MARK: - registeredBackendSnapshot after registration

    func test_register_snapshotContainsAllDeclaredProviders() {
        let service = InferenceService()
        DefaultBackends.register(with: service)
        let snapshot = service.registeredBackendSnapshot()

        for provider in APIProvider.availableInBuild {
            XCTAssertTrue(snapshot.cloudProviders.contains(provider),
                          "\(provider) missing from snapshot after registration")
        }
    }

    func test_register_snapshotLocalTypesMatchStaticQuery() {
        let service = InferenceService()
        DefaultBackends.register(with: service)
        let snapshot = service.registeredBackendSnapshot()

        XCTAssertEqual(snapshot.localModelTypes, DefaultBackends.supportedModelTypes,
                       "Snapshot localModelTypes should equal DefaultBackends.supportedModelTypes")
    }

    // MARK: - FrameworkCapabilityService integration

    func test_frameworkCapabilityService_afterRegisterAndRefresh_matchesStaticQuery() {
        let service = InferenceService()
        DefaultBackends.register(with: service)
        let capService = FrameworkCapabilityService(inferenceService: service)
        capService.refresh()

        XCTAssertEqual(capService.enabledBackends.localModelTypes,
                       DefaultBackends.supportedModelTypes,
                       "FrameworkCapabilityService.enabledBackends should match static query after refresh")

        // Cloud inference support tracks whichever providers the build's
        // traits compiled in. Offline builds (neither `Ollama` nor
        // `CloudSaaS`) declare none, so `supportsCloudInference` is false.
        let expected = !APIProvider.availableInBuild.isEmpty
        XCTAssertEqual(capService.enabledBackends.supportsCloudInference, expected,
                       "Cloud inference support should match the trait-gated provider list")
    }

    // Sabotage check: without register(), cloud providers are absent.
    func test_withoutRegister_cloudProvidersNotDeclared_sabotageCheck() {
        let service = InferenceService()
        // Do NOT call register(with:).
        // Use whichever provider the current build can build, falling back to
        // `.claude` purely so the assertion compiles in offline builds.
        let probe = APIProvider.availableInBuild.first ?? .claude
        XCTAssertFalse(service.canLoad(provider: probe),
                       "Without registration, no provider should be declared")
    }
}
