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
@MainActor
public final class BaseChatRuntime {

    /// Minimal bootstrap lifecycle contract for runtime assembly.
    public enum Event: Sendable, Equatable {
        case configurationInstalled(bundleIdentifier: String)
        case inferenceServiceReady
        case modelContainerReady
        case persistenceReady
        case runtimeReady
    }

    public typealias EventHandler = @MainActor (Event) -> Void

    public let inferenceService: InferenceService
    public let diagnostics: DiagnosticsService
    public let modelContainer: ModelContainer
    public let persistence: SwiftDataPersistenceProvider

    public var modelContext: ModelContext { modelContainer.mainContext }

    public init(
        configuration: BaseChatConfiguration,
        inferenceService: InferenceService? = nil,
        diagnostics: DiagnosticsService = DiagnosticsService(),
        makeModelContainer: @MainActor () throws -> ModelContainer = { try ModelContainerFactory.makeContainer() },
        onEvent: EventHandler? = nil
    ) throws {
        // Capture the previous configuration before any mutation so a failure
        // partway through bootstrap leaves `BaseChatConfiguration.shared`
        // untouched from the caller's perspective.
        let previousConfiguration = BaseChatConfiguration.shared

        do {
            BaseChatConfiguration.shared = configuration
            onEvent?(.configurationInstalled(bundleIdentifier: configuration.bundleIdentifier))

            let resolvedInferenceService = inferenceService ?? InferenceService()
            self.inferenceService = resolvedInferenceService
            onEvent?(.inferenceServiceReady)

            let resolvedModelContainer = try makeModelContainer()
            self.modelContainer = resolvedModelContainer
            onEvent?(.modelContainerReady)

            self.diagnostics = diagnostics
            self.persistence = SwiftDataPersistenceProvider(modelContext: resolvedModelContainer.mainContext)
            onEvent?(.persistenceReady)
            onEvent?(.runtimeReady)
        } catch {
            BaseChatConfiguration.shared = previousConfiguration
            throw error
        }
    }
}
