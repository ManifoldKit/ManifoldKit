import Foundation
import SwiftData
import BaseChatRuntime
import BaseChatInference

// MARK: - RAGConfiguration

/// Configuration for the RAG knowledge base.
///
/// Pass to ``BaseChatBootstrap/init(configuration:ragConfiguration:inferenceService:imageGenerationService:diagnostics:makeModelContainer:)``
/// to enable on-device RAG. When `nil`, the runtime runs without retrieval.
///
/// ```swift
/// let rag = RAGConfiguration(embeddingBackend: myLlamaEmbeddingBackend)
/// let bootstrap = try BaseChatBootstrap(configuration: config, ragConfiguration: rag)
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

/// Preferred bootstrap surface for host apps that use BaseChatKit's shipped
/// SwiftData persistence.
///
/// ``BaseChatBootstrap`` installs ``BaseChatConfiguration/shared`` first, then
/// builds the shared inference, persistence, and diagnostics services in a
/// fixed order so consumer apps do not have to manually coordinate those
/// steps.
///
/// Apps that need a custom ``InferenceService`` configuration (for example a
/// `ToolRegistry` or approval gate) can construct that service first and pass
/// it in. The runtime will keep using the exact instance supplied.
///
/// ``BaseChatBootstrap`` is the SwiftData-backed bootstrap. Adopters using
/// custom ``SessionStore`` / ``MessageStore`` impls should construct
/// ``ChatViewModel`` / ``SessionManagerViewModel`` directly and call
/// `configure(persistence:)` — runtime support for custom stores is tracked
/// separately.
///
/// > Note: This type was named `BaseChatRuntime` prior to the phase-2 target
/// > split. It was renamed to avoid shadowing the `BaseChatRuntime` *target*
/// > (module) name in IDE jump-to-definition and DocC.
///
/// ### Splash-screen progress
///
/// Call ``build(configuration:inferenceService:diagnostics:makeModelContainer:)``
/// instead of `init` when you want to drive a launch progress UI. That factory
/// returns an `AsyncStream<RuntimeBootstrapMilestone>` you can iterate on the
/// main actor while bootstrap runs concurrently in a sibling task:
///
/// ```swift
/// let (milestones, runtimeTask) = BaseChatBootstrap.build(configuration: config)
/// for await milestone in milestones {
///     splashProgress = milestone.fractionComplete
/// }
/// runtime = try await runtimeTask.value
/// ```
@MainActor
public final class BaseChatBootstrap {

    public let inferenceService: InferenceService
    public let diagnostics: DiagnosticsService
    public let modelContainer: ModelContainer
    public let persistence: SwiftDataPersistenceProvider
    public let samplerPresetStore: SwiftDataSamplerPresetStore
    public let benchmarkCache: SwiftDataBenchmarkCache
    public let endpointStore: SwiftDataEndpointStore
    /// The shared turn-loop runtime, pre-wired against ``persistence`` and
    /// ``inferenceService``. Apps that bootstrap through this type should pass
    /// this instance to ``ChatViewModel/configure(conversationRuntime:)`` (or
    /// rely on ``ChatViewModel/configure(runtime:)``, which does so by
    /// default) to opt into the runtime-driven send/regenerate/edit/cancel
    /// path.
    public let conversationRuntime: ConversationRuntime

    /// The image-generation service, when the host opted in to image generation.
    /// `nil` when ``BaseChatBootstrap`` was constructed without an
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

    /// Builds the full BaseChatKit stack synchronously.
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
        configuration: BaseChatConfiguration,
        ragConfiguration: RAGConfiguration? = nil,
        inferenceService: InferenceService? = nil,
        imageGenerationService: ImageGenerationService? = nil,
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
            let resolvedPersistence = SwiftDataPersistenceProvider(modelContext: mainContext)
            self.persistence = resolvedPersistence
            self.samplerPresetStore = SwiftDataSamplerPresetStore(modelContext: mainContext)
            self.benchmarkCache = SwiftDataBenchmarkCache(modelContext: mainContext)
            self.endpointStore = SwiftDataEndpointStore(modelContext: mainContext)

            let resolvedRAGService: RAGService?
            if let ragConfig = ragConfiguration {
                let vectorURL = ragConfig.vectorStoreURL
                    ?? ModelContainerFactory.defaultStoreURL()?
                        .deletingLastPathComponent()
                        .appendingPathComponent("ragvectors.bin")
                    ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                        .first!.appendingPathComponent("ragvectors.bin")
                let vectorStore = FlatFileVectorStore(storageURL: vectorURL)
                let documentStore = SwiftDataDocumentStore(modelContext: mainContext)
                let chunker = DocumentChunker(
                    chunkSize: ragConfig.chunkSize,
                    overlap: ragConfig.chunkOverlap
                )
                resolvedRAGService = RAGService(
                    documentStore: documentStore,
                    vectorStore: vectorStore,
                    embeddingBackend: ragConfig.embeddingBackend,
                    chunker: chunker
                )
            } else {
                resolvedRAGService = nil
            }
            self.ragService = resolvedRAGService

            self.conversationRuntime = ConversationRuntime(
                messageStore: resolvedPersistence,
                sessionStore: resolvedPersistence,
                inferenceService: resolvedInferenceService,
                ragService: resolvedRAGService
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
            BaseChatConfiguration.shared = previousConfiguration
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
        imageGenerationService: ImageGenerationService? = nil,
        ragService: RAGService? = nil
    ) {
        self.inferenceService = inferenceService
        self.diagnostics = diagnostics
        self.modelContainer = modelContainer
        self.persistence = persistence
        self.samplerPresetStore = samplerPresetStore
        self.benchmarkCache = benchmarkCache
        self.endpointStore = endpointStore
        self.ragService = ragService
        self.conversationRuntime = ConversationRuntime(
            messageStore: persistence,
            sessionStore: persistence,
            inferenceService: inferenceService,
            ragService: ragService
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

    public static func build(
        configuration: BaseChatConfiguration,
        inferenceService: InferenceService? = nil,
        imageGenerationService: ImageGenerationService? = nil,
        diagnostics: DiagnosticsService = DiagnosticsService(),
        makeModelContainer: @MainActor @escaping () throws -> ModelContainer = { try ModelContainerFactory.makeContainer() }
    ) -> (progress: AsyncStream<RuntimeBootstrapMilestone>, task: Task<BaseChatBootstrap, any Error>) {
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

                return BaseChatBootstrap(
                    inferenceService: resolvedService,
                    diagnostics: diagnostics,
                    modelContainer: container,
                    persistence: persistence,
                    samplerPresetStore: samplerPresetStore,
                    benchmarkCache: benchmarkCache,
                    endpointStore: endpointStore,
                    imageGenerationService: imageGenerationService
                )
            } catch {
                BaseChatConfiguration.shared = previousConfiguration
                throw error
            }
        }

        return (stream, task)
    }

    // MARK: - Boot hooks

    /// Removes Keychain items whose owning ``BaseChatSchemaV4/APIEndpoint`` row
    /// no longer exists.
    ///
    /// Orphans accumulate when an endpoint row is deleted while the matching
    /// Keychain delete silently fails, or when rows are wiped directly through
    /// SwiftData without routing through the UI. The reaper compares every
    /// account in the framework's Keychain namespace against the current set of
    /// endpoint IDs and deletes anything that no longer has an owner.
    ///
    /// The sweep is a no-op when
    /// ``BaseChatInference/BaseChatConfiguration/keychainReaperEnabled`` is
    /// `false`. Errors (including Keychain access denial in sandboxed contexts)
    /// are logged and swallowed so a boot hook can never crash the app.
    ///
    /// Fire-and-forget — call once per app boot. Returns the number of items
    /// that were actually reaped, for testing and diagnostics.
    @discardableResult
    public static func reapOrphanedKeychainItems(in modelContext: ModelContext) -> Int {
        guard BaseChatConfiguration.shared.keychainReaperEnabled else {
            return 0
        }

        let validAccounts: Set<String>
        do {
            let descriptor = FetchDescriptor<APIEndpoint>()
            let endpoints = try modelContext.fetch(descriptor)
            validAccounts = Set(endpoints.map(\.keychainAccount))
        } catch {
            Log.security.warning("BaseChatBootstrap.reapOrphanedKeychainItems: failed to fetch APIEndpoint rows — skipping reap: \(error.localizedDescription)")
            return 0
        }

        return KeychainService.sweep(validAccounts: validAccounts)
    }
}

extension BaseChatBootstrap: ChatRuntimeBootstrap {
    public var persistenceStores: any SessionStore & MessageStore { persistence }
    public var apiEndpointStore: any EndpointStore { endpointStore }
    public var diagnosticsService: DiagnosticsService { diagnostics }
    public var imageGenerationRuntime: ImageGenerationRuntime? { imageRuntime }
}
