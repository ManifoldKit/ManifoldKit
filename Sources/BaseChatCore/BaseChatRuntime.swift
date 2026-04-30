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
/// ``BaseChatRuntime`` is the SwiftData-backed bootstrap. Adopters using
/// custom ``SessionStore`` / ``MessageStore`` impls should construct
/// ``ChatViewModel`` / ``SessionManagerViewModel`` directly and call
/// `configure(persistence:)` — runtime support for custom stores is tracked
/// separately.
///
/// ### Splash-screen progress
///
/// Call ``build(configuration:inferenceService:diagnostics:makeModelContainer:)``
/// instead of `init` when you want to drive a launch progress UI. That factory
/// returns an `AsyncStream<RuntimeBootstrapMilestone>` you can iterate on the
/// main actor while bootstrap runs concurrently in a sibling task:
///
/// ```swift
/// let (milestones, runtimeTask) = BaseChatRuntime.build(configuration: config)
/// for await milestone in milestones {
///     splashProgress = milestone.fractionComplete
/// }
/// runtime = try await runtimeTask.value
/// ```
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

    // MARK: - Internal memberwise init (used by `build`)

    internal init(
        inferenceService: InferenceService,
        diagnostics: DiagnosticsService,
        modelContainer: ModelContainer,
        persistence: SwiftDataPersistenceProvider,
        samplerPresetStore: SwiftDataSamplerPresetStore,
        benchmarkCache: SwiftDataBenchmarkCache,
        endpointStore: SwiftDataEndpointStore
    ) {
        self.inferenceService = inferenceService
        self.diagnostics = diagnostics
        self.modelContainer = modelContainer
        self.persistence = persistence
        self.samplerPresetStore = samplerPresetStore
        self.benchmarkCache = benchmarkCache
        self.endpointStore = endpointStore
    }

    // MARK: - Progress-reporting factory

    /// Starts runtime bootstrap and returns both a milestone stream and an
    /// in-flight task — without blocking the caller.
    ///
    /// Because the stream consumer and the bootstrap task share the main-actor
    /// executor, the `await Task.yield()` calls inside the task cooperatively
    /// interleave with the consumer, so UI updates happen between phases rather
    /// than all at once after bootstrap finishes.
    ///
    /// - Parameters:
    ///   - configuration: The ``BaseChatConfiguration`` to install globally.
    ///   - inferenceService: An existing ``InferenceService`` to reuse. Pass
    ///     `nil` (the default) to let the runtime create one.
    ///   - diagnostics: The ``DiagnosticsService`` the runtime should use.
    ///   - makeModelContainer: A closure that creates the `ModelContainer`.
    ///     Runs on the main actor. Defaults to the framework's standard schema.
    /// - Returns: A tuple of:
    ///   - `progress`: An `AsyncStream<RuntimeBootstrapMilestone>` that emits
    ///     one value per phase and finishes when bootstrap completes or throws.
    ///   - `task`: A `Task` whose `value` is the fully-bootstrapped runtime.
    ///     `await task.value` after draining `progress` to obtain the runtime.
    ///
    /// Typical splash-screen usage from a SwiftUI `.task { }` modifier:
    /// ```swift
    /// let (milestones, runtimeTask) = BaseChatRuntime.build(configuration: config)
    /// for await milestone in milestones {
    ///     splashProgress = milestone.fractionComplete
    /// }
    /// runtime = try await runtimeTask.value
    /// ```
    ///
    /// If `makeModelContainer` throws, the stream finishes immediately,
    /// ``BaseChatConfiguration/shared`` is restored to its pre-call value,
    /// and `runtimeTask` rethrows the error.
    public static func build(
        configuration: BaseChatConfiguration,
        inferenceService: InferenceService? = nil,
        diagnostics: DiagnosticsService = DiagnosticsService(),
        makeModelContainer: @MainActor @escaping () throws -> ModelContainer = { try ModelContainerFactory.makeContainer() }
    ) -> (progress: AsyncStream<RuntimeBootstrapMilestone>, task: Task<BaseChatRuntime, any Error>) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: RuntimeBootstrapMilestone.self,
            bufferingPolicy: .unbounded
        )

        let task = Task { @MainActor [continuation] in
            defer { continuation.finish() }

            let previousConfiguration = BaseChatConfiguration.shared
            do {
                continuation.yield(.installingConfiguration)
                BaseChatConfiguration.shared = configuration
                await Task.yield()

                continuation.yield(.resolvingInferenceService)
                let resolvedService = inferenceService ?? InferenceService()
                await Task.yield()

                continuation.yield(.buildingModelContainer)
                let container = try makeModelContainer()
                await Task.yield()

                continuation.yield(.wiringPersistence)
                let mainContext = container.mainContext
                let persistence = SwiftDataPersistenceProvider(modelContext: mainContext)
                let samplerPresetStore = SwiftDataSamplerPresetStore(modelContext: mainContext)
                let benchmarkCache = SwiftDataBenchmarkCache(modelContext: mainContext)
                let endpointStore = SwiftDataEndpointStore(modelContext: mainContext)
                await Task.yield()

                continuation.yield(.complete)

                return BaseChatRuntime(
                    inferenceService: resolvedService,
                    diagnostics: diagnostics,
                    modelContainer: container,
                    persistence: persistence,
                    samplerPresetStore: samplerPresetStore,
                    benchmarkCache: benchmarkCache,
                    endpointStore: endpointStore
                )
            } catch {
                BaseChatConfiguration.shared = previousConfiguration
                throw error
            }
        }

        return (stream, task)
    }
}
