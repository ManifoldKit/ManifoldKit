#if Server
import ArgumentParser
import ManifoldBackends
import ManifoldInference
import Foundation

internal enum ServerBackendKind: String, CaseIterable, ExpressibleByArgument, Equatable, Sendable {
    case mlx
    case llama
    case foundation
    case ollama
    case cloud
}

internal struct ServerBackendSelection: Equatable, Sendable {
    internal var backend: ServerBackendKind
    internal var model: String?
    internal var modelPath: String?
    internal var ollamaBaseURL: String

    internal init(
        backend: ServerBackendKind,
        model: String? = nil,
        modelPath: String? = nil,
        ollamaBaseURL: String = APIProvider.ollama.defaultBaseURL
    ) {
        self.backend = backend
        self.model = model
        self.modelPath = modelPath
        self.ollamaBaseURL = ollamaBaseURL
    }

    internal func validate(compiledBackends: CompiledBackends = DefaultBackends.compiledBackends) throws {
        switch backend {
        case .mlx:
            try requireLocal(.mlx, compiledBackends: compiledBackends)
            guard modelPath != nil || model != nil else {
                throw ServerError.invalidConfiguration("MLX backend requires --model-path for a local snapshot or --model for a model identifier.")
            }
        case .llama:
            try requireLocal(.gguf, compiledBackends: compiledBackends)
            guard modelPath != nil else {
                throw ServerError.invalidConfiguration("Llama backend requires --model-path pointing to a .gguf file.")
            }
        case .foundation:
            try requireLocal(.foundation, compiledBackends: compiledBackends)
        case .ollama:
            try requireProvider(.ollama, compiledBackends: compiledBackends)
            guard URL(string: ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else {
                throw ServerError.invalidConfiguration("--ollama-base-url must be a valid URL.")
            }
        case .cloud:
            throw ServerError.notImplemented("Cloud SaaS backend loading is not implemented for ManifoldServer v1; use mlx, llama, foundation, or ollama.")
        }
    }

    private func requireLocal(_ modelType: ModelType, compiledBackends: CompiledBackends) throws {
        let compatibility = compiledBackends.compatibility(for: modelType)
        guard compatibility.isSupported else {
            throw ServerError.backendUnavailable(compatibility.unavailableReason ?? "Backend is not available in this build.")
        }
    }

    private func requireProvider(_ provider: APIProvider, compiledBackends: CompiledBackends) throws {
        let compatibility = compiledBackends.compatibility(for: provider)
        guard compatibility.isSupported else {
            throw ServerError.backendUnavailable(compatibility.unavailableReason ?? "Backend is not available in this build.")
        }
    }
}

internal actor TraitAwareServerBackendProvider: ServerBackendProvider {
    internal let selection: ServerBackendSelection
    internal let compiledBackends: CompiledBackends
    private var cachedBackend: (any InferenceBackend)?
    private var loadedModelID: String?

    internal init(
        selection: ServerBackendSelection,
        compiledBackends: CompiledBackends = DefaultBackends.compiledBackends,
        loadedModelID: String? = nil
    ) {
        self.selection = selection
        self.compiledBackends = compiledBackends
        self.loadedModelID = loadedModelID
    }

    internal func listModels() async throws -> [String] {
        let configuredModels: [String] = switch selection.backend {
        case .foundation:
            [ModelInfo.builtInFoundation.name]
        case .ollama:
            [selection.model ?? APIProvider.ollama.defaultModelName]
        case .cloud, .mlx, .llama:
            [selection.model, selection.modelPath].compactMap { $0 }
        }

        guard let loadedModelID, !configuredModels.contains(loadedModelID) else {
            return configuredModels
        }
        return [loadedModelID] + configuredModels
    }

    internal func listModelRecords() async throws -> [ModelsListResponse.Model] {
        let currentModelID = loadedModelID ?? modelID(for: ServerBackendRequest())
        return try await listModels().map { id in
            let isCurrent = currentModelID == id
            return ModelsListResponse.Model(
                id: id,
                status: loadedModelID == id ? "loaded" : "available",
                backend: selection.backend.rawValue,
                source: modelSource,
                current: isCurrent
            )
        }
    }

    internal func backend(for request: ServerBackendRequest) async throws -> any InferenceBackend {
        if let cached = cachedBackend {
            return cached
        }

        try selection.validate(compiledBackends: compiledBackends)

        let backend: any InferenceBackend
        switch selection.backend {
        case .mlx:
            backend = try await loadMLXBackend(modelOverride: request.model)
        case .llama:
            backend = try await loadLlamaBackend()
        case .foundation:
            backend = try await loadFoundationBackend()
        case .ollama:
            backend = try await loadOllamaBackend(modelOverride: request.model)
        case .cloud:
            throw ServerError.notImplemented("Cloud SaaS backend loading is not implemented for ManifoldServer v1; configure a local or self-hosted backend instead.")
        }
        cachedBackend = backend
        loadedModelID = modelID(for: request)
        return backend
    }

    private var modelSource: String {
        switch selection.backend {
        case .foundation:
            return "built_in"
        case .mlx, .llama:
            return selection.modelPath == nil ? "remote_identifier" : "local_path"
        case .ollama, .cloud:
            return "remote_endpoint"
        }
    }

    internal func modelID(for request: ServerBackendRequest) -> String? {
        switch selection.backend {
        case .foundation:
            return ModelInfo.builtInFoundation.name
        case .mlx:
            return selection.modelPath ?? request.model ?? selection.model
        case .ollama:
            return request.model ?? selection.model ?? APIProvider.ollama.defaultModelName
        case .llama:
            return selection.modelPath
        case .cloud:
            return selection.model
        }
    }

    private func loadMLXBackend(modelOverride: String?) async throws -> any InferenceBackend {
        #if MLX
        let rawPath = selection.modelPath ?? modelOverride ?? selection.model
        guard let rawPath else {
            throw ServerError.invalidConfiguration("MLX backend requires --model-path for a local snapshot or --model for a model identifier.")
        }
        let url = URL(fileURLWithPath: rawPath).standardizedFileURL
        guard let modelInfo = ModelInfo(mlxDirectory: url) else {
            throw ServerError.invalidConfiguration("MLX model path must be a directory containing config.json and .safetensors files: \(url.path)")
        }
        let backend = MLXBackend()
        let plan = ModelLoadPlan.compute(for: modelInfo, requestedContextSize: 4096, strategy: backend.capabilities.memoryStrategy)
        guard plan.verdict != .deny else {
            throw ServerError.invalidConfiguration("MLX model does not fit available memory at the requested context size.")
        }
        try await backend.loadModel(from: modelInfo.url, plan: plan)
        return backend
        #else
        throw ServerError.backendUnavailable("MLX models require the MLX trait in this build.")
        #endif
    }

    private func loadLlamaBackend() async throws -> any InferenceBackend {
        #if Llama
        guard let rawPath = selection.modelPath else {
            throw ServerError.invalidConfiguration("Llama backend requires --model-path pointing to a .gguf file.")
        }
        let url = URL(fileURLWithPath: rawPath).standardizedFileURL
        guard let modelInfo = ModelInfo(ggufURL: url) else {
            throw ServerError.invalidConfiguration("Llama model path must point to a valid .gguf file: \(url.path)")
        }
        let backend = LlamaBackend()
        let plan = ModelLoadPlan.compute(for: modelInfo, requestedContextSize: 4096, strategy: backend.capabilities.memoryStrategy)
        guard plan.verdict != .deny else {
            throw ServerError.invalidConfiguration("GGUF model does not fit available memory at the requested context size.")
        }
        try await backend.loadModel(from: modelInfo.url, plan: plan)
        return backend
        #else
        throw ServerError.backendUnavailable("GGUF models require the Llama trait in this build.")
        #endif
    }

    private func loadFoundationBackend() async throws -> any InferenceBackend {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            let backend = FoundationBackend()
            try await backend.loadModel(from: ModelInfo.builtInFoundation.url, plan: .cloud())
            return backend
        }
        #endif
        throw ServerError.backendUnavailable("Apple Foundation Models require iOS 26 / macOS 26 or later.")
    }

    private func loadOllamaBackend(modelOverride: String?) async throws -> any InferenceBackend {
        #if Ollama
        let modelName = modelOverride ?? selection.model ?? APIProvider.ollama.defaultModelName
        guard let baseURL = URL(string: selection.ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ServerError.invalidConfiguration("--ollama-base-url must be a valid URL.")
        }
        let backend = OllamaBackend(_registrar: ())
        backend.configure(baseURL: baseURL, modelName: modelName)
        try await backend.loadModel(from: baseURL, plan: .cloud(requestedContextSize: 8192))
        return backend
        #else
        throw ServerError.backendUnavailable("Ollama endpoints require the Ollama trait in this build.")
        #endif
    }
}

#endif
