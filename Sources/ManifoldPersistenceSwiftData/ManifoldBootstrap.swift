import Foundation
import SwiftData
import ManifoldRuntime
import ManifoldInference

// MARK: - RAGConfiguration

/// Configuration for the RAG knowledge base.
///
/// Pass to ``ManifoldBootstrap/init(configuration:ragConfiguration:inferenceService:imageGenerationService:diagnostics:makeModelContainer:)``
/// to enable on-device RAG. When `nil`, the runtime runs without retrieval.
///
/// ```swift
/// let rag = RAGConfiguration(embeddingBackend: myLlamaEmbeddingBackend)
/// let bootstrap = try ManifoldBootstrap(configuration: config, ragConfiguration: rag)
/// bootstrap.ragService?.ingest(url: myDocumentURL)
/// ```
public struct RAGConfiguration: Sendable {
    /// Optional embedding backend for semantic search. When `nil`, retrieval
    /// falls back to case-insensitive keyword search.
    public var embeddingBackend: (any EmbeddingBackend)?
    /// Character count per chunk. Default: 1800.
    public var chunkSize: Int
    /// Character overlap between consecutive chunks. Default: 200.
    public var chunkOverlap: Int
    /// Number of chunks to retrieve per turn. Default: 5.
    public var topK: Int
    /// URL for the flat-file vector index. Defaults to
    /// `<Application Support>/<bundleIdentifier>/ragvectors.bin`.
    public var vectorStoreURL: URL?

    public init(
        embeddingBackend: (any EmbeddingBackend)? = nil,
        chunkSize: Int = 1800,
        chunkOverlap: Int = 200,
        topK: Int = 5,
        vectorStoreURL: URL? = nil
    ) {
        self.embeddingBackend = embeddingBackend
        self.chunkSize = chunkSize
        self.chunkOverlap = chunkOverlap
        self.topK = topK
        self.vectorStoreURL = vectorStoreURL
    }
}

/// Preferred bootstrap surface for host apps that use ManifoldKit's shipped
/// SwiftData persistence.
///
/// ``ManifoldBootstrap`` installs ``ManifoldConfiguration/shared`` first, then
/// builds the shared inference, persistence, and diagnostics services in a
/// fixed order so consumer apps do not have to manually coordinate those
/// steps.
///
/// Apps that need a custom ``InferenceService`` configuration (for example a
/// `ToolRegistry` or approval gate) can construct that service first and pass
/// it in. The runtime will keep using the exact instance supplied.
///
/// ``ManifoldBootstrap`` is the SwiftData-backed bootstrap. Adopters using
/// custom ``SessionStore`` / ``MessageStore`` impls should construct
/// ``ChatViewModel`` / ``SessionManagerViewModel`` directly and call
/// `configure(persistence:)` — runtime support for custom stores is tracked
/// separately.
///
/// > Note: This type was named `ManifoldRuntime` prior to the phase-2 target
/// > split. It was renamed to avoid shadowing the `ManifoldRuntime` *target*
/// > (module) name in IDE jump-to-definition and DocC.
///
/// ### Splash-screen progress
///
/// Call ``build(configuration:ragConfiguration:inferenceService:imageGenerationService:diagnostics:sessionToolSources:hookRegistry:makeModelContainer:)``
/// instead of `init` when you want to drive a launch progress UI. That factory
/// returns an `AsyncStream<RuntimeBootstrapMilestone>` you can iterate on the
/// main actor while bootstrap runs concurrently in a sibling task:
///
/// ```swift
/// let (milestones, runtimeTask) = ManifoldBootstrap.build(configuration: config)
/// for await milestone in milestones {
///     splashProgress = milestone.fractionComplete
/// }
/// runtime = try await runtimeTask.value
/// ```
@MainActor
public final class ManifoldBootstrap {

    public let inferenceService: InferenceService
    public let diagnostics: DiagnosticsService
    public let modelContainer: ModelContainer
    public let persistence: SwiftDataPersistenceProvider
    public let samplerPresetStore: SwiftDataSamplerPresetStore
    public let benchmarkCache: SwiftDataBenchmarkCache
    public let endpointStore: SwiftDataEndpointStore
    /// Persists per-turn token counts for all cloud-backed sessions. Host apps
    /// can read aggregated totals via ``usageStore`` to surface cost dashboards.
    public let usageStore: SwiftDataUsageStore
    /// The shared turn-loop runtime, pre-wired against ``persistence`` and
    /// ``inferenceService``. Apps that bootstrap through this type should pass
    /// this instance to ``ChatViewModel/configure(conversationRuntime:)`` (or
    /// rely on ``ChatViewModel/configure(runtime:)``, which does so by
    /// default) to opt into the runtime-driven send/regenerate/edit/cancel
    /// path.
    public let conversationRuntime: ConversationRuntime

    /// The image-generation service, when the host opted in to image generation.
    /// `nil` when ``ManifoldBootstrap`` was constructed without an
    /// `imageGenerationService` parameter.
    public let imageGenerationService: ImageGenerationService?

    /// The image-generation runtime, pre-wired against ``imageGenerationService``
    /// and ``persistence``. Pass to ``ChatViewModel/configure(imageRuntime:)``
    /// to enable image generation in the chat view model.
    /// `nil` when ``imageGenerationService`` is `nil`.
    public let imageRuntime: ImageGenerationRuntime?

    /// The RAG knowledge-base service, when the host opted in via
    /// ``RAGConfiguration``. `nil` when bootstrapped without RAG.
    ///
    /// Call ``RAGService/ingest(url:)`` to add documents and
    /// ``RAGService/deleteDocument(id:)`` to remove them. The service is
    /// automatically queried before each generation turn via
    /// ``ConversationRuntime``.
    public let ragService: RAGService?

    public var modelContext: ModelContext { modelContainer.mainContext }

    /// Builds the full ManifoldKit stack synchronously.
    ///
    /// - Parameter makeModelContainer: Closure producing the SwiftData
    ///   `ModelContainer`. The default derives a per-app on-disk store at
    ///   `<Application Support>/<bundleIdentifier>/store.sqlite` from the
    ///   `configuration` parameter (see
    ///   ``ModelContainerFactory/defaultModelConfiguration()``). Pass an
    ///   explicit closure to use an in-memory store, a custom directory, or to
    ///   migrate an existing app away from the legacy
    ///   `<Application Support>/default.store` path.
    public init(
        configuration: ManifoldConfiguration,
        ragConfiguration: RAGConfiguration? = nil,
        inferenceService: InferenceService? = nil,
        imageGenerationService: ImageGenerationService? = nil,
        diagnostics: DiagnosticsService = DiagnosticsService(),
        sessionToolSources: [any SessionToolSource] = [],
        hookRegistry: HookRegistry? = nil,
        makeModelContainer: @MainActor () throws -> ModelContainer = { try ModelContainerFactory.makeContainer() }
    ) throws {
        // Capture the previous configuration before any mutation so a failure
        // partway through bootstrap leaves `ManifoldConfiguration.shared`
        // untouched from the caller's perspective.
        let previousConfiguration = ManifoldConfiguration.shared

        do {
            ManifoldConfiguration.shared = configuration

            let resolvedInferenceService = inferenceService ?? InferenceService()
            self.inferenceService = resolvedInferenceService

            let resolvedModelContainer = try makeModelContainer()
            self.modelContainer = resolvedModelContainer

            self.diagnostics = diagnostics
            let mainContext = resolvedModelContainer.mainContext
            let resolvedPersistence = SwiftDataPersistenceProvider(modelContext: mainContext)
            self.persistence = resolvedPersistence
            self.samplerPresetStore = SwiftDataSamplerPresetStore(modelContext: mainContext)
            self.benchmarkCache = SwiftDataBenchmarkCache(modelContext: mainContext)
            self.endpointStore = SwiftDataEndpointStore(modelContext: mainContext)
            let resolvedUsageStore = SwiftDataUsageStore(modelContext: mainContext)
            self.usageStore = resolvedUsageStore

            let resolvedRAGService = Self.makeRAGService(
                ragConfiguration: ragConfiguration,
                modelContext: mainContext
            )
            self.ragService = resolvedRAGService

            // ManifoldPersistenceSwiftData does not depend on ManifoldFoundation,
            // so FoundationBackend cannot be instantiated here directly. Host apps
            // that run on iOS 26+ / macOS 26+ can wire their own auxiliary service
            // via the `auxiliaryInferenceService:` parameter on ConversationRuntime.
            // See ManifoldFoundation.FoundationBackend for the recommended setup.
            self.conversationRuntime = ConversationRuntime(
                messageStore: resolvedPersistence,
                sessionStore: resolvedPersistence,
                inferenceService: resolvedInferenceService,
                ragService: resolvedRAGService,
                usageStore: resolvedUsageStore,
                sessionToolSources: sessionToolSources,
                hookRegistry: hookRegistry
            )
            self.imageGenerationService = imageGenerationService
            if let imageGenerationService {
                self.imageRuntime = ImageGenerationRuntime(
                    service: imageGenerationService,
                    messageStore: resolvedPersistence
                )
            } else {
                self.imageRuntime = nil
            }
        } catch {
            ManifoldConfiguration.shared = previousConfiguration
            throw error
        }
    }

    internal init(
        inferenceService: InferenceService,
        diagnostics: DiagnosticsService,
        modelContainer: ModelContainer,
        persistence: SwiftDataPersistenceProvider,
        samplerPresetStore: SwiftDataSamplerPresetStore,
        benchmarkCache: SwiftDataBenchmarkCache,
        endpointStore: SwiftDataEndpointStore,
        usageStore: SwiftDataUsageStore,
        imageGenerationService: ImageGenerationService? = nil,
        ragService: RAGService? = nil,
        sessionToolSources: [any SessionToolSource] = [],
        hookRegistry: HookRegistry? = nil
    ) {
        self.inferenceService = inferenceService
        self.diagnostics = diagnostics
        self.modelContainer = modelContainer
        self.persistence = persistence
        self.samplerPresetStore = samplerPresetStore
        self.benchmarkCache = benchmarkCache
        self.endpointStore = endpointStore
        self.usageStore = usageStore
        self.ragService = ragService
        self.conversationRuntime = ConversationRuntime(
            messageStore: persistence,
            sessionStore: persistence,
            inferenceService: inferenceService,
            ragService: ragService,
            usageStore: usageStore,
            sessionToolSources: sessionToolSources,
            hookRegistry: hookRegistry
        )
        self.imageGenerationService = imageGenerationService
        if let imageGenerationService {
            self.imageRuntime = ImageGenerationRuntime(
                service: imageGenerationService,
                messageStore: persistence
            )
        } else {
            self.imageRuntime = nil
        }
    }

    /// Constructs the ``RAGService`` for the given configuration, or returns
    /// `nil` when RAG was not requested.
    ///
    /// Shared by both the synchronous `init` and the async ``build(configuration:ragConfiguration:inferenceService:imageGenerationService:diagnostics:sessionToolSources:hookRegistry:makeModelContainer:)``
    /// factory so the two bootstrap paths wire retrieval identically. Before
    /// this was factored out, `build()` had no RAG wiring at all and silently
    /// produced a runtime with retrieval disabled.
    private static func makeRAGService(
        ragConfiguration: RAGConfiguration?,
        modelContext: ModelContext
    ) -> RAGService? {
        guard let ragConfig = ragConfiguration else { return nil }

        // Resolve the on-disk vector index location. Both the configured URL
        // and the derived Application Support path can be absent (e.g. a
        // sandbox that denies the directory), so skip RAG with a logged
        // warning rather than trapping on a recoverable path.
        let vectorURL = ragConfig.vectorStoreURL
            ?? ModelContainerFactory.defaultStoreURL()?
                .deletingLastPathComponent()
                .appendingPathComponent("ragvectors.bin")
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("ragvectors.bin")

        guard let vectorURL else {
            Log.persistence.warning("ManifoldBootstrap: could not resolve a vector-store URL — RAG retrieval disabled for this session.")
            return nil
        }

        let vectorStore = FlatFileVectorStore(storageURL: vectorURL)
        let documentStore = SwiftDataDocumentStore(modelContext: modelContext)
        let chunker = DocumentChunker(
            chunkSize: ragConfig.chunkSize,
            overlap: ragConfig.chunkOverlap
        )
        return RAGService(
            documentStore: documentStore,
            vectorStore: vectorStore,
            embeddingBackend: ragConfig.embeddingBackend,
            chunker: chunker
        )
    }

    public static func build(
        configuration: ManifoldConfiguration,
        ragConfiguration: RAGConfiguration? = nil,
        inferenceService: InferenceService? = nil,
        imageGenerationService: ImageGenerationService? = nil,
        diagnostics: DiagnosticsService = DiagnosticsService(),
        sessionToolSources: [any SessionToolSource] = [],
        hookRegistry: HookRegistry? = nil,
        makeModelContainer: @MainActor @escaping () throws -> ModelContainer = { try ModelContainerFactory.makeContainer() }
    ) -> (progress: AsyncStream<RuntimeBootstrapMilestone>, task: Task<ManifoldBootstrap, any Error>) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: RuntimeBootstrapMilestone.self,
            bufferingPolicy: .unbounded
        )

        let task = Task { @MainActor [continuation] in
            defer { continuation.finish() }

            let previousConfiguration = ManifoldConfiguration.shared
            do {
                continuation.yield(.installingConfiguration)
                ManifoldConfiguration.shared = configuration
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
                let usageStore = SwiftDataUsageStore(modelContext: mainContext)
                let ragService = makeRAGService(
                    ragConfiguration: ragConfiguration,
                    modelContext: mainContext
                )
                await Task.yield()

                continuation.yield(.complete)

                return ManifoldBootstrap(
                    inferenceService: resolvedService,
                    diagnostics: diagnostics,
                    modelContainer: container,
                    persistence: persistence,
                    samplerPresetStore: samplerPresetStore,
                    benchmarkCache: benchmarkCache,
                    endpointStore: endpointStore,
                    usageStore: usageStore,
                    imageGenerationService: imageGenerationService,
                    ragService: ragService,
                    sessionToolSources: sessionToolSources,
                    hookRegistry: hookRegistry
                )
            } catch {
                ManifoldConfiguration.shared = previousConfiguration
                throw error
            }
        }

        return (stream, task)
    }

    // MARK: - Boot hooks

    /// Removes Keychain items whose owning ``ManifoldSchemaV4/APIEndpoint`` row
    /// no longer exists.
    ///
    /// Orphans accumulate when an endpoint row is deleted while the matching
    /// Keychain delete silently fails, or when rows are wiped directly through
    /// SwiftData without routing through the UI. The reaper compares every
    /// account in the framework's Keychain namespace against the current set of
    /// endpoint IDs and deletes anything that no longer has an owner.
    ///
    /// The sweep is a no-op when
    /// ``ManifoldInference/ManifoldConfiguration/keychainReaperEnabled`` is
    /// `false`. Errors (including Keychain access denial in sandboxed contexts)
    /// are logged and swallowed so a boot hook can never crash the app.
    ///
    /// Fire-and-forget — call once per app boot. Returns the number of items
    /// that were actually reaped, for testing and diagnostics.
    @discardableResult
    public static func reapOrphanedKeychainItems(in modelContext: ModelContext) -> Int {
        guard ManifoldConfiguration.shared.keychainReaperEnabled else {
            return 0
        }

        let validAccounts: Set<String>
        do {
            let descriptor = FetchDescriptor<APIEndpoint>()
            let endpoints = try modelContext.fetch(descriptor)
            validAccounts = Set(endpoints.map(\.keychainAccount))
        } catch {
            Log.security.warning("ManifoldBootstrap.reapOrphanedKeychainItems: failed to fetch APIEndpoint rows — skipping reap: \(error.localizedDescription)")
            return 0
        }

        return KeychainService.sweep(validAccounts: validAccounts)
    }
}

extension ManifoldBootstrap: ChatRuntimeBootstrap {
    public var persistenceStores: any SessionStore & MessageStore { persistence }
    public var apiEndpointStore: any EndpointStore { endpointStore }
    public var diagnosticsService: DiagnosticsService { diagnostics }
    public var imageGenerationRuntime: ImageGenerationRuntime? { imageRuntime }
}
