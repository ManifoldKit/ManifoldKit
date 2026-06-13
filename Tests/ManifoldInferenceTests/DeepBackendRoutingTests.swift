import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Coverage for the optional Deep-backend routing seam on ``InferenceService``
/// (#799). Unlike the unqueued `fastBackend` primitive, a Deep-routed request
/// flows through the QUEUED `enqueue` path so it keeps cancellation,
/// request-group scoping, and stream lifecycle — while dispatching to a
/// host-owned secondary backend WITHOUT tearing down or unloading the primary.
@MainActor
final class DeepBackendRoutingTests: XCTestCase {

    private func makeConfig() -> GenerationConfig { GenerationConfig() }

    private func consume(_ stream: GenerationStream) async throws -> String {
        var visible = ""
        for try await event in stream.events {
            if case let .token(t) = event { visible += t }
        }
        return visible
    }

    // MARK: - Routing

    func test_enqueue_deepRoute_routesToDeepBackend_primaryUntouchedAndLoaded() async throws {
        let primary = MockInferenceBackend()
        primary.isModelLoaded = true
        primary.tokensToYield = ["primary"]

        let deep = MockInferenceBackend()
        deep.isModelLoaded = true
        deep.tokensToYield = ["deep"]

        let service = InferenceService(backend: primary, name: "Primary")
        service.deepBackend = deep

        let (_, stream) = try service.enqueue(
            messages: [.user("scene-start beat")],
            config: makeConfig(),
            route: .deep
        )
        let visible = try await consume(stream)

        XCTAssertEqual(visible, "deep", "deep route must produce the deep backend's tokens")
        XCTAssertEqual(deep.generateCallCount, 1, "deep backend should have served the routed turn")
        XCTAssertEqual(primary.generateCallCount, 0, "primary must not see a deep-routed turn")
        // The whole point of a coexisting secondary backend: the primary is
        // never torn down to serve a Deep turn.
        XCTAssertEqual(primary.unloadCallCount, 0, "primary must not be unloaded for a deep turn")
        XCTAssertTrue(primary.isModelLoaded, "primary must stay loaded across a deep turn")
    }

    func test_enqueue_primaryRoute_ignoresDeepBackend() async throws {
        let primary = MockInferenceBackend()
        primary.isModelLoaded = true
        primary.tokensToYield = ["primary"]

        let deep = MockInferenceBackend()
        deep.isModelLoaded = true
        deep.tokensToYield = ["deep"]

        let service = InferenceService(backend: primary, name: "Primary")
        service.deepBackend = deep

        // Default route is .primary — existing behavior must be unchanged even
        // when a deep backend happens to be configured.
        let (_, stream) = try service.enqueue(
            messages: [.user("ordinary turn")],
            config: makeConfig()
        )
        let visible = try await consume(stream)

        XCTAssertEqual(visible, "primary")
        XCTAssertEqual(primary.generateCallCount, 1)
        XCTAssertEqual(deep.generateCallCount, 0, "primary route must never touch the deep backend")
    }

    func test_enqueue_deepRoute_fallsBackToPrimary_whenDeepBackendNil() async throws {
        let primary = MockInferenceBackend()
        primary.isModelLoaded = true
        primary.tokensToYield = ["primary"]

        let service = InferenceService(backend: primary, name: "Primary")
        XCTAssertNil(service.deepBackend, "precondition: deepBackend defaults to nil")

        // route: .deep with no deep backend resolves to nil -> primary serves;
        // must not crash or skip the load-coordinator gate path.
        let (_, stream) = try service.enqueue(
            messages: [.user("hi")],
            config: makeConfig(),
            route: .deep
        )
        let visible = try await consume(stream)

        XCTAssertEqual(visible, "primary", "deep route with no deep backend must fall back to primary")
        XCTAssertEqual(primary.generateCallCount, 1)
    }

    // MARK: - Cancellation targets the routed backend (#799 review C2/C5)

    func test_stopGeneration_targetsDeepBackend_whenDeepRequestActive() throws {
        let primary = MockInferenceBackend()
        primary.isModelLoaded = true

        let deep = MockInferenceBackend()
        deep.isModelLoaded = true

        let service = InferenceService(backend: primary, name: "Primary")
        service.deepBackend = deep

        // enqueue + drainQueue run synchronously on the MainActor, so the
        // deep request is the active request before the spawned task body runs.
        _ = try service.enqueue(
            messages: [.user("deep turn")],
            config: makeConfig(),
            route: .deep
        )
        service.stopGeneration()

        XCTAssertEqual(deep.stopCallCount, 1, "stop must target the in-flight deep backend")
        XCTAssertEqual(primary.stopCallCount, 0, "stop must NOT hit the primary when a deep turn is active (no leaked deep stream)")
    }

    // MARK: - Configuration introspection

    func test_hasDeepBackend_and_deepCapabilities_reflectState() {
        let primary = MockInferenceBackend()
        primary.isModelLoaded = true
        let service = InferenceService(backend: primary, name: "Primary")

        XCTAssertFalse(service.hasDeepBackend)
        XCTAssertNil(service.deepCapabilities)

        let deep = MockInferenceBackend()
        service.deepBackend = deep

        XCTAssertTrue(service.hasDeepBackend)
        XCTAssertNotNil(service.deepCapabilities, "deepCapabilities must surface the deep backend's capabilities")
    }
}
