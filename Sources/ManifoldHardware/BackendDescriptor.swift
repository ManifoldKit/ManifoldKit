import Foundation
import os

// MARK: - Descriptor protocols
//
// A *descriptor* bundles the static, display-layer metadata for a backend
// family so callers can look things up by identity without exhaustive `switch`
// statements. The existing `ModelType` and `APIProvider` enums remain the
// canonical identifiers for persistence and `Codable`; descriptors are an
// additive overlay, not a replacement.
//
// Design constraints driving these choices:
//
// 1. **No actor isolation on the descriptor itself.** Descriptors are pure
//    value-type metadata read at call sites that span `@MainActor`,
//    `nonisolated`, and `Task.detached` contexts. Forcing `@MainActor` on
//    every property lookup would push isolation errors into callers that have
//    no natural actor. `Sendable` + immutable value types is the right shape.
//
// 2. **Registry is a global but not a mutable singleton.** Built-in
//    descriptors are registered once at module-init time via `static let`.
//    Third-party descriptors extend the registry via a dedicated write-once
//    seam. The registry is protected by `OSAllocatedUnfairLock`, matching
//    the pattern established by `MemoryPressureBroadcaster` in the same module.
//    Available on iOS 16 / macOS 13+, which is well below the iOS 18 / macOS 15
//    deployment floor.
//
// 3. **Enum cases stay.** `APIProvider.rawValue` and `ModelType` are persisted
//    in SwiftData `providerRawValue: String` (ManifoldSchemaV3/V4). Third-party
//    providers that need persistence register a `providerID` that goes into
//    `providerRawValue` and decode via the `unknown(_:)` escape hatch (not
//    in scope for this spike — noted in the plan).

/// Static metadata a cloud-provider backend needs to surface to routing,
/// display, and capability layers without owning any mutable state.
public struct CloudProviderDescriptor: Sendable {

    /// The stable identifier. For built-ins this equals `APIProvider.rawValue`.
    /// Third-party providers choose a unique reverse-DNS string
    /// (e.g. `"com.example.groq"`).
    public let providerID: String

    /// Human-readable display name (used in UI pickers and log labels).
    public let displayName: String

    /// The canonical `BackendName`-compatible engine label emitted in load-event
    /// logs and surfaced as `InferenceService.activeBackendName`.
    ///
    /// This is an **identity** string, not a display string (Wave 2 A1): for
    /// providers with a `BackendName` case it is that case's raw value; for the
    /// rest it is the stable `APIProvider` code (`"openAIResponses"`,
    /// `"lmStudio"`, `"custom"`). When omitted it falls back to `providerID`.
    /// Use `displayName` for anything a person reads.
    public let engineLabel: String

    /// Default base URL for the provider's API.
    public let defaultBaseURL: String

    /// Whether this provider requires an API key.
    public let requiresAPIKey: Bool

    /// Default model name seeded when creating a new endpoint record.
    public let defaultModelName: String

    /// UI / registration ordering weight. Lower values appear first in
    /// `orderedCloudProviders`. Built-in providers use the values 0–5 to
    /// preserve their existing documented order.
    public let sortOrder: Int

    public init(
        providerID: String,
        displayName: String,
        engineLabel: String? = nil,
        defaultBaseURL: String,
        requiresAPIKey: Bool,
        defaultModelName: String,
        sortOrder: Int
    ) {
        self.providerID = providerID
        self.displayName = displayName
        // Identity fallback: engineLabel feeds activeBackendName, so the
        // stable providerID — not the display label — is the right default.
        self.engineLabel = engineLabel ?? providerID
        self.defaultBaseURL = defaultBaseURL
        self.requiresAPIKey = requiresAPIKey
        self.defaultModelName = defaultModelName
        self.sortOrder = sortOrder
    }
}

/// Static metadata for a local (on-device) model format backend.
public struct LocalModelDescriptor: Sendable {

    /// The `ModelType` this descriptor extends. Remains the canonical identity
    /// key for persistence and routing; the descriptor is an overlay.
    public let modelType: ModelType

    /// Short label used in accessibility strings and log events.
    public let backendLabel: String

    /// The canonical `BackendName`-compatible engine label emitted in load-event
    /// logs.
    public let engineLabel: String

    /// File extension (or directory convention) associated with this format.
    /// Used for display and validation; not authoritative for routing.
    public let formatHint: String

    /// Whether models of this type can be downloaded via the HuggingFace flow.
    public let isDownloadable: Bool

    /// UI / tab ordering weight. Lower values appear first in type-sorted lists.
    /// Built-in types use 0 (foundation), 1 (gguf), 2 (mlx) to match the
    /// documented tab order in `ModelSelectionTabView`.
    public let sortOrder: Int

    public init(
        modelType: ModelType,
        backendLabel: String,
        engineLabel: String,
        formatHint: String,
        isDownloadable: Bool,
        sortOrder: Int
    ) {
        self.modelType = modelType
        self.backendLabel = backendLabel
        self.engineLabel = engineLabel
        self.formatHint = formatHint
        self.isDownloadable = isDownloadable
        self.sortOrder = sortOrder
    }
}

// MARK: - Registry

/// A read-mostly registry of backend descriptors that replaces the
/// exhaustive `switch` statements on `ModelType` and `APIProvider`.
///
/// Built-in descriptors are registered at declaration time. Third-party
/// packages register additional descriptors before calling
/// `DefaultBackends.register(with:)`.
///
/// Thread safety: protected by a `Mutex`. All writes happen during the
/// app's single-threaded startup sequence (before any concurrent access
/// from the generation queue or UI), but the lock guards against edge
/// cases in test environments where registration races are possible.
public struct BackendDescriptorRegistry: Sendable {

    // MARK: - Shared instance

    public static let shared = BackendDescriptorRegistry()

    // MARK: - Storage

    private struct RegistryState {
        var cloudProviders: [String: CloudProviderDescriptor] = [:]
        var localModels: [ModelType: LocalModelDescriptor] = [:]
    }

    private let lock: OSAllocatedUnfairLock<RegistryState>

    init() {
        var initial = RegistryState()
        // Register built-ins eagerly so the registry is usable before
        // any explicit registration call. This mirrors how `CompiledBackends.current`
        // is lazily-but-automatically available.
        for d in CloudProviderDescriptor.builtIns {
            initial.cloudProviders[d.providerID] = d
        }
        for d in LocalModelDescriptor.builtIns {
            initial.localModels[d.modelType] = d
        }
        lock = OSAllocatedUnfairLock(initialState: initial)
    }

    // MARK: - Cloud provider lookup

    /// Returns the descriptor for the built-in `APIProvider`, or `nil` for
    /// unknown / unregistered providers.
    public func descriptor(for provider: APIProvider) -> CloudProviderDescriptor? {
        lock.withLock { $0.cloudProviders[provider.rawValue] }
    }

    /// Returns all registered cloud providers sorted by `sortOrder`.
    public var allCloudProviders: [CloudProviderDescriptor] {
        lock.withLock { $0.cloudProviders.values.sorted { $0.sortOrder < $1.sortOrder } }
    }

    // MARK: - Local model lookup

    /// Returns the descriptor for the given `ModelType`.
    public func descriptor(for modelType: ModelType) -> LocalModelDescriptor? {
        lock.withLock { $0.localModels[modelType] }
    }

    // MARK: - Registration (third-party extension point)

    /// Registers a third-party cloud provider descriptor.
    ///
    /// Call this before `DefaultBackends.register(with:)`. Registration is
    /// idempotent — re-registering the same `providerID` overwrites the
    /// previous entry.
    public func register(_ descriptor: CloudProviderDescriptor) {
        lock.withLock { $0.cloudProviders[descriptor.providerID] = descriptor }
    }

    /// Registers a third-party local model descriptor.
    public func register(_ descriptor: LocalModelDescriptor) {
        lock.withLock { $0.localModels[descriptor.modelType] = descriptor }
    }
}

// MARK: - Built-in descriptors

extension CloudProviderDescriptor {
    /// The descriptors for all built-in `APIProvider` cases, in their
    /// documented registration/display order (matching
    /// `CompiledBackends.orderedCloudProviders`).
    public static let builtIns: [CloudProviderDescriptor] = [
        CloudProviderDescriptor(
            providerID: APIProvider.claude.rawValue,
            displayName: "Claude",
            engineLabel: "claude",
            defaultBaseURL: "https://api.anthropic.com",
            requiresAPIKey: true,
            defaultModelName: "claude-sonnet-4-6",
            sortOrder: 0
        ),
        CloudProviderDescriptor(
            providerID: APIProvider.openAI.rawValue,
            displayName: "OpenAI",
            engineLabel: "openAI",
            defaultBaseURL: "https://api.openai.com",
            requiresAPIKey: true,
            defaultModelName: "gpt-4o-mini",
            sortOrder: 1
        ),
        CloudProviderDescriptor(
            providerID: APIProvider.openAIResponses.rawValue,
            displayName: "OpenAI Responses",
            engineLabel: "openAIResponses",
            defaultBaseURL: "https://api.openai.com",
            requiresAPIKey: true,
            defaultModelName: "gpt-5",
            sortOrder: 2
        ),
        CloudProviderDescriptor(
            providerID: APIProvider.lmStudio.rawValue,
            displayName: "LM Studio",
            engineLabel: "lmStudio",
            defaultBaseURL: "http://localhost:1234",
            requiresAPIKey: false,
            defaultModelName: "local-model",
            sortOrder: 3
        ),
        CloudProviderDescriptor(
            providerID: APIProvider.custom.rawValue,
            displayName: "Custom",
            engineLabel: "custom",
            defaultBaseURL: "https://",
            requiresAPIKey: true,
            defaultModelName: "model",
            sortOrder: 4
        ),
        CloudProviderDescriptor(
            providerID: APIProvider.ollama.rawValue,
            displayName: "Ollama",
            engineLabel: "ollama",
            defaultBaseURL: "http://localhost:11434",
            requiresAPIKey: false,
            defaultModelName: "llama3.2",
            sortOrder: 5
        ),
    ]
}

extension LocalModelDescriptor {
    /// The descriptors for all built-in `ModelType` cases.
    public static let builtIns: [LocalModelDescriptor] = [
        LocalModelDescriptor(
            modelType: .gguf,
            backendLabel: "GGUF",
            engineLabel: "llama",
            formatHint: ".gguf",
            isDownloadable: true,
            sortOrder: 1
        ),
        LocalModelDescriptor(
            modelType: .mlx,
            backendLabel: "MLX",
            engineLabel: "mlx",
            formatHint: "config.json",
            isDownloadable: true,
            sortOrder: 2
        ),
        LocalModelDescriptor(
            modelType: .foundation,
            backendLabel: "Apple",
            engineLabel: "foundation",
            formatHint: "built-in",
            isDownloadable: false,
            sortOrder: 0
        ),
    ]
}
