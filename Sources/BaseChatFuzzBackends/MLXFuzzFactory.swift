#if MLX
import Foundation
import BaseChatBackends
import BaseChatFuzz
import BaseChatInference
import BaseChatTestSupport

/// `FuzzBackendFactory` conformance that instantiates `MLXBackend` from a local
/// safetensors directory.
///
/// `MLX_TEST_MODEL` (or an explicit `modelHint`) can pin a specific snapshot by
/// directory name. The factory remains library-based so the XCTest host can run
/// under Xcode while sharing the same backend wiring as the CLI-backed fuzz paths.
public struct MLXFuzzFactory: FuzzBackendFactory {
    public let modelHint: String?
    public let environment: [String: String]

    public init(
        modelHint: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.modelHint = modelHint
        self.environment = environment
    }

    public var supportsDeterministicReplay: Bool { true }

    @MainActor
    public func makeHandle() async throws -> FuzzRunner.BackendHandle {
        guard let modelURL = HardwareRequirements.findMLXModelDirectory(
            nameContains: modelHint,
            environment: environment
        ) else {
            throw FuzzBackendFactoryError(
                "No MLX model found in ~/Documents/Models/. "
                    + "Set MLX_TEST_MODEL=<name> to pin a specific snapshot, or download a safetensors model to run MLX fuzz tests."
            )
        }
        let backend = MLXBackend()
        try await backend.loadModel(
            from: modelURL,
            plan: .testStub(effectiveContextSize: 4096)
        )
        return FuzzRunner.BackendHandle(
            backend: backend,
            modelId: modelURL.lastPathComponent,
            modelURL: modelURL,
            backendName: "mlx",
            templateMarkers: nil
        )
    }
}
#endif
