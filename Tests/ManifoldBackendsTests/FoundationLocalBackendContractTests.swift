#if canImport(FoundationModels)
import Foundation
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
/// in each test. The participant factory remains unloaded for the fast
/// capability-gate assertion. Slow generation tests explicitly call
/// `loadModel`, while `FoundationBackendUnitTests.test_generate_beforeLoad_throwsNoModelLoaded`
/// separately pins the unloaded error contract.
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
                // The fast capability-gate check must not require Apple
                // Intelligence. Generation tests use withLoadedBackend below.
                FoundationBackend()
            }
        )
    }

    @available(macOS 26, iOS 26, *)
    private func withLoadedBackend(
        _ body: (FoundationBackend) async throws -> Void
    ) async throws {
        try LocalBackendContractRunner.skipIfHardwareGated(Self.participant)
        try XCTSkipUnless(
            FoundationBackend.isAvailable,
            "Apple Intelligence not available on this device"
        )

        let backend = FoundationBackend()
        try await backend.loadModel(
            from: URL(fileURLWithPath: "/dev/null"),
            plan: .systemManaged(requestedContextSize: 4096)
        )
        XCTAssertTrue(
            backend.isModelLoaded,
            "Generation contract fixture must return a loaded backend"
        )

        do {
            try await body(backend)
        } catch {
            await backend.unloadModelAndWait()
            throw error
        }
        await backend.unloadModelAndWait()
    }

    func test_generate_simplePrompt_emitsTokensInOrder() async throws {
        guard #available(macOS 26, iOS 26, *) else {
            throw XCTSkip("FoundationModels requires macOS 26 / iOS 26")
        }
        try await withLoadedBackend { backend in
            let stream = try backend.generate(
                prompt: "Hello",
                systemPrompt: nil,
                config: GenerationConfig()
            )
            var visibleText = ""
            for try await event in stream.events {
                if case .token(let text) = event {
                    visibleText += text
                }
            }
            XCTAssertFalse(
                visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Foundation model must emit non-empty visible text for a simple prompt"
            )
        }
    }

    func test_generate_stopsGenerating_afterStreamEnd() async throws {
        guard #available(macOS 26, iOS 26, *) else {
            throw XCTSkip("FoundationModels requires macOS 26 / iOS 26")
        }
        try await withLoadedBackend { backend in
            let stream = try backend.generate(
                prompt: "ping",
                systemPrompt: nil,
                config: GenerationConfig()
            )
            for try await _ in stream.events {}
            XCTAssertFalse(
                backend.isGenerating,
                "Foundation backend must stop generating after the stream ends"
            )
        }
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
