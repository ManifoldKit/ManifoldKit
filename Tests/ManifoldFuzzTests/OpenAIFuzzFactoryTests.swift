#if Fuzz
#if CloudSaaS
import XCTest
import ManifoldFuzz
import ManifoldInference
import ManifoldBackends // SSECloudBackend / OpenAIBackend (re-exported)
@testable import ManifoldFuzzBackends

/// Unit tests for ``OpenAIFuzzFactory`` — the OpenAI-Chat-Completions-compatible
/// cloud fuzz factory (OpenRouter, OpenAI, …).
///
/// Network-free: `makeHandle()` constructs an `OpenAIBackend`, configures it,
/// and runs the no-op cloud `loadModel` (which only validates the base URL and
/// flips `isModelLoaded`). No HTTP request is issued until `generate`, so these
/// assertions never touch the wire and need no API key, no live endpoint, and
/// no `MockURLProtocol` stubs.
final class OpenAIFuzzFactoryTests: XCTestCase {

    private func makeFactory(model: String = "gpt-4o-mini") -> OpenAIFuzzFactory {
        OpenAIFuzzFactory(
            // No /v1 suffix — OpenAIBackend.buildRequest appends it. (No request
            // is built here regardless; this documents the contract.)
            baseURL: URL(string: "https://openrouter.ai/api")!,
            apiKey: "sk-test-never-sent-no-network",
            modelName: model
        )
    }

    /// The factory must thread `requestTimeout` onto the backend's per-request
    /// HTTP idle override (``SSECloudBackend/requestIdleTimeout``) so a hung
    /// cloud iteration abandons at the bounded value instead of the 300s shared
    /// session default. Network-free: only `configure` + the no-op cloud
    /// `loadModel` run before we read the override back.
    func test_makeHandle_propagatesRequestTimeoutToBackend() async throws {
        let factory = OpenAIFuzzFactory(
            baseURL: URL(string: "https://openrouter.ai/api")!,
            apiKey: "sk-test-never-sent-no-network",
            modelName: "gpt-4o-mini",
            requestTimeout: 42
        )
        let handle = try await factory.makeHandle()
        let backend = try XCTUnwrap(
            handle.backend as? SSECloudBackend,
            "OpenAI fuzz backend must be an SSECloudBackend so the per-request timeout override applies."
        )
        XCTAssertEqual(
            backend.requestIdleTimeout, 42,
            "Factory must propagate requestTimeout to the backend's per-request idle override."
        )
    }

    /// The default keeps the bound well below the 300s session default while
    /// staying above the detectors' 60s flag threshold.
    func test_defaultRequestTimeout_is90Seconds() async throws {
        let handle = try await makeFactory().makeHandle()
        let backend = try XCTUnwrap(handle.backend as? SSECloudBackend)
        XCTAssertEqual(backend.requestIdleTimeout, 90)
    }

    /// Cloud generation cannot be bit-reproduced — providers don't honour a seed
    /// reproducibly and `:free` slugs route to shifting backends. The factory
    /// must opt out of deterministic replay so `Replayer` short-circuits with
    /// `.nonDeterministicBackend` instead of running a guaranteed-noisy replay.
    func test_supportsDeterministicReplay_isFalse() {
        XCTAssertFalse(
            makeFactory().supportsDeterministicReplay,
            "Cloud backends are non-deterministic; replay/shrink must refuse."
        )
    }

    /// `makeHandle()` wires a `BackendHandle` whose identity fields match the
    /// configured slug, with `backendName == \"openai\"` and a non-nil marker
    /// snapshot. Exercises the full construct→configure→loadModel path offline.
    func test_makeHandle_producesExpectedBackendHandle() async throws {
        let slug = "deepseek/deepseek-r1:free"
        let handle = try await makeFactory(model: slug).makeHandle()

        XCTAssertEqual(handle.backendName, "openai",
                       "Factory must label the backend so findings attribute to the cloud path.")
        XCTAssertEqual(handle.modelId, slug,
                       "modelId must echo the requested slug verbatim.")
        XCTAssertEqual(handle.modelURL, URL(string: "openai:\(slug)"),
                       "modelURL must namespace the slug under the openai: scheme.")
        XCTAssertNotNil(handle.templateMarkers,
                        "Factory always sets a marker snapshot (manifest markers or the Qwen3 fallback).")
    }
}
#endif
#endif
