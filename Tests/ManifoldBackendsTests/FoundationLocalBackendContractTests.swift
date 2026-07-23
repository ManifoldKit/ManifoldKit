#if canImport(FoundationModels)
import XCTest
import ManifoldInference
import ManifoldTestSupport
import ManifoldBackendTestKit
import ManifoldFoundation

/// Foundation participant for the local-backend contract suite.
///
/// Stays in core (ManifoldFoundation does not move to a companion package).
/// Scenario implementations live in
/// ``ManifoldBackendTestKit/LocalBackendContractRunner``.
///
/// Gated by `#if canImport(FoundationModels)` (always true on macOS 26+
/// / iOS 26+ where the framework ships) and `#available(macOS 26, iOS 26, *)`
/// in each test. The `makeBackend` factory creates a `FoundationBackend` in
/// its initial unconfigured state — no session created. This is intentional:
/// the pre-load invariants and the `capabilities` snapshot do not require a
/// live session.
///
/// Scenarios that call `generate()` are gated behind `RUN_SLOW_TESTS=1` and
/// an `#available` check, so they only run on nightly infrastructure where
/// macOS 26 / iOS 26 and Apple Intelligence are present.
final class FoundationLocalBackendContractTests: XCTestCase {

    @available(macOS 26, iOS 26, *)
    private static var participant: LocalBackendContractParticipant {
        LocalBackendContractParticipant(
            label: "foundation.backend",
            fixtureDirectory: "foundation",
            capabilities: BackendCapabilities(
                supportedParameters: [.temperature],
                maxContextTokens: 4096,
                requiresPromptTemplate: false,
                supportsSystemPrompt: true,
                supportsToolCalling: true,
                supportsStructuredOutput: false,
                supportsNativeJSONMode: false,
                cancellationStyle: .cooperative,
                supportsTokenCounting: false,
                memoryStrategy: .external,
                maxOutputTokens: 4096,
                supportsStreaming: true,
                isRemote: false,
                supportsVision: false,
                streamsToolCallArguments: false,
                // Declared true (#2354): `.guided` is wired end-to-end via
                // native GuidedGeneration. Must match the backend's real
                // capability literal.
                supportsGuidedStructuredOutput: true
            ),
            requiresSlowTests: true,
            makeBackend: {
                // No session created — factory returns the backend in its zero
                // state. Generation scenarios gate themselves behind
                // RUN_SLOW_TESTS=1 via the runner's hardware gate.
                FoundationBackend()
            }
        )
    }

    func test_generate_simplePrompt_emitsTokensInOrder() async throws {
        guard #available(macOS 26, iOS 26, *) else {
            throw XCTSkip("FoundationModels requires macOS 26 / iOS 26")
        }
        try await LocalBackendContractRunner.assertSimplePromptEmitsTokensInOrder(
            participant: Self.participant,
            fixturesRoot: LocalBackendContractRunner.locateFixturesRoot()
        )
    }

    func test_generate_stopsGenerating_afterStreamEnd() async throws {
        guard #available(macOS 26, iOS 26, *) else {
            throw XCTSkip("FoundationModels requires macOS 26 / iOS 26")
        }
        try await LocalBackendContractRunner.assertStopsGeneratingAfterStreamEnd(
            participant: Self.participant
        )
    }

    func test_capabilityGate_disclaimedRequirementThrows() async throws {
        guard #available(macOS 26, iOS 26, *) else {
            throw XCTSkip("FoundationModels requires macOS 26 / iOS 26")
        }
        await LocalBackendContractRunner.assertCapabilityGateDisclaimedRequirementThrows(
            participant: Self.participant
        )
    }
}
#endif
