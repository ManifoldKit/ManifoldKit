import XCTest
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldTestSupport
@testable import ManifoldBackends

/// Contract tests that lock down capability fields on every concrete backend.
///
/// These tests exist to catch merge conflicts or accidental regressions where
/// capability flags are removed or flipped. If a test here fails, the backend's
/// declared posture has changed — update it deliberately.
final class BackendCapabilitiesContractTests: XCTestCase {

    // MARK: - Remote backends

    #if Ollama && CloudSaaS
    func test_cloudBackends_reportIsRemote() {
        XCTAssertTrue(ClaudeBackend().capabilities.isRemote,
                      "ClaudeBackend makes network calls — isRemote must be true")
        XCTAssertTrue(OpenAIBackend().capabilities.isRemote,
                      "OpenAIBackend makes network calls — isRemote must be true")
        XCTAssertTrue(OllamaBackend().capabilities.isRemote,
                      "OllamaBackend makes network calls — isRemote must be true")
    }
    #endif

    // MARK: - Tool Calling

    #if Ollama && CloudSaaS
    func test_cloudBackends_toolCallingCapabilities() {
        // Tool calling is advertised by every cloud backend now that the
        // per-vendor wire-format work in #435 has landed:
        //   - Ollama: Wave 2 dispatch wiring (PR #640) — OpenAI-compatible
        //     `tool_calls` over NDJSON.
        //   - OpenAI: Chat Completions `tools[]` + streaming `tool_calls[]`
        //     deltas keyed by `index`.
        //   - Claude: Anthropic Messages `tools[]` + `content_block_*`
        //     events keyed by tool_use index.
        XCTAssertTrue(ClaudeBackend().capabilities.supportsToolCalling,
                      "ClaudeBackend advertises tool calling since #435 Anthropic wiring")
        XCTAssertTrue(OpenAIBackend().capabilities.supportsToolCalling,
                      "OpenAIBackend advertises tool calling since #435 Chat Completions wiring")
        XCTAssertTrue(OllamaBackend().capabilities.supportsToolCalling,
                      "OllamaBackend advertises tool calling since Wave 2 dispatch wiring")
    }
    #endif

    #if CloudSaaS
    func test_cloudBackends_structuredOutputCapabilities() {
        XCTAssertTrue(ClaudeBackend().capabilities.supportsStructuredOutput,
                      "ClaudeBackend supports structured output")
        XCTAssertTrue(OpenAIBackend().capabilities.supportsStructuredOutput,
                      "OpenAIBackend supports structured output via json_schema")
    }
    #endif

    #if Ollama && CloudSaaS
    func test_backends_nativeJSONModeCapabilities() {
        XCTAssertFalse(ClaudeBackend().capabilities.supportsNativeJSONMode,
                       "ClaudeBackend does not advertise a dedicated native JSON mode")
        XCTAssertTrue(OpenAIBackend().capabilities.supportsNativeJSONMode,
                      "OpenAIBackend supports response_format json_object")
        XCTAssertTrue(OllamaBackend().capabilities.supportsNativeJSONMode,
                      "OllamaBackend supports format=json")
    }
    #endif

    // MARK: - supportsThinking

    /// `supportsThinking` is now derived from ``ModelManifest`` rather than
    /// hardcoded on each backend. Claude 4-class models advertise extended
    /// thinking via the manifest table, so `ClaudeBackend` configured with
    /// the default `claude-sonnet-4-20250514` name reports `true`.
    /// `OpenAIBackend`'s default `gpt-4o-mini` is a chat model (no thinking),
    /// and `OllamaBackend` resolves at load time via `/api/show` so an
    /// unloaded instance reports the manifest-default `false`.
    #if Ollama && CloudSaaS
    func test_cloudBackends_advertiseThinkingFromManifest() {
        XCTAssertTrue(ClaudeBackend().capabilities.supportsThinking,
                      "ClaudeBackend default model is claude-sonnet-4, which the manifest table reports as a thinking model")
        XCTAssertFalse(OpenAIBackend().capabilities.supportsThinking,
                       "OpenAIBackend default model gpt-4o-mini is not a thinking model")
        XCTAssertFalse(OllamaBackend().capabilities.supportsThinking,
                       "OllamaBackend reports thinking only after /api/show probe runs at loadModel time")
    }
    #endif

    // MARK: - Local backends

#if Llama
    func test_llamaBackend_reportNotRemote() throws {
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice,
                          "LlamaBackend requires Metal (unavailable in simulator)")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "LlamaBackend requires Apple Silicon")
        XCTAssertFalse(LlamaBackend().capabilities.isRemote,
                       "LlamaBackend runs on-device — isRemote must be false")
    }

    func test_llamaBackend_supportsToolCalling() throws {
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice,
                          "LlamaBackend requires Metal (unavailable in simulator)")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "LlamaBackend requires Apple Silicon")
        XCTAssertTrue(LlamaBackend().capabilities.supportsToolCalling,
                      "LlamaBackend advertises tool calling for Gemma 4 and parser-backed local tool-call formats")
    }

    func test_llamaBackend_doesNotSupportNativeJSONMode() throws {
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice,
                          "LlamaBackend requires Metal (unavailable in simulator)")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "LlamaBackend requires Apple Silicon")
        XCTAssertFalse(LlamaBackend().capabilities.supportsNativeJSONMode,
                       "LlamaBackend does not expose a native JSON mode")
    }

    /// `LlamaGenerationDriver` already filters thinking markers and emits
    /// `.thinkingToken` / `.thinkingComplete`, so the capability flag must
    /// advertise it for consumers gating reasoning UI (#480).
    func test_llamaBackend_supportsThinking() throws {
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice,
                          "LlamaBackend requires Metal (unavailable in simulator)")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "LlamaBackend requires Apple Silicon")
        XCTAssertTrue(LlamaBackend().capabilities.supportsThinking,
                      "LlamaBackend emits thinking events via LlamaGenerationDriver — supportsThinking must be true")
    }
#endif

#if MLX
    func test_mlxBackend_reportNotRemote() throws {
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "MLXBackend requires Apple Silicon")
        XCTAssertFalse(MLXBackend().capabilities.isRemote,
                       "MLXBackend runs on-device — isRemote must be false")
        XCTAssertFalse(MLXBackend().capabilities.supportsNativeJSONMode,
                       "MLXBackend does not expose a native JSON mode")
    }

    /// MLXBackend routes generation through `ThinkingTransform` when
    /// `config.thinkingMarkers` is set, emitting `.thinkingToken` /
    /// `.thinkingComplete` events. Capability flag must reflect that (#480).
    func test_mlxBackend_supportsThinking() throws {
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "MLXBackend requires Apple Silicon")
        XCTAssertTrue(MLXBackend().capabilities.supportsThinking,
                      "MLXBackend emits thinking events via ThinkingTransform — supportsThinking must be true")
    }

    /// MLXBackend uses MLX's process-global GPU buffer cache and Metal
    /// device — it must coordinate with `MLXResourceArbiter` for safe
    /// multi-backend hosting. See `MLXResourceArbiter.swift` for details.
    func test_mlxBackend_sharesMLXProcessResources() throws {
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
                          "MLXBackend requires Apple Silicon")
        XCTAssertTrue(MLXBackend().capabilities.sharesMLXProcessResources,
                      "MLXBackend uses MLX.Memory.cacheLimit — sharesMLXProcessResources must be true")
    }
#endif

#if canImport(FoundationModels)
    @available(iOS 26, macOS 26, *)
    func test_foundationBackend_reportNotRemote() {
        XCTAssertFalse(FoundationBackend().capabilities.isRemote,
                       "FoundationBackend uses OS-managed on-device models — isRemote must be false")
    }

    @available(iOS 26, macOS 26, *)
    func test_foundationBackend_supportsToolCalling_viaGuidedGeneration() {
        // Tool calling is synthesized on top of GuidedGeneration (#434): the
        // backend constrains the on-device model to a (text|tool_call) sum-type
        // schema and emits .toolCall events when the model picks the tool branch.
        let caps = FoundationBackend().capabilities
        XCTAssertTrue(caps.supportsToolCalling,
                      "FoundationBackend exposes tool calling via GuidedGeneration on iOS 26 / macOS 26 (#434)")
        XCTAssertFalse(caps.streamsToolCallArguments,
                       "FoundationBackend emits whole .toolCall events; no streaming start/delta")
    }

    @available(iOS 26, macOS 26, *)
    func test_foundationBackend_supportsGuidedStructuredOutput() {
        let caps = FoundationBackend().capabilities

        XCTAssertTrue(caps.supportsGuidedStructuredOutput,
                      "FoundationBackend routes structured generation through FoundationModels GuidedGeneration.")
        XCTAssertEqual(caps.preferredStructuredOutputSupport, .guidedGeneration)
    }

    @available(iOS 26, macOS 26, *)
    func test_foundationBackend_doesNotSupportNativeJSONMode() {
        XCTAssertFalse(FoundationBackend().capabilities.supportsNativeJSONMode,
                       "FoundationBackend does not expose a native JSON mode in this version")
    }

    /// FoundationBackend does not expose reasoning events today; it stays at
    /// the default `false` until Foundation Models gain a thinking surface.
    @available(iOS 26, macOS 26, *)
    func test_foundationBackend_doesNotAdvertiseThinking() {
        XCTAssertFalse(FoundationBackend().capabilities.supportsThinking,
                       "FoundationBackend does not emit thinking events — supportsThinking must be false")
    }

    /// Apple's public FoundationModels SDK currently exposes text and
    /// structured prompt segments, but no image-bearing prompt/input type.
    /// Keep the capability explicit so the runtime rejects image-bearing
    /// turns locally instead of flattening them away for FoundationBackend.
    @available(iOS 26, macOS 26, *)
    func test_foundationBackend_doesNotAdvertiseVision() {
        XCTAssertFalse(FoundationBackend().capabilities.supportsVision,
                       "FoundationBackend must not advertise image input until FoundationModels exposes an image-bearing Prompt/Transcript surface")
    }
#endif
}
