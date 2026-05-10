#if Tools && (Ollama || CloudSaaS || canImport(FoundationModels))
import Foundation
import XCTest
import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends

@MainActor
final class DemoScenarioCrossBackendContractTests: XCTestCase {

    func test_meetingNotes_wholeCallMock_matchesSharedContract() async throws {
        let backend = MockInferenceBackend(capabilities: BackendCapabilities(
            supportsToolCalling: true,
            streamsToolCallArguments: false,
            supportsParallelToolCalls: false
        ))
        backend.isModelLoaded = true
        backend.tokensToYield = []
        backend.scriptedToolCallsPerTurn = [[DemoScenarioMeetingNotes.makeScriptedCall()], []]
        backend.tokensToYieldPerTurn = [
            [],
            ["Riley owns BetaLaunch. Decision: Ship candidate Friday. Blocker: Security review."]
        ]

        let result = try await DemoScenarioE2EHarness(
            backend: backend,
            backendName: "whole-call-mock",
            modelName: "scripted"
        ).runAndAssert(DemoScenarioMeetingNotes.spec, registry: DemoScenarioMeetingNotes.makeRegistry())

        DemoScenarioMeetingNotes.assertContract(result)
    }

    func test_meetingNotes_streamingArgsMock_matchesSharedContract() async throws {
        let backend = MockInferenceBackend(capabilities: BackendCapabilities(
            supportsToolCalling: true,
            streamsToolCallArguments: true,
            supportsParallelToolCalls: true
        ))
        backend.isModelLoaded = true
        let call = DemoScenarioMeetingNotes.makeScriptedCall(id: "stream-meeting-notes")
        backend.tokensToYield = []
        backend.scriptedToolCallDeltasPerTurn = [[
            .start(callId: call.id, name: call.toolName),
            .delta(callId: call.id, textDelta: call.arguments),
            .call(call),
        ], []]
        backend.tokensToYieldPerTurn = [
            [],
            ["Riley owns BetaLaunch. Decision: Ship candidate Friday. Blocker: Security review."]
        ]

        let result = try await DemoScenarioE2EHarness(
            backend: backend,
            backendName: "streaming-args-mock",
            modelName: "scripted"
        ).runAndAssert(DemoScenarioMeetingNotes.spec, registry: DemoScenarioMeetingNotes.makeRegistry())

        DemoScenarioMeetingNotes.assertContract(result)
    }
}

/// Cross-backend #707 meeting-notes scenario coverage.
///
/// All three real legs use the same prompt, `meeting_notes_lookup` toolset,
/// and `DemoScenarioMeetingNotes.assertContract` transcript assertions. Live
/// dependencies are explicitly gated so normal CI gets deterministic mock
/// coverage without requiring Ollama, Anthropic credentials, or Apple
/// Intelligence availability.
@MainActor
final class DemoScenarioCrossBackendE2ETests: XCTestCase {

    func test_deterministicMeetingNotesContract_coversOptionalBackendSkips() async throws {
        let backend = MockInferenceBackend(capabilities: BackendCapabilities(
            supportsToolCalling: true,
            streamsToolCallArguments: false,
            supportsParallelToolCalls: false
        ))
        backend.isModelLoaded = true
        backend.tokensToYield = []
        backend.scriptedToolCallsPerTurn = [[DemoScenarioMeetingNotes.makeScriptedCall()], []]
        backend.tokensToYieldPerTurn = [
            [],
            ["Riley owns BetaLaunch. Decision: Ship candidate Friday. Blocker: Security review."]
        ]

        let result = try await DemoScenarioE2EHarness(
            backend: backend,
            backendName: "cross-backend-deterministic-mock",
            modelName: "scripted"
        ).runAndAssert(DemoScenarioMeetingNotes.spec, registry: DemoScenarioMeetingNotes.makeRegistry())

        DemoScenarioMeetingNotes.assertContract(result)
    }

#if Ollama
    func test_ollama_meetingNotes_sharedScenario() async throws {
        try XCTSkipUnless(
            HardwareRequirements.hasOllamaServer,
            "Ollama server not running at localhost:11434"
        )
        let available = HardwareRequirements.listOllamaModels() ?? []
        let preferredModels = ["llama3.1:8b", "qwen2.5:7b-instruct", "qwen2.5:7b"]
        let modelName: String
        if let pinned = ProcessInfo.processInfo.environment["OLLAMA_TEST_MODEL"] {
            guard available.contains(pinned) else {
                XCTFail("OLLAMA_TEST_MODEL=\(pinned) is set but not installed locally. Installed: \(available)")
                throw XCTSkip("OLLAMA_TEST_MODEL not installed")
            }
            modelName = pinned
        } else {
            guard let match = preferredModels.first(where: { available.contains($0) }) else {
                throw XCTSkip("No tool-calling-capable Ollama model installed; need one of \(preferredModels). Installed: \(available)")
            }
            modelName = match
        }

        let backend = OllamaBackend()
        backend.configure(baseURL: URL(string: "http://localhost:11434")!, modelName: modelName)
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        defer { backend.unloadModel() }

        let result = try await DemoScenarioE2EHarness(
            backend: backend,
            backendName: "Ollama",
            modelName: modelName
        ).runAndAssert(DemoScenarioMeetingNotes.spec, registry: DemoScenarioMeetingNotes.makeRegistry())

        DemoScenarioMeetingNotes.assertContract(result)
    }
#endif

#if CloudSaaS
    func test_claude_meetingNotes_sharedScenario() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !apiKey.isEmpty else {
            throw XCTSkip("ANTHROPIC_API_KEY not set; skipping live Claude meeting-notes scenario")
        }
        let modelName = try claudeModelName()
        let backend = ClaudeBackend()
        backend.configure(
            baseURL: URL(string: "https://api.anthropic.com")!,
            apiKey: apiKey,
            modelName: modelName
        )
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        defer { backend.unloadModel() }

        let result = try await DemoScenarioE2EHarness(
            backend: backend,
            backendName: "Claude",
            modelName: modelName
        ).runAndAssert(DemoScenarioMeetingNotes.spec, registry: DemoScenarioMeetingNotes.makeRegistry())

        DemoScenarioMeetingNotes.assertContract(result)
    }

    private func claudeModelName() throws -> String {
        if let pinned = ProcessInfo.processInfo.environment["CLAUDE_TEST_MODEL"] {
            guard !pinned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                XCTFail("CLAUDE_TEST_MODEL is set but empty")
                throw XCTSkip("CLAUDE_TEST_MODEL is empty")
            }
            return pinned
        }
        return "claude-3-5-haiku-20241022"
    }
#endif

#if canImport(FoundationModels)
    @available(iOS 26, macOS 26, *)
    func test_foundation_meetingNotes_sharedScenario() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FOUNDATION_CROSS_BACKEND"] == "1" else {
            throw XCTSkip("RUN_FOUNDATION_CROSS_BACKEND=1 not set; skipping nondeterministic live Foundation meeting-notes scenario")
        }
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        ) else {
            throw XCTSkip("FoundationModels requires iOS 26 / macOS 26")
        }
        try XCTSkipUnless(
            FoundationBackend.isAvailable,
            "Apple Intelligence is not available on this device"
        )
        let foundationReady = await FoundationBackend.probeIsReady()
        try XCTSkipUnless(foundationReady, "Apple Intelligence model is not ready")

        let backend = FoundationBackend()
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        defer { backend.unloadModel() }

        let result = try await DemoScenarioE2EHarness(
            backend: backend,
            backendName: "Foundation",
            modelName: "SystemLanguageModel.default"
        ).runAndAssert(DemoScenarioMeetingNotes.spec, registry: DemoScenarioMeetingNotes.makeRegistry())

        DemoScenarioMeetingNotes.assertContract(result)
    }
#endif
}
#endif
