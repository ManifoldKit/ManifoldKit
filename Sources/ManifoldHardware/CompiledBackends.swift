import Foundation

/// Inference traits that materially change which backends a build can expose at
/// runtime.
///
/// `.ollama` and `.cloudSaaS` are retained for Codable stability but are no
/// longer SwiftPM traits: since v0.48 the cloud families compile
/// unconditionally, so both members are always present in
/// ``CompiledBackends/current``.
public enum BackendBuildTrait: String, CaseIterable, Codable, Hashable, Sendable {
    case mlx = "MLX"
    case llama = "Llama"
    case huggingFace = "HuggingFace"
    case ollama = "Ollama"
    case cloudSaaS = "CloudSaaS"
}

/// The network/profile posture of the current build.
///
/// Since v0.48 the cloud families compile unconditionally, so
/// ``CompiledBackends/current`` always reports `.full`. The other cases
/// remain for hand-constructed ``CompiledBackends`` values (tests,
/// ManifoldServer's injectable provider) and Codable stability. Excluding
/// cloud code from a shipped binary is now a *link-time* decision — depend
/// on the products you want (see docs/FIPS.md) — not a compile flag.
public enum BackendBuildProfile: String, CaseIterable, Codable, Sendable {
    /// No networked inference backends are compiled in.
    case offline

    /// Self-hosted / private-datacenter inference is compiled in via `Ollama`.
    case selfHosted

    /// SaaS providers are compiled in via `CloudSaaS`.
    case saas

    /// Both self-hosted and SaaS providers are compiled in.
    case full
}

/// Describes which inference backends are compiled into the current binary
/// before anything is registered on an `InferenceService`.
///
/// Use this when a host app needs to decide what UI to present at startup
/// (e.g. whether to show a model-download flow or cloud-endpoint settings)
/// without importing `ManifoldBackends` or constructing backend instances.
public struct CompiledBackends: Sendable, Equatable {

    /// The current binary's network/build profile.
    public let buildProfile: BackendBuildProfile

    /// Inference traits compiled into this binary.
    public let traits: Set<BackendBuildTrait>

    /// Local model types this build can load when registered.
    public let localModelTypes: Set<ModelType>

    /// Cloud / remote API providers this build can load when registered.
    public let cloudProviders: Set<APIProvider>

    public init(
        buildProfile: BackendBuildProfile,
        traits: Set<BackendBuildTrait>,
        localModelTypes: Set<ModelType>,
        cloudProviders: Set<APIProvider>
    ) {
        self.buildProfile = buildProfile
        self.traits = traits
        self.localModelTypes = localModelTypes
        self.cloudProviders = cloudProviders
    }

    /// The local model types that have a downloadable artifact flow in the stock UI.
    public var downloadableModelTypes: Set<ModelType> {
        localModelTypes.intersection([.gguf, .mlx])
    }

    /// Whether any local inference backend is compiled in.
    public var supportsLocalInference: Bool { !localModelTypes.isEmpty }

    /// Whether any cloud / remote inference backend is compiled in.
    public var supportsCloudInference: Bool { !cloudProviders.isEmpty }

    /// Whether the stock "Download Models" affordance makes sense for this build.
    public var shouldPresentModelDownloads: Bool {
        traits.contains(.huggingFace) && !downloadableModelTypes.isEmpty
    }

    /// Whether the stock "Manage Cloud APIs" affordance makes sense for this build.
    public var shouldPresentCloudAPIManagement: Bool { !cloudProviders.isEmpty }

    /// Providers in the UI / registration order documented by ManifoldKit.
    /// Order is driven by `CloudProviderDescriptor.sortOrder` in
    /// `BackendDescriptorRegistry`, so third-party providers registered with a
    /// `sortOrder` beyond 5 appear after the built-ins.
    public var orderedCloudProviders: [APIProvider] {
        BackendDescriptorRegistry.shared
            .allCloudProviders
            .compactMap { d in APIProvider(rawValue: d.providerID) }
            .filter { cloudProviders.contains($0) }
    }

    /// Returns whether the given local model type is compiled into this build.
    public func compatibility(for modelType: ModelType) -> ModelCompatibilityResult {
        if localModelTypes.contains(modelType) {
            return .supported
        }
        return .unsupported(reason: unavailableReason(for: modelType))
    }

    /// Returns whether the given API provider is compiled into this build.
    public func compatibility(for provider: APIProvider) -> ModelCompatibilityResult {
        if cloudProviders.contains(provider) {
            return .supported
        }
        return .unsupported(reason: unavailableReason(for: provider))
    }

    /// The compiled backend contract for the current binary.
    public static let current = Self.detected()

    private static func detected() -> Self {
        var traits: Set<BackendBuildTrait> = []
        var localModelTypes: Set<ModelType> = []
        var cloudProviders: Set<APIProvider> = []

        #if MLX
        traits.insert(.mlx)
        localModelTypes.insert(.mlx)
        #endif

        #if Llama
        traits.insert(.llama)
        localModelTypes.insert(.gguf)
        #endif

        #if HuggingFace
        traits.insert(.huggingFace)
        #endif

        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            localModelTypes.insert(.foundation)
        }
        #endif

        // Cloud families compile unconditionally since v0.48 (the Ollama and
        // CloudSaaS traits are retired), so they are constant members here.
        // Whether a cloud endpoint is *usable* is a runtime configuration
        // question — see APIEndpointStore / the endpoint editors in UIMM.
        traits.insert(.ollama)
        cloudProviders.insert(.ollama)
        traits.insert(.cloudSaaS)
        cloudProviders.formUnion([.claude, .openAI, .openAIResponses, .lmStudio, .custom])

        return Self(
            buildProfile: buildProfile(for: traits),
            traits: traits,
            localModelTypes: localModelTypes,
            cloudProviders: cloudProviders
        )
    }

    /// Maps a trait set to the corresponding build profile. Exposed at the
    /// `package` level so tests can drive every profile combination without
    /// recompiling under different SwiftPM trait flags.
    package static func buildProfile(for traits: Set<BackendBuildTrait>) -> BackendBuildProfile {
        let hasOllama = traits.contains(.ollama)
        let hasCloudSaaS = traits.contains(.cloudSaaS)

        switch (hasOllama, hasCloudSaaS) {
        case (false, false): return .offline
        case (true, false): return .selfHosted
        case (false, true): return .saas
        case (true, true): return .full
        }
    }

    private func unavailableReason(for modelType: ModelType) -> String {
        switch modelType {
        case .gguf:
            return "GGUF models require the Llama trait in this build."
        case .mlx:
            return "MLX models require the MLX trait in this build."
        case .foundation:
            return "Apple Foundation Models require iOS 26 / macOS 26 or later."
        }
    }

    private func unavailableReason(for provider: APIProvider) -> String {
        switch provider {
        // Unreachable via `CompiledBackends.current` since v0.48 (cloud is
        // always compiled in); still reachable for hand-constructed values.
        case .ollama:
            return "Ollama support is not included in this CompiledBackends value."
        case .openAI, .openAIResponses, .claude, .lmStudio, .custom:
            return "Cloud API support is not included in this CompiledBackends value."
        }
    }
}
