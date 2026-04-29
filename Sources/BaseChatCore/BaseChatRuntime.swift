import Foundation
import SwiftData
import BaseChatInference

/// Preferred bootstrap surface for host apps that use BaseChatKit's shipped
/// SwiftData persistence.
///
/// ``BaseChatRuntime`` installs ``BaseChatConfiguration/shared`` first, then
/// builds the shared inference, persistence, and diagnostics services in a
/// fixed order so consumer apps do not have to manually coordinate those
/// steps.
///
/// Apps that need a custom ``InferenceService`` configuration (for example a
/// `ToolRegistry` or approval gate) can construct that service first and pass
/// it in. The runtime will keep using the exact instance supplied.
///
/// ``BaseChatRuntime`` is the SwiftData-backed bootstrap. Adopters using a
/// custom ``ChatPersistenceProvider`` should construct ``ChatViewModel`` /
/// ``SessionManagerViewModel`` directly and call `configure(persistence:)` —
/// runtime support for custom providers is tracked separately.
///
/// Adopters needing fine-grained progress signals during bootstrap (e.g. splash-screen UI,
/// per-phase analytics) should construct the runtime on a background task and observe its
/// returned properties; an `AsyncSequence` of bootstrap milestones is tracked in #872.
@MainActor
public final class BaseChatRuntime {

    public let inferenceService: InferenceService
    public let diagnostics: DiagnosticsService
    public let modelContainer: ModelContainer
    public let persistence: SwiftDataPersistenceProvider
    public let samplerPresetStore: SwiftDataSamplerPresetStore
    public let benchmarkCache: SwiftDataBenchmarkCache
    public let endpointStore: SwiftDataEndpointStore

    public var modelContext: ModelContext { modelContainer.mainContext }

    public init(
        configuration: BaseChatConfiguration,
        inferenceService: InferenceService? = nil,
        diagnostics: DiagnosticsService = DiagnosticsService(),
        makeModelContainer: @MainActor () throws -> ModelContainer = { try ModelContainerFactory.makeContainer() }
    ) throws {
        // Capture the previous configuration before any mutation so a failure
        // partway through bootstrap leaves `BaseChatConfiguration.shared`
        // untouched from the caller's perspective.
        let previousConfiguration = BaseChatConfiguration.shared

        do {
            BaseChatConfiguration.shared = configuration

            let resolvedInferenceService = inferenceService ?? InferenceService()
            self.inferenceService = resolvedInferenceService

            let resolvedModelContainer = try makeModelContainer()
            self.modelContainer = resolvedModelContainer

            self.diagnostics = diagnostics
            let mainContext = resolvedModelContainer.mainContext
            self.persistence = SwiftDataPersistenceProvider(modelContext: mainContext)
            self.samplerPresetStore = SwiftDataSamplerPresetStore(modelContext: mainContext)
            self.benchmarkCache = SwiftDataBenchmarkCache(modelContext: mainContext)
            self.endpointStore = SwiftDataEndpointStore(modelContext: mainContext)
        } catch {
            BaseChatConfiguration.shared = previousConfiguration
            throw error
        }
    }
}
