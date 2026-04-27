#if Llama
import Foundation
import BaseChatBackends
import BaseChatFuzz
import BaseChatInference
import BaseChatTestSupport

/// `FuzzBackendFactory` conformance that instantiates `LlamaBackend` against a
/// single GGUF model selected from the local model directories.
///
/// `llama_backend_init` is a process-global one-shot, so this factory always
/// uses one model for the whole campaign. `LLAMA_TEST_MODEL` (or an explicit
/// `modelHint`) can pin a specific GGUF by filename substring; otherwise the
/// first discovered model in deterministic path order is used.
public final class LlamaFuzzFactory: FuzzBackendFactory, @unchecked Sendable {
    private let modelHint: String?
    private let environment: [String: String]
    private var backend: LlamaBackend?

    public init(
        modelHint: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.modelHint = modelHint
        self.environment = environment
    }

    public var supportsDeterministicReplay: Bool { true }

    public func makeHandle() async throws -> FuzzRunner.BackendHandle {
        guard let modelURL = HardwareRequirements.findGGUFModel(
            nameContains: modelHint,
            environment: environment
        ) else {
            throw FuzzBackendFactoryError(
                "No GGUF model found in ~/Documents/Models/. "
                    + "Set LLAMA_TEST_MODEL=<name> to pin a specific file, or download a GGUF model to use --backend llama."
            )
        }
        let backend = LlamaBackend()
        try await backend.loadModel(
            from: modelURL,
            plan: .testStub(effectiveContextSize: 4096)
        )
        self.backend = backend
        return FuzzRunner.BackendHandle(
            backend: backend,
            modelId: modelURL.lastPathComponent,
            modelURL: modelURL,
            backendName: "llama",
            templateMarkers: nil
        )
    }

    public func teardown() async {
        await backend?.unloadAndWait()
    }
}
#endif
