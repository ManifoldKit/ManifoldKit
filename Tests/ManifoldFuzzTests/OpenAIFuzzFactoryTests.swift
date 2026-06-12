import XCTest
import ManifoldFuzz
import ManifoldInference
import ManifoldBackends
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

    private func makeFactory(
        model: String = "gpt-4o-mini",
        requestTimeout: TimeInterval = 90
    ) -> OpenAIFuzzFactory {
        OpenAIFuzzFactory(
            // No /v1 suffix — OpenAIBackend.buildRequest appends it. (No request
            // is built here regardless; this documents the contract.)
            baseURL: URL(string: "https://openrouter.ai/api")!,
            apiKey: "sk-test-never-sent-no-network",
            modelName: model,
            requestTimeout: requestTimeout
        )
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

    /// The factory's `requestTimeout` must propagate to the backend's per-request
    /// HTTP idle override (`SSECloudBackend.requestIdleTimeout`). Without this the
    /// fuzz path inherits the 300s session default and a hung free-model iteration
    /// stalls ~300s before abandoning — even though the detectors flag >60s.
    func test_makeHandle_propagatesRequestTimeoutToBackend() async throws {
        let handle = try await makeFactory(requestTimeout: 42).makeHandle()

        let backend = try XCTUnwrap(
            handle.backend as? OpenAIBackend,
            "openai fuzz handle must wrap an OpenAIBackend so the timeout override is observable."
        )
        XCTAssertEqual(
            backend.requestIdleTimeout, 42,
            "Factory must apply requestTimeout as the backend's per-request idle override."
        )
    }
}
