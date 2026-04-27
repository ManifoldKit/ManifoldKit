#if Ollama
import Foundation
import BaseChatBackends
import BaseChatFuzz
import BaseChatInference
import BaseChatTestSupport

/// `FuzzBackendFactory` conformance that instantiates a fresh `OllamaBackend`
/// configured against a local Ollama server.
///
/// When used directly, the factory honours the existing
/// `HardwareRequirements.findOllamaModel` selection rules, including the
/// `OLLAMA_TEST_MODEL` environment override. `makeCampaignFactory(modelHint:)`
/// preserves the CLI's rotate-all default when no explicit model hint is given.
public struct OllamaFuzzFactory: FuzzBackendFactory {
    public let modelHint: String?
    public let baseURL: URL
    public let environment: [String: String]

    public init(
        modelHint: String? = nil,
        baseURL: URL = URL(string: "http://localhost:11434")!,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.modelHint = modelHint
        self.baseURL = baseURL
        self.environment = environment
    }

    public func makeHandle() async throws -> FuzzRunner.BackendHandle {
        // Single `/api/tags` round-trip per iteration: select from the
        // already-fetched list rather than re-querying via
        // `HardwareRequirements.findOllamaModel`, which would hit the endpoint
        // again. In rotation mode this halves the per-iteration request count.
        guard let models = HardwareRequirements.listOllamaModels() else {
            throw FuzzBackendFactoryError(
                "No Ollama server reachable at \(baseURL.absoluteString). Start with: ollama serve"
            )
        }
        guard let model = Self.selectModel(from: models, modelHint: modelHint, environment: environment) else {
            throw FuzzBackendFactoryError(
                "No Ollama model installed. Pull one with: ollama pull qwen3.5:4b"
            )
        }
        // FIXME(#714): expected deprecation warning until the next major
        // release flips `Ollama` out of default traits. The fuzz harness
        // is internal infrastructure that exercises the trait-gated init
        // directly.
        let backend = OllamaBackend()
        backend.configure(baseURL: baseURL, modelName: model)
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        let markers = RunRecord.MarkerSnapshot(open: "<think>", close: "</think>")
        return FuzzRunner.BackendHandle(
            backend: backend,
            modelId: model,
            modelURL: URL(string: "ollama:" + model)!,
            backendName: "ollama",
            templateMarkers: markers
        )
    }

    /// Builds the campaign factory the CLI uses for Ollama runs.
    ///
    /// - When `modelHint` is `nil`, empty, or `"all"`: enumerates every installed
    ///   Ollama model, sorts by UTF-8 byte order, and wraps them in a
    ///   `RotatingFuzzFactory` so the runner round-robins one model per
    ///   iteration.
    /// - When `modelHint` names a specific model: returns a single pinned factory
    ///   so callers preserve the pre-rotation behaviour.
    public static func makeCampaignFactory(
        modelHint: String? = nil,
        baseURL: URL = URL(string: "http://localhost:11434")!,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> any FuzzBackendFactory {
        guard let normalizedHint = normalizedModelHint(modelHint) else {
            guard let models = HardwareRequirements.listOllamaModels() else {
                throw FuzzBackendFactoryError(
                    "No Ollama server reachable at \(baseURL.absoluteString). Start with: ollama serve"
                )
            }
            guard !models.isEmpty else {
                throw FuzzBackendFactoryError(
                    "No Ollama model installed. Pull one with: ollama pull qwen3.5:4b"
                )
            }
            let children: [any FuzzBackendFactory] = models.sorted().map {
                OllamaFuzzFactory(modelHint: $0, baseURL: baseURL, environment: environment)
            }
            return RotatingFuzzFactory(children: children)
        }

        return OllamaFuzzFactory(modelHint: normalizedHint, baseURL: baseURL, environment: environment)
    }

    private static func normalizedModelHint(_ modelHint: String?) -> String? {
        guard var modelHint else { return nil }
        modelHint = modelHint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelHint.isEmpty else { return nil }
        guard modelHint.lowercased() != "all" else { return nil }
        return modelHint
    }

    /// Selects an Ollama model from a pre-fetched name list, applying the same
    /// precedence as the per-call helpers in `HardwareRequirements`:
    /// 1. explicit `modelHint` (substring match, case-insensitive)
    /// 2. `OLLAMA_TEST_MODEL` env override (substring match)
    /// 3. first model in the list (rotation deterministically pins one model
    ///    per child factory, so `models.first` is the desired pinned name)
    static func selectModel(
        from models: [String],
        modelHint: String?,
        environment: [String: String]
    ) -> String? {
        if let hint = normalizedModelHint(modelHint),
           let match = matchModel(in: models, query: hint) {
            return match
        }
        if let override = normalizedModelHint(environment["OLLAMA_TEST_MODEL"]),
           let match = matchModel(in: models, query: override) {
            return match
        }
        return models.first
    }

    private static func matchModel(in models: [String], query: String) -> String? {
        if let exact = models.first(where: { $0.caseInsensitiveCompare(query) == .orderedSame }) {
            return exact
        }
        let lowered = query.lowercased()
        return models.first { $0.lowercased().contains(lowered) }
    }
}
#endif
