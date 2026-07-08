import XCTest
import Foundation
@testable import ManifoldInference
import ManifoldTestSupport

/// Matrix tests for capability-gated requests at the inference boundary.
///
/// These use `MockInferenceBackend` so they stay CI-safe with default traits
/// disabled while still pinning the shared behavior every backend relies on:
/// advertised capabilities must either allow the request through or produce an
/// explicit local signal before an unsupported hint can be silently dropped.
@MainActor
final class BackendCapabilityMatrixTests: XCTestCase {
    private var provider: FakeGenerationContextProvider!
    private var coordinator: GenerationQueue!

    override func setUp() async throws {
        try await super.setUp()
        provider = FakeGenerationContextProvider()
        coordinator = GenerationQueue()
        provider.bind(to: coordinator)
    }

    override func tearDown() async throws {
        await coordinator?.stopGenerationAndWait()
        GenerationQueue.jsonModeUnsupportedWarningHook = nil
        GenerationQueue.toolsUnsupportedWarningHook = nil
        GenerationQueue.thinkingUnsupportedWarningHook = nil
        coordinator = nil
        provider = nil
        try await super.tearDown()
    }

    func test_visionCapabilityMatrix_rejectsImagesWhenUnsupportedBeforeBackendGenerate() throws {
        provider.backend.capabilities = capabilities(supportsVision: false)

        XCTAssertThrowsError(
            try coordinator.generate(structuredMessages: [imageMessage()])
        ) { error in
            guard case InferenceError.inferenceFailure(let message) = error else {
                XCTFail("expected InferenceError.inferenceFailure, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("supportsVision"), message)
        }

        XCTAssertEqual(provider.backend.generateCallCount, 0,
                       "unsupported images must fail before backend.generate can flatten or drop them")
        XCTAssertNil(provider.backend.lastReceivedStructuredHistory,
                     "unsupported images must not be installed on a text-only backend")
    }

    func test_visionCapabilityMatrix_forwardsImagesWhenAdvertised() async throws {
        provider.backend.capabilities = capabilities(supportsVision: true)

        let stream = try coordinator.generate(structuredMessages: [imageMessage()])
        for try await _ in stream.events {}

        XCTAssertEqual(provider.backend.generateCallCount, 1)
        let history = try XCTUnwrap(provider.backend.lastReceivedStructuredHistory)
        XCTAssertTrue(history.contains { message in
            message.parts.contains { part in
                if case .image = part { return true }
                return false
            }
        }, "vision-capable backends must receive image parts intact")
    }

    func test_toolCapabilityMatrix_rejectsToolsWhenUnsupportedBeforeBackendGenerate() throws {
        provider.backend.capabilities = capabilities(supportsToolCalling: false)
        let warnings = CapabilityWarningCapture()
        GenerationQueue.toolsUnsupportedWarningHook = { backendType, message in
            warnings.record(backendType: backendType, message: message)
        }

        XCTAssertThrowsError(
            try coordinator.enqueue(messages: [("user", "use a tool")], tools: [weatherTool()])
        ) { error in
            guard case InferenceError.inferenceFailure(let message) = error else {
                XCTFail("expected InferenceError.inferenceFailure, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("does not support tool calling"), message)
        }

        XCTAssertEqual(provider.backend.generateCallCount, 0,
                       "unsupported tools must fail before the request reaches the backend")
        let entry = try XCTUnwrap(warnings.snapshot().first)
        XCTAssertEqual(entry.backendType, "MockInferenceBackend")
        XCTAssertTrue(entry.message.contains("supportsToolCalling"), entry.message)
    }

    func test_toolCapabilityMatrix_forwardsToolsWhenAdvertised() async throws {
        provider.backend.capabilities = capabilities(supportsToolCalling: true)
        let warnings = CapabilityWarningCapture()
        GenerationQueue.toolsUnsupportedWarningHook = { backendType, message in
            warnings.record(backendType: backendType, message: message)
        }

        let (_, stream) = try coordinator.enqueue(
            messages: [("user", "use a tool")],
            tools: [weatherTool()]
        )
        for try await _ in stream.events {}

        XCTAssertTrue(warnings.snapshot().isEmpty)
        XCTAssertEqual(provider.backend.generateCallCount, 1)
        XCTAssertEqual(provider.backend.lastConfig?.tools.map(\.name), ["get_weather"])
    }

    func test_jsonCapabilityMatrix_warnsButForwardsWhenNativeJSONModeUnsupported() async throws {
        provider.backend.capabilities = capabilities(supportsNativeJSONMode: false)
        let warnings = CapabilityWarningCapture()
        GenerationQueue.jsonModeUnsupportedWarningHook = { backendType, message in
            warnings.record(backendType: backendType, message: message)
        }

        let stream = try coordinator.generate(messages: [("user", "return json")], jsonMode: true)
        for try await _ in stream.events {}

        XCTAssertEqual(provider.backend.generateCallCount, 1)
        XCTAssertTrue(provider.backend.lastHints?.jsonMode == true)
        let entry = try XCTUnwrap(warnings.snapshot().first)
        XCTAssertEqual(entry.backendType, "MockInferenceBackend")
        XCTAssertTrue(entry.message.contains("supportsNativeJSONMode"), entry.message)
    }

    func test_jsonCapabilityMatrix_forwardsWithoutWarningWhenNativeJSONModeAdvertised() async throws {
        provider.backend.capabilities = capabilities(supportsNativeJSONMode: true)
        let warnings = CapabilityWarningCapture()
        GenerationQueue.jsonModeUnsupportedWarningHook = { backendType, message in
            warnings.record(backendType: backendType, message: message)
        }

        let stream = try coordinator.generate(messages: [("user", "return json")], jsonMode: true)
        for try await _ in stream.events {}

        XCTAssertTrue(warnings.snapshot().isEmpty)
        XCTAssertEqual(provider.backend.generateCallCount, 1)
        XCTAssertTrue(provider.backend.lastHints?.jsonMode == true)
    }

    func test_thinkingCapabilityMatrix_warnsButForwardsHintsWhenThinkingUnsupported() async throws {
        provider.backend.capabilities = capabilities(supportsThinking: false)
        let warnings = CapabilityWarningCapture()
        GenerationQueue.thinkingUnsupportedWarningHook = { backendType, message in
            warnings.record(backendType: backendType, message: message)
        }

        var config = GenerationConfig(maxOutputTokens: 16)
        config.maxThinkingTokens = 4
        let hints = GenerationRuntimeHints(thinkingMarkers: .qwen3)
        let stream = try coordinator.generateWithConfig(
            messages: [("user", "think briefly")],
            systemPrompt: nil,
            config: config,
            hints: hints
        )
        for try await _ in stream.events {}

        XCTAssertEqual(provider.backend.generateCallCount, 1)
        XCTAssertEqual(provider.backend.lastConfig?.maxThinkingTokens, 4)
        XCTAssertEqual(provider.backend.lastHints?.thinkingMarkers, .qwen3)
        let entry = try XCTUnwrap(warnings.snapshot().first)
        XCTAssertEqual(entry.backendType, "MockInferenceBackend")
        XCTAssertTrue(entry.message.contains("supportsThinking"), entry.message)
        XCTAssertTrue(entry.message.contains("maxThinkingTokens"), entry.message)
        XCTAssertTrue(entry.message.contains("thinkingMarkers"), entry.message)
    }

    func test_thinkingCapabilityMatrix_emitsThinkingEventsOnlyWhenAdvertisedAndProduced() async throws {
        provider.backend.capabilities = capabilities(supportsThinking: true)
        provider.backend.thinkingTokensToYield = ["reasoning"]
        let warnings = CapabilityWarningCapture()
        GenerationQueue.thinkingUnsupportedWarningHook = { backendType, message in
            warnings.record(backendType: backendType, message: message)
        }

        let stream = try coordinator.generate(messages: [("user", "think")], maxThinkingTokens: 8)
        var sawThinkingToken = false
        var sawThinkingComplete = false
        for try await event in stream.events {
            switch event {
            case .thinkingToken:
                sawThinkingToken = true
            case .thinkingCompleted:
                sawThinkingComplete = true
            default:
                break
            }
        }

        XCTAssertTrue(warnings.snapshot().isEmpty)
        XCTAssertTrue(sawThinkingToken, "a backend advertising thinking must surface reasoning tokens when produced")
        XCTAssertTrue(sawThinkingComplete, "thinking tokens must be closed by thinkingCompleted")
    }

    private func capabilities(
        supportsToolCalling: Bool = false,
        supportsNativeJSONMode: Bool = false,
        supportsThinking: Bool = false,
        supportsVision: Bool = false
    ) -> BackendCapabilities {
        BackendCapabilities(
            supportedParameters: [.temperature],
            maxContextTokens: 4096,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: supportsToolCalling,
            supportsStructuredOutput: supportsNativeJSONMode,
            supportsNativeJSONMode: supportsNativeJSONMode,
            cancellationStyle: .cooperative,
            supportsTokenCounting: false,
            supportsThinking: supportsThinking,
            supportsVision: supportsVision
        )
    }

    private func imageMessage() -> StructuredMessage {
        StructuredMessage(
            role: "user",
            parts: [
                .text("describe this"),
                .image(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png")
            ]
        )
    }

    private func weatherTool() -> ToolDefinition {
        ToolDefinition(name: "get_weather", description: "Lookup weather")
    }
}

private final class CapabilityWarningCapture: @unchecked Sendable {
    struct Entry {
        let backendType: String
        let message: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func record(backendType: String, message: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(Entry(backendType: backendType, message: message))
    }

    func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}
