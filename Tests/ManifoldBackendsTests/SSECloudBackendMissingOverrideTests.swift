import XCTest
@testable import ManifoldCloudCore
@testable import ManifoldInference

/// Regression coverage for `SSECloudBackend`'s subclass-override hooks.
///
/// Before this fix, a subclass that forgot to override `capabilities` or
/// `buildRequest(...)` crashed the whole host process via `fatalError` the
/// first time either was touched — a real risk given `SSECloudBackend` is
/// `open` and no companion package (manifold-mlx, manifold-llama) currently
/// subclasses it, but nothing stops a third-party subclass from doing so.
/// `buildRequest` was already `throws`, so it now throws
/// `CloudBackendError.missingRequiredOverride` instead of trapping —
/// compile-time enforcement (the `payloadHandler` pattern) is not used for
/// either hook: both are dynamically re-evaluated per call against live
/// instance state (`capabilities` reads `modelName`; `buildRequest` reads
/// keychain/cache-policy/baseURL/modelName), which is what open-method
/// overriding is for, so both log/throw a conservative fallback instead.
///
/// Sabotage check: reintroduce either `fatalError` and these tests crash the
/// test process instead of passing/failing normally.
final class SSECloudBackendMissingOverrideTests: XCTestCase {

    func test_capabilities_doesNotTrap_whenSubclassOmitsOverride() {
        let backend = BareMinimumSSEBackend(
            defaultModelName: "test-model",
            urlSession: URLSession(configuration: .ephemeral),
            payloadHandler: NoOpPayloadHandler()
        )
        // Must not crash merely by being read.
        let capabilities = backend.capabilities
        XCTAssertTrue(capabilities.isRemote, "the base fallback should still report the backend as remote")
        XCTAssertFalse(capabilities.supportsToolCalling, "the base fallback should be maximally conservative")
        // Regression: a first cut of this fallback used
        // `BackendCapabilities(isRemote: true)` and silently inherited the
        // memberwise-init defaults for everything else — `supportsStreaming:
        // true` (advertising a capability the broken subclass never
        // demonstrated) and `memoryStrategy: .resident` (violating this
        // type's own documented invariant that every remote backend reports
        // `.external`). Assert both explicitly so "conservative" is checked,
        // not just claimed in the doc comment.
        XCTAssertFalse(capabilities.supportsStreaming, "the base fallback must not claim streaming support it never demonstrated")
        XCTAssertEqual(capabilities.memoryStrategy, .external, "a remote backend's fallback must report .external, not the resident default")
    }

    func test_buildRequest_throws_whenSubclassOmitsOverride() {
        let backend = BareMinimumSSEBackend(
            defaultModelName: "test-model",
            urlSession: URLSession(configuration: .ephemeral),
            payloadHandler: NoOpPayloadHandler()
        )
        XCTAssertThrowsError(
            try backend.buildRequest(
                prompt: "hi",
                systemPrompt: nil,
                config: GenerationConfig(),
                hints: GenerationRuntimeHints()
            )
        ) { error in
            guard case CloudBackendError.missingRequiredOverride = error else {
                XCTFail("Expected CloudBackendError.missingRequiredOverride but got \(error)")
                return
            }
        }
    }
}

/// Deliberately omits both `capabilities` and `buildRequest` overrides —
/// the exact shape of a third-party subclass that forgot to implement them.
private final class BareMinimumSSEBackend: SSECloudBackend, @unchecked Sendable {}

private struct NoOpPayloadHandler: SSEPayloadHandler {
    func extractToken(from payload: String) -> String? { nil }
    func extractEvents(from payload: String) -> [GenerationEvent] { [] }
    func extractUsage(from payload: String) -> (promptTokens: Int?, completionTokens: Int?)? { nil }
    func isStreamEnd(_ payload: String) -> Bool { false }
    func extractStreamError(from payload: String) -> Error? { nil }
}
