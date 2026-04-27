#if canImport(FoundationModels)
import Foundation
import BaseChatBackends
import BaseChatFuzz
import BaseChatInference

/// `FuzzBackendFactory` conformance that instantiates `FoundationBackend`.
///
/// The Apple Intelligence system model is always resident — no model file is needed.
/// Throws `FuzzBackendFactoryError` when Apple Intelligence is unavailable, which
/// callers surface as an early-exit error rather than letting the campaign run
/// 0 iterations silently.
///
/// Requires macOS 26 / iOS 26. Call sites must be guarded with
/// `#available(macOS 26, iOS 26, *)`.
@available(macOS 26, iOS 26, *)
public struct FoundationFuzzFactory: FuzzBackendFactory {
    public init() {}

    public var supportsDeterministicReplay: Bool { true }

    public func makeHandle() async throws -> FuzzRunner.BackendHandle {
        guard FoundationBackend.isAvailable else {
            throw FuzzBackendFactoryError(
                "Apple Intelligence is not available. "
                    + "Enable it in Settings > Apple Intelligence & Siri."
            )
        }
        let backend = FoundationBackend()
        let modelURL = URL(string: "foundation:system")!
        try await backend.loadModel(from: modelURL, plan: .systemManaged(requestedContextSize: 0))
        return FuzzRunner.BackendHandle(
            backend: backend,
            modelId: "apple-intelligence",
            modelURL: modelURL,
            backendName: "foundation",
            templateMarkers: nil
        )
    }
}
#endif
