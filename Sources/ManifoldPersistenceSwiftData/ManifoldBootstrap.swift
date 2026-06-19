import Foundation
import SwiftData
import ManifoldRuntime
import ManifoldInference

// MARK: - RAGConfiguration

/// Configuration for the RAG knowledge base.
///
/// Pass to ``ManifoldBootstrap/init(configuration:ragConfiguration:inferenceService:imageGenerationService:diagnostics:runtimeOptions:sessionToolSources:hookRegistry:makeModelContainer:)``
/// to enable on-device RAG. When `nil`, the runtime runs without retrieval.
///
/// ```swift
/// let rag = RAGConfiguration(embeddingBackend: myLlamaEmbeddingBackend)
/// let bootstrap = try ManifoldBootstrap(configuration: config, ragConfiguration: rag)
/// bootstrap.ragService?.ingest(url: myDocumentURL)
/// ```
///
/// ## Reranking (optional)
///
/// Supply a ``Reranker`` to add a cross-encoder rerank stage after cosine
/// retrieval. The retriever widens its candidate pool, the reranker re-scores
/// each passage against the query, and the top results are injected. On-device,
/// `LlamaReranker` (from `ManifoldLlama`) wraps a RANK-pooling cross-encoder
/// GGUF such as `bge-reranker`:
///
/// ```swift
/// let reranker = LlamaReranker()
/// try await reranker.loadModel(from: bgeRerankerGGUFURL)
/// let rag = RAGConfiguration(
///     embeddingBackend: myLlamaEmbeddingBackend,
///     reranker: reranker
/// )
/// ```
///
/// When `reranker` is `nil` (the default) or its model is not loaded, retrieval
/// behaves exactly as it does without reranking — including the keyword
/// fallback.
public struct RAGConfiguration: Sendable {
    /// Optional embedding backend for semantic search. When `nil`, retrieval
    /// falls back to case-insensitive keyword search.
    public var embeddingBackend: (any EmbeddingBackend)?
    /// Optional reranker for the post-retrieve, pre-inject stage. When `nil`
    /// (or not ready), retrieval behaves exactly as it did before reranking
    /// existed. Supply `LlamaReranker` (from `ManifoldLlama`) loaded with a
    /// cross-encoder GGUF (e.g. `bge-reranker`) to enable it.
    public var reranker: (any Reranker)?
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
        reranker: (any Reranker)? = nil,
        chunkSize: Int = 1800,
        chunkOverlap: Int = 200,
        topK: Int = 5,
        vectorStoreURL: URL? = nil
    ) {
        self.embeddingBackend = embeddingBackend
        self.reranker = reranker
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
/// Call ``build(configuration:ragConfiguration:inferenceService:imageGenerationService:diagnostics:runtimeOptions:sessionToolSources:hookRegistry:makeModelContainer:)``
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

    /// `true` when this bootstrap was created with
    /// ``makeInMemory(configuration:inferenceService:ragConfiguration:)``.
    ///
    /// Useful for surfaces that need to indicate an Incognito/ephemeral mode —
    /// for example the Architect view's Incognito indicator.
    public var isInMemory: Bool { _isInMemory }
    private let _isInMemory: Bool

    /// The SwiftData-backed ``RunStore`` for durable, resumable multi-step runs
    /// (P3b #1784), or `nil` when the host did not opt in via
    /// `enableResumableRuns: true`.
    ///
    /// When non-`nil`, ``conversationRuntime`` was built with a
    /// `ResumableRunDriver` over this store, so you can:
    ///
    /// ```swift
    /// let bootstrap = try ManifoldBootstrap(configuration: config, enableResumableRuns: true)
    /// let run = ConversationRun(sessionID: sessionID, goal: "Plan the launch", maxSteps: 4)
    /// for await event in bootstrap.conversationRuntime.startRun(run) { /* observe */ }
    /// // After a relaunch over the same store:
    /// for await event in bootstrap.conversationRuntime.resumeRun(run.id) { /* observe */ }
    /// ```
    ///
    /// Query persisted runs directly through this store
    /// (`fetchRuns(for:)` / `fetchRun(_:)`).
    public let runStore: SwiftDataRunStore?

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

    /// The video-generation service, when the host opted in to video generation.
    /// `nil` when ``ManifoldBootstrap`` was constructed without a
    /// `videoGenerationService` parameter.
    public let videoGenerationService: VideoGenerationService?

    /// The video-generation runtime, pre-wired against ``videoGenerationService``
    /// and ``persistence``. Pass to ``ChatViewModel/configure(videoRuntime:)``
    /// to enable video generation in the chat view model.
    /// `nil` when ``videoGenerationService`` is `nil`.
    public let videoRuntime: VideoGenerationRuntime?

    /// The audio-generation (TTS) service, when the host opted in to audio
    /// generation. `nil` when ``ManifoldBootstrap`` was constructed without an
    /// `audioGenerationService` parameter.
    public let audioGenerationService: AudioGenerationService?

    /// The audio-generation runtime, pre-wired against ``audioGenerationService``
    /// and ``persistence``. Pass to ``ChatViewModel/configure(audioRuntime:)``
    /// to enable audio generation in the chat view model.
    /// `nil` when ``audioGenerationService`` is `nil`.
    public let audioRuntime: AudioGenerationRuntime?

    /// The web-search runtime, when the host opted in to web search.
    ///
    /// Unlike image/video, the concrete implementation
    /// (`DefaultWebSearchRuntime`) lives in `ManifoldCloud`, which
    /// `ManifoldPersistenceSwiftData` cannot import (backend-family boundary).
    /// The host constructs it and passes it via the `webSearchRuntime`
    /// parameter; `ChatViewModel/configure(webSearchRuntime:)` is then wired
    /// automatically through ``ChatRuntimeBootstrap``. `nil` when no runtime
    /// was supplied.
    public let webSearchRuntime: (any WebSearchRuntime)?

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
        videoGenerationService videoService: VideoGenerationService? = nil,
        webSearchRuntime: (any WebSearchRuntime)? = nil,
        diagnostics: DiagnosticsService = DiagnosticsService(),
        runtimeOptions: ConversationRuntimeOptions = ConversationRuntimeOptions(),
        sessionToolSources: [any SessionToolSource] = [],
        hookRegistry: HookRegistry? = nil,
        enableResumableRuns: Bool = false,
        makeModelContainer: @MainActor () throws -> ModelContainer = { try ModelContainerFactory.makeContainer() },
        isInMemory: Bool = false,
        // Appended at the tail to keep the existing parameter positions stable
        // for the API source-compat digester (#1904 UI fast-follow). Grouped
        // with the other *GenerationService params at the call site by label.
        audioGenerationService: AudioGenerationService? = nil
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

            // Opt-in durable resumable runs (P3b #1784): construct a
            // SwiftData-backed RunStore over the main context and thread it
            // into the runtime options so makeConversationRuntime wires a
            // ResumableRunDriver. When `enableResumableRuns` is false the store
            // stays nil and the runtime keeps SingleTurnDriver — unchanged.
            let resolvedRunStore = enableResumableRuns
                ? SwiftDataRunStore(modelContext: mainContext)
                : nil
            self.runStore = resolvedRunStore
            var resolvedRuntimeOptions = runtimeOptions
            if let resolvedRunStore {
                resolvedRuntimeOptions.runStore = resolvedRunStore
            }

            // ManifoldPersistenceSwiftData does not depend on ManifoldFoundation,
            // so FoundationBackend cannot be instantiated here directly. Host apps
            // that run on iOS 26+ / macOS 26+ can wire their own auxiliary service
            // via `runtimeOptions.auxiliaryInferenceService`.
            // See ManifoldFoundation.FoundationBackend for the recommended setup.
            self.conversationRuntime = Self.makeConversationRuntime(
                persistence: resolvedPersistence,
                inferenceService: resolvedInferenceService,
                ragService: resolvedRAGService,
                usageStore: resolvedUsageStore,
                runtimeOptions: resolvedRuntimeOptions,
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
            self.videoGenerationService = videoService
            self.videoRuntime = videoService.map {
                VideoGenerationRuntime(service: $0, messageStore: resolvedPersistence)
            }
            self.audioGenerationService = audioGenerationService
            self.audioRuntime = audioGenerationService.map {
                AudioGenerationRuntime(service: $0, messageStore: resolvedPersistence)
            }
            self.webSearchRuntime = webSearchRuntime
            self._isInMemory = isInMemory
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
        videoGenerationService: VideoGenerationService? = nil,
        audioGenerationService: AudioGenerationService? = nil,
        webSearchRuntime: (any WebSearchRuntime)? = nil,
        ragService: RAGService? = nil,
        runtimeOptions: ConversationRuntimeOptions = ConversationRuntimeOptions(),
        sessionToolSources: [any SessionToolSource] = [],
        hookRegistry: HookRegistry? = nil,
        runStore: SwiftDataRunStore? = nil,
        isInMemory: Bool = false
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
        self.runStore = runStore
        self._isInMemory = isInMemory
        var resolvedRuntimeOptions = runtimeOptions
        if let runStore {
            resolvedRuntimeOptions.runStore = runStore
        }
        self.conversationRuntime = Self.makeConversationRuntime(
            persistence: persistence,
            inferenceService: inferenceService,
            ragService: ragService,
            usageStore: usageStore,
            runtimeOptions: resolvedRuntimeOptions,
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
        self.videoGenerationService = videoGenerationService
        if let videoGenerationService {
            self.videoRuntime = VideoGenerationRuntime(
                service: videoGenerationService,
                messageStore: persistence
            )
        } else {
            self.videoRuntime = nil
        }
        self.audioGenerationService = audioGenerationService
        if let audioGenerationService {
            self.audioRuntime = AudioGenerationRuntime(
                service: audioGenerationService,
                messageStore: persistence
            )
        } else {
            self.audioRuntime = nil
        }
        self.webSearchRuntime = webSearchRuntime
    }

    /// Constructs the ``ConversationRuntime`` from fully-resolved, path-specific
    /// inputs.
    ///
    /// Shared by the public synchronous `init` and the internal `init` (which
    /// the async ``build()`` factory delegates to) so all construction paths
    /// wire the runtime identically. A forgotten argument can only be forgotten
    /// in one place — before this was factored out, the public `init` and the
    /// internal `init` duplicated the 17-argument construction block verbatim,
    /// which historically caused `build()` to ship with RAG silently missing
    /// (the ``makeRAGService(_:_:)`` refactor fixed the equivalent RAG bug;
    /// this factory closes the runtime-wiring gap).
    private static func makeConversationRuntime(
        persistence: SwiftDataPersistenceProvider,
        inferenceService: InferenceService,
        ragService: RAGService?,
        usageStore: SwiftDataUsageStore,
        runtimeOptions: ConversationRuntimeOptions,
        sessionToolSources: [any SessionToolSource],
        hookRegistry: HookRegistry?
    ) -> ConversationRuntime {
        ConversationRuntime(
            messageStore: persistence,
            sessionStore: persistence,
            inferenceService: inferenceService,
            pipeline: runtimeOptions.pipeline,
            budgetPlanner: runtimeOptions.budgetPlanner,
            ragService: ragService,
            auxiliaryInferenceService: runtimeOptions.auxiliaryInferenceService,
            usageStore: usageStore,
            generationHooks: runtimeOptions.generationHooks,
            compressionPolicy: runtimeOptions.compressionPolicy,
            preTurnCompressionPolicy: runtimeOptions.preTurnCompressionPolicy,
            historyShaper: runtimeOptions.historyShaper,
            historyProviders: runtimeOptions.historyProviders,
            hostTurnContextProvider: runtimeOptions.hostTurnContextProvider,
            turnContextProvider: runtimeOptions.turnContextProvider,
            sessionToolSources: sessionToolSources,
            hookRegistry: hookRegistry,
            runStore: runtimeOptions.runStore
        )
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
            embeddingBackend: resolveEmbeddingBackend(ragConfig.embeddingBackend),
            reranker: ragConfig.reranker,
            chunker: chunker
        )
    }

    /// Resolves the embedding backend RAG will use.
    ///
    /// A host-supplied backend always wins. When the host did not inject one,
    /// this falls back to the bundled on-device ``NLEmbeddingBackend`` so RAG
    /// performs semantic (vector) retrieval out of the box with zero model
    /// download. If even that is unavailable (no sentence-embedding model for
    /// the OS locale), `nil` is returned and ``RAGService`` degrades to
    /// case-insensitive keyword search — never a crash.
    static func resolveEmbeddingBackend(
        _ hostSupplied: (any EmbeddingBackend)?
    ) -> (any EmbeddingBackend)? {
        if let hostSupplied { return hostSupplied }
        #if canImport(NaturalLanguage)
        if let bundled = NLEmbeddingBackend() {
            return bundled
        }
        Log.persistence.warning("ManifoldBootstrap: bundled NLEmbeddingBackend unavailable for this OS locale — RAG will use keyword-only retrieval until a host backend is supplied.")
        #endif
        return nil
    }

    public static func build(
        configuration: ManifoldConfiguration,
        ragConfiguration: RAGConfiguration? = nil,
        inferenceService: InferenceService? = nil,
        imageGenerationService: ImageGenerationService? = nil,
        videoGenerationService: VideoGenerationService? = nil,
        webSearchRuntime: (any WebSearchRuntime)? = nil,
        diagnostics: DiagnosticsService = DiagnosticsService(),
        runtimeOptions: ConversationRuntimeOptions = ConversationRuntimeOptions(),
        sessionToolSources: [any SessionToolSource] = [],
        hookRegistry: HookRegistry? = nil,
        enableResumableRuns: Bool = false,
        makeModelContainer: @MainActor @escaping () throws -> ModelContainer = { try ModelContainerFactory.makeContainer() },
        // Appended at the tail to keep existing parameter positions stable for
        // the API source-compat digester (#1904 UI fast-follow).
        audioGenerationService: AudioGenerationService? = nil
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
                let runStore = enableResumableRuns
                    ? SwiftDataRunStore(modelContext: mainContext)
                    : nil
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
                    videoGenerationService: videoGenerationService,
                    audioGenerationService: audioGenerationService,
                    webSearchRuntime: webSearchRuntime,
                    ragService: ragService,
                    runtimeOptions: runtimeOptions,
                    sessionToolSources: sessionToolSources,
                    hookRegistry: hookRegistry,
                    runStore: runStore
                )
            } catch {
                ManifoldConfiguration.shared = previousConfiguration
                throw error
            }
        }

        return (stream, task)
    }

    // MARK: - In-memory bootstrap

    /// Creates a ``ManifoldBootstrap`` backed by an ephemeral in-memory SwiftData
    /// container — nothing is written to disk.
    ///
    /// Use for Incognito sessions (no conversation history persisted), SwiftUI
    /// Previews, and test helpers that need the full bootstrap stack without
    /// touching the production store.
    ///
    /// ```swift
    /// let incognito = try ManifoldBootstrap.makeInMemory(
    ///     configuration: ManifoldConfiguration(bundleIdentifier: "com.example.MyApp"),
    ///     inferenceService: InferenceService(backend: myBackend)
    /// )
    /// // incognito.isInMemory == true
    /// ```
    ///
    /// - Parameters:
    ///   - configuration: The ``ManifoldConfiguration`` to install.
    ///   - inferenceService: The inference service to use. A default
    ///     ``InferenceService`` is created when `nil`.
    ///   - ragConfiguration: Optional RAG configuration. When supplied, the
    ///     RAG service is wired against the in-memory document store and the
    ///     vector index URL from ``RAGConfiguration/vectorStoreURL`` (or a
    ///     resolved Application Support path). Pass `nil` to disable retrieval.
    /// - Returns: A fully-wired ``ManifoldBootstrap`` whose persistence is
    ///   ephemeral — all data is discarded when the instance is deallocated.
    /// - Throws: If the in-memory ``ModelContainer`` cannot be created.
    public static func makeInMemory(
        configuration: ManifoldConfiguration,
        inferenceService: InferenceService? = nil,
        ragConfiguration: RAGConfiguration? = nil
    ) throws -> ManifoldBootstrap {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        return try ManifoldBootstrap(
            configuration: configuration,
            ragConfiguration: ragConfiguration,
            inferenceService: inferenceService,
            makeModelContainer: { container },
            isInMemory: true
        )
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

// MARK: - Tool sources

extension ManifoldBootstrap {
    /// Registers additional session tool sources with the conversation runtime.
    ///
    /// Convenience wrapper around
    /// ``ConversationRuntime/updateSessionToolSources(_:)``. Tool sources added
    /// here are available to all subsequent generation turns; calling this method
    /// again replaces the previous set.
    ///
    /// ```swift
    /// await bootstrap.addToolSources([
    ///     ImageGenerationToolSource(viewModel: viewModel),
    ///     MyCustomToolSource()
    /// ])
    /// ```
    public func addToolSources(_ sources: [any SessionToolSource]) async {
        await conversationRuntime.updateSessionToolSources(sources)
    }
}

extension ManifoldBootstrap: ChatRuntimeBootstrap {
    public var persistenceStores: any SessionStore & MessageStore { persistence }
    public var apiEndpointStore: any EndpointStore { endpointStore }
    public var diagnosticsService: DiagnosticsService { diagnostics }
    public var imageGenerationRuntime: ImageGenerationRuntime? { imageRuntime }
    public var videoGenerationRuntime: VideoGenerationRuntime? { videoRuntime }
    public var audioGenerationRuntime: AudioGenerationRuntime? { audioRuntime }
    public var webSearchRuntimePort: (any WebSearchRuntime)? { webSearchRuntime }
}
