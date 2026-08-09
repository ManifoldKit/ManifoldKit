// QuickStart — one-call bootstrap facade.
//
// Collapses the documented three-object dance (`ManifoldBootstrap.build(...)`
// + `DefaultBackends.register(with:)` + `ChatViewModel(...)`) into a single
// API call. The README's first code block depends on this remaining a
// one-liner; do not grow it into a parameterised builder.
//
// The facade is intentionally non-configurable beyond `ManifoldConfiguration`
// — adopters who need a custom inference service, a custom model container,
// or a non-default backend mix should drop down to `ManifoldBootstrap.build`
// directly. The whole point of `quickStart()` is "no decisions required."

import Foundation
import SwiftData
import ManifoldInference
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldFoundation
import ManifoldOllama
import ManifoldCloudSaaS
import ManifoldUI
import ManifoldHuggingFace

// MARK: - Backend availability diagnostics
//
// There is intentionally no compile-time "no backends" `#warning` here (one
// existed pre-v0.48). Since v0.48 the cloud families (Ollama + SaaS) compile
// unconditionally, so the "zero backends compiled in" condition the old
// warning guarded is no longer expressible. Whether a backend can actually
// *generate* is a runtime question: a cloud backend needs a configured
// endpoint, FoundationBackend needs iOS 26 / macOS 26+, and local backends
// need a downloaded model.
//
// The authoritative runtime diagnostics are `ManifoldKitError.noBackendsRegistered`
// (nothing registered at all) and the cloud-only-without-endpoint warning from
// `backendAvailabilityDiagnostic(snapshot:configuredEndpointCount:)` — both
// derived from live registration state, so they see companion-package
// registrars injected via `quickStart(backends:)`.

/// The umbrella namespace for ManifoldKit's high-level entry points.
///
/// Today this hosts ``quickStart(configuration:)``;
/// future top-level conveniences will land here so adopters have one
/// well-known place to look.
@MainActor
public enum ManifoldKit {

    /// The compiled-in default backend registrars folded by `quickStart()`.
    ///
    /// Since v0.48 these are the families that ship in core: the two cloud
    /// families (Ollama self-hosted + the SaaS providers) and Apple Foundation
    /// Models. The MLX and llama.cpp families live in the manifold-mlx /
    /// manifold-llama companion packages (#1749) — pass their registrars to
    /// ``quickStart(backends:configuration:seed:)``.
    ///
    /// Order is significant only for the cloud registrars, which prime
    /// `PinnedSessionDelegate` before any URLSession factory is built; the
    /// Foundation registrar is independent.
    @MainActor
    public static let defaultBackendRegistrars: [any BackendRegistrar.Type] = [
        OllamaBackends.self,
        CloudSaaSBackends.self,
        FoundationBackends.self,
    ]

    /// Bootstraps a working chat runtime with sensible defaults in one call.
    ///
    /// Internally this:
    /// 1. Drives `ManifoldBootstrap.build(...)` to completion (consuming its
    ///    progress milestones).
    /// 2. Registers the compiled-in default backends.
    /// 3. Constructs a `ChatViewModel` wired to the bootstrap's shared
    ///    `InferenceService`, persistence stores, and `ConversationRuntime`.
    ///
    /// Errors thrown by any step are reduced through `ManifoldKitError.from(_:)`
    /// so callers always see the unified error rim instead of raw
    /// `URLError` / SwiftData errors.
    ///
    /// ```swift
    /// let kit = try await ManifoldKit.quickStart()
    /// // kit.viewModel      — a configured ChatViewModel
    /// // kit.sessionManager — sessions already loaded; wire to a sidebar list
    /// // kit.bootstrap      — keep alive for the lifetime of the app
    /// ```
    ///
    /// - Parameter configuration: The framework configuration. Defaults to
    ///   `ManifoldConfiguration.default` — fine for
    ///   demos and tests, but production apps should pass an explicit
    ///   configuration with their own bundle identifier.
    /// - Returns: A ``QuickStartResult`` carrying the bootstrap, the chat view
    ///   model, and a session manager with the initial session page already
    ///   loaded. The caller owns the bootstrap and must retain it for the
    ///   lifetime of the chat runtime.
    public static func quickStart(
        configuration: ManifoldConfiguration = .default
    ) async throws -> QuickStartResult {
        try await _quickStart(
            configuration: configuration,
            makeModelContainer: { try ModelContainerFactory.makeContainer() }
        )
    }

    /// Bootstraps a working chat runtime and seeds a curated small model on
    /// first launch when no model is available.
    ///
    /// This overload extends ``quickStart(configuration:)`` with an opt-in
    /// first-launch download so developers can reach a *live, generating* chat
    /// in one call — no model management UI required.
    ///
    /// ### What changes versus `quickStart(configuration:)`
    ///
    /// When `seed` is non-nil and no model is already selectable (no Foundation
    /// model and no on-disk GGUF / MLX), `quickStart` downloads the curated
    /// model **before** the backend-selection policy runs. After a successful
    /// download the model registry is refreshed and the selection policy picks
    /// the new model automatically — the chat is live.
    ///
    /// The download is **skipped** (with a log entry, never an error) when any
    /// of the following is true:
    /// - A model is already available (Foundation or local disk).
    /// - No *registered* backend can load the seed's model type — checked
    ///   against the live `InferenceService` registration state, so backends
    ///   injected via ``quickStart(backends:configuration:seed:)`` count.
    ///   The curated GGUF seed therefore requires the manifold-llama companion
    ///   package's `LlamaBackends` registrar (see ``QuickStartSeed``).
    /// - A network error occurs (the app launches with the empty state instead).
    ///
    /// ### Example
    ///
    /// ```swift
    /// import ManifoldLlama
    ///
    /// let kit = try await ManifoldKit.quickStart(
    ///     backends: [LlamaBackends.self],
    ///     seed: .recommendedSmallModel { progress in
    ///         print("Downloading: \(Int(progress * 100))%")
    ///     }
    /// )
    /// // kit.viewModel is live — generating chat ready on first launch
    /// ```
    ///
    /// - Parameters:
    ///   - configuration: Framework configuration. Defaults to
    ///     `ManifoldConfiguration.default`.
    ///   - seed: Opt-in seed configuration. Use
    ///     ``QuickStartSeed/recommended(useCase:device:foundationAvailable:onProgress:)``
    ///     to seed a *device-aware* starter model — a 64 GB M-series machine gets a
    ///     larger, more capable model than a base iPhone, with the Qwen3-0.6B floor
    ///     as the guaranteed fallback. Use
    ///     ``QuickStartSeed/recommendedSmallModel(onProgress:)`` to always seed the
    ///     fixed 0.6B floor. Pass `nil` for the original (no-seed) behavior.
    /// - Returns: A ``QuickStartResult`` as in ``quickStart(configuration:)``.
    public static func quickStart(
        configuration: ManifoldConfiguration = .default,
        seed: QuickStartSeed?
    ) async throws -> QuickStartResult {
        try await _quickStart(
            configuration: configuration,
            seed: seed,
            makeModelContainer: { try ModelContainerFactory.makeContainer() }
        )
    }

    /// Bootstraps a working chat runtime with additional, caller-supplied
    /// backend registrars.
    ///
    /// This is the migration path for backends that live outside this package
    /// (the `manifold-mlx` / `manifold-llama` companion packages, #1749).
    /// The compiled-in defaults are registered
    /// first, then every entry in `backends` — **before** the model registry
    /// refresh, the optional starter-model seed, and the model-selection
    /// policy run. Registering a backend only after `quickStart` returns is
    /// too late for all three of those steps: the seed would skip ("no backend
    /// can load .gguf"), and the selection policy would refuse to pick an
    /// on-disk model it believes nothing can load.
    ///
    /// ```swift
    /// import ManifoldKit
    /// import ManifoldMLX   // from the manifold-mlx companion package
    ///
    /// let kit = try await ManifoldKit.quickStart(backends: [MLXBackends.self])
    /// ```
    ///
    /// - Parameters:
    ///   - backends: Registrars to fold into the service after the compiled-in
    ///     defaults. Order follows array order; registering the same family
    ///     twice is harmless (last registration wins per model type).
    ///   - includeDefaultBackends: When `true` (the default — unchanged
    ///     behaviour for every existing caller) the compiled-in default cloud +
    ///     Foundation families are registered before `backends`. Pass `false`
    ///     for a **local-only / replace-mode** runtime in which *only* the
    ///     registrars you name are wired, so the cloud families never reach the
    ///     service. See ``localOnly(backends:configuration:seed:)`` for the
    ///     on-device convenience built on this. Note: this is
    ///     *registration-level* exclusion, not link-level — the cloud code is
    ///     still linked through the `ManifoldKit` umbrella. For true link-time
    ///     exclusion (FIPS) depend on the individual products; see docs/FIPS.md.
    ///   - configuration: Framework configuration. Defaults to
    ///     `ManifoldConfiguration.default`.
    ///   - seed: Optional starter-model seed, as in
    ///     ``quickStart(configuration:seed:)``. The seed sees the injected
    ///     backends: a GGUF seed downloads when any registered backend —
    ///     compiled-in or injected — can load `.gguf`.
    /// - Returns: A ``QuickStartResult`` as in ``quickStart(configuration:)``.
    public static func quickStart(
        backends: [any BackendRegistrar.Type],
        includeDefaultBackends: Bool = true,
        configuration: ManifoldConfiguration = .default,
        seed: QuickStartSeed? = nil
    ) async throws -> QuickStartResult {
        try await _quickStart(
            configuration: configuration,
            backends: backends,
            includeDefaultBackends: includeDefaultBackends,
            seed: seed,
            makeModelContainer: { try ModelContainerFactory.makeContainer() }
        )
    }

    /// Bootstraps a working chat runtime that registers **no cloud backends** —
    /// the privacy / local-only / on-device entry point.
    ///
    /// Unlike ``quickStart(backends:configuration:seed:)`` (which always folds in
    /// the cloud families), this convenience registers only the on-device Apple
    /// Foundation Models family plus any `backends` you pass — typically the
    /// `manifold-llama` (GGUF) or `manifold-mlx` registrars for local inference
    /// on OSes without Apple Intelligence. The Ollama and SaaS cloud families are
    /// never registered, so no cloud backend can be selected or dispatched.
    ///
    /// ```swift
    /// import ManifoldKit
    /// import ManifoldLlama   // manifold-llama companion package
    ///
    /// // On-device only: Foundation Models (iOS 26 / macOS 26+) + local GGUF.
    /// let kit = try await ManifoldKit.localOnly(backends: [LlamaBackends.self])
    /// ```
    ///
    /// - Important: This is *registration-level* exclusion: the chat surface
    ///   cannot reach a cloud provider, but the cloud code is still compiled and
    ///   linked through the `ManifoldKit` umbrella. It does **not** guarantee the
    ///   binary contains no networking/cloud symbols. For true link-time
    ///   exclusion (e.g. a FIPS posture) depend on the individual products rather
    ///   than the umbrella — see docs/FIPS.md.
    ///
    /// - Parameters:
    ///   - backends: On-device registrars to register alongside Foundation
    ///     (e.g. `[LlamaBackends.self]`). Defaults to empty — on iOS 26 / macOS
    ///     26+ Foundation Models alone yields a working local chat.
    ///   - configuration: Framework configuration. Defaults to
    ///     `ManifoldConfiguration.default`.
    ///   - seed: Optional starter-model seed, as in
    ///     ``quickStart(backends:configuration:seed:)``.
    /// - Returns: A ``QuickStartResult`` as in ``quickStart(configuration:)``.
    public static func localOnly(
        backends: [any BackendRegistrar.Type] = [],
        configuration: ManifoldConfiguration = .default,
        seed: QuickStartSeed? = nil
    ) async throws -> QuickStartResult {
        try await _quickStart(
            configuration: configuration,
            // Fold in the on-device Foundation family explicitly; everything
            // else (the cloud families) is excluded by includeDefaultBackends.
            backends: [FoundationBackends.self] + backends,
            includeDefaultBackends: false,
            seed: seed,
            makeModelContainer: { try ModelContainerFactory.makeContainer() }
        )
    }

    /// Internal seam used by tests to inject a custom (or throwing) model
    /// container factory and an optional selection policy. Production callers
    /// go through ``quickStart(configuration:)`` or ``quickStart(configuration:seed:)``.
    ///
    /// - Parameters:
    ///   - configuration: The framework configuration.
    ///   - seed: Optional seed configuration. When non-nil and no model is
    ///     available, a curated small model is downloaded before the selection
    ///     policy runs. Nil skips seeding entirely.
    ///   - makeModelContainer: Factory closure that produces the SwiftData container.
    ///   - downloadManagerOverride: Injectable download manager for tests. When
    ///     nil, a `BackgroundDownloadManager` is created.
    ///   - foundationAvailableOverride: Test seam for "is a zero-cost
    ///     Foundation model available?", which otherwise depends on the
    ///     host's Apple Intelligence state. Nil uses the live probe. Shared
    ///     by two call sites: the seed path's download-skip check, and the
    ///     backend-availability diagnostic's OS-gate detection (#2157) —
    ///     both ask the same underlying question, so one override covers
    ///     both deterministically in tests regardless of the test host's OS.
    ///   - storageServiceOverride: Test seam for the seed path's "is a model
    ///     already on disk?" probe, which otherwise scans the host's real
    ///     models directory. Nil uses the default service.
    ///   - selectionPolicy: An optional closure that receives the populated
    ///     `ModelRegistry` and returns the `ModelInfo` to select, or `nil` to
    ///     leave no model selected. When `nil` (the default), the built-in
    ///     Foundation-first → first-local → labeled-empty-state policy runs.
    static func _quickStart(
        configuration: ManifoldConfiguration,
        backends: [any BackendRegistrar.Type] = [],
        includeDefaultBackends: Bool = true,
        seed: QuickStartSeed? = nil,
        makeModelContainer: @MainActor @escaping () throws -> ModelContainer,
        downloadManagerOverride: (any BackgroundDownloadManaging)? = nil,
        foundationAvailableOverride: Bool? = nil,
        storageServiceOverride: ModelStorageService? = nil,
        selectionPolicy: (@MainActor (ModelRegistry) async -> ModelInfo?)? = nil
    ) async throws -> QuickStartResult {
        do {
            // Drive the bootstrap stream to completion. We don't surface
            // milestones from the simple facade — `quickStart()` is the
            // "no progress UI" path. Consumers that want a launch
            // progress bar should call `ManifoldBootstrap.build` directly.
            // Enable RAG by default. With no embedding backend injected,
            // `ManifoldBootstrap` resolves the bundled on-device
            // `NLEmbeddingBackend` (Apple NaturalLanguage, zero download), so a
            // host gets working semantic retrieval out of the box. Hosts that
            // want a higher-quality embedder (MLXEmbedders / Llama) or to disable
            // RAG drop down to `ManifoldBootstrap.build` directly with their own
            // `RAGConfiguration`.
            let (progress, task) = ManifoldBootstrap.build(
                configuration: configuration,
                ragConfiguration: RAGConfiguration(),
                makeModelContainer: makeModelContainer
            )
            for await _ in progress {
                // Consume so the buffered stream doesn't grow unboundedly.
                // The bootstrap task drives `continuation.finish()` itself.
            }

            let bootstrap = try await task.value

            // Register the compiled-in defaults first (unless the caller opted
            // out via `includeDefaultBackends: false`), then any caller-supplied
            // registrars (companion packages, #1749). Both must run before the
            // registry refresh, the starter seed, and the selection policy —
            // all three consult the live registration state below.
            // The compiled-in defaults are the surviving core families:
            // Ollama + SaaS (cloud) + Foundation. The MLX / llama.cpp
            // registrars live in the manifold-mlx / manifold-llama companion
            // packages — pass them via `backends:`.
            if !includeDefaultBackends {
                // Local-only / replace-mode: only the caller's registrars are
                // wired, so the cloud families never reach the service. This is
                // *registration-level* exclusion — the privacy guarantee a host
                // gets is "no cloud backend can be selected or dispatched" — NOT
                // link-level: the cloud code is still compiled and linked through
                // the `ManifoldKit` umbrella. For true link-time exclusion (e.g.
                // FIPS) depend on the individual products instead of the umbrella;
                // see docs/FIPS.md.
                Log.quickStart.info("quickStart: includeDefaultBackends=false — registering only the \(backends.count, privacy: .public) caller-supplied backend(s); the default cloud families (Ollama + SaaS) are NOT registered. Registration-level exclusion only (the cloud code is still linked via the ManifoldKit umbrella) — see docs/FIPS.md for true link-time exclusion.")
            }
            let baseRegistrars = includeDefaultBackends ? ManifoldKit.defaultBackendRegistrars : []
            for registrar in baseRegistrars {
                registrar.register(with: bootstrap.inferenceService)
            }
            for registrar in backends {
                registrar.register(with: bootstrap.inferenceService)
            }

            // Fail fast / warn loudly when the assembled service can never
            // generate. Without this the app launches fully wired —
            // persistence, session list, composer enabled — then throws on the
            // first turn with a confusing "No model loaded". The check is
            // runtime-registration-based (not trait-based): once cloud
            // registrars register unconditionally, "some backend registered"
            // stops implying "local inference works", so the cloud-only case
            // additionally checks for a configured endpoint.
            let snapshot = bootstrap.inferenceService.registeredBackendSnapshot()
            let configuredEndpointCount: Int
            if snapshot.supportsLocalInference {
                // Endpoints are irrelevant to the diagnostic when local
                // inference is available — skip the fetch.
                configuredEndpointCount = 0
            } else {
                do {
                    configuredEndpointCount = try await bootstrap.endpointStore.fetchEndpoints().count
                } catch {
                    Log.quickStart.warning("quickStart: endpoint fetch failed during backend-availability check: \(error, privacy: .public)")
                    configuredEndpointCount = 0
                }
            }
            switch backendAvailabilityDiagnostic(
                snapshot: snapshot,
                configuredEndpointCount: configuredEndpointCount,
                registrars: baseRegistrars + backends,
                foundationModelsOSAvailable: foundationAvailableOverride ?? ManifoldKit.foundationModelsOSAvailable
            ) {
            case .noBackends:
                throw ManifoldKitError.noBackendsRegistered
            case .noBackendsOSGated(let reason):
                // No new public ManifoldKitError case for the OS-gate cause
                // (readiness/error-surface-completeness follow-up — a new
                // case on a public non-frozen enum is source-breaking). The
                // concrete reason is logged here so it isn't lost; the
                // thrown case's `errorDescription` carries generic-but-
                // actionable OS-gate guidance for callers that only read
                // `error.localizedDescription`.
                Log.quickStart.error("quickStart: \(reason, privacy: .public)")
                throw ManifoldKitError.noBackendsRegistered
            case .cloudOnlyWithoutEndpoint(let message):
                // Warn rather than throw: endpoints are commonly configured
                // *after* quickStart() returns (settings UI, first-run flow),
                // so a cloud-only service is degraded, not necessarily dead.
                Log.quickStart.warning("\(message, privacy: .public)")
            case nil:
                break
            }

            let viewModel = ChatViewModel(
                inferenceService: bootstrap.inferenceService,
                conversationRuntime: bootstrap.conversationRuntime
            )
            viewModel.configure(persistence: bootstrap.persistence)
            viewModel.configure(endpointStore: bootstrap.endpointStore)

            // Wire the Foundation-model availability probe so `refresh()`
            // prepends the built-in model when Apple Intelligence is available.
            // Done before the selection policy so `availableModels` reflects
            // the full local catalogue at policy-evaluation time.
            #if canImport(FoundationModels)
            if #available(iOS 26, macOS 26, *) {
                viewModel.modelRegistry.foundationModelProvider = { FoundationBackend.isAvailable }
            }
            #endif

            // Wire the session manager and await its initial load so that
            // `sessionManager.sessions` is populated before this call returns
            // (#1447). Using `configureAndLoad(bootstrap:)` instead of the
            // fire-and-forget `configure(bootstrap:)` eliminates the race
            // window that forced consumers to invent polling heuristics on
            // relaunch.
            let sessionManager = SessionManagerViewModel()
            await sessionManager.configureAndLoad(bootstrap: bootstrap)

            // Auto-title sessions after the first user message so restored
            // sessions don't all remain titled "New Chat" (#1515). The word-
            // truncation path (`autoGenerateTitle`) is used here rather than
            // the inference-backed `autoRenameSession` so the hook is
            // synchronous, cheap, and available on all OS versions without
            // any backend being loaded. Hosts that want AI-generated titles
            // can replace this closure after `quickStart()` returns.
            viewModel.onFirstMessage = { [weak sessionManager] session, text in
                await sessionManager?.autoGenerateTitle(for: session, firstMessage: text)
            }

            // Wire the branch-origin chip's title resolution (#2307) the
            // same way — `ChatHistoryView` calls this closure to render
            // `BranchOriginChipView` for sessions created via `branch(from:)`.
            viewModel.resolveBranchOriginTitle = { [weak sessionManager] session in
                await sessionManager?.branchOriginTitle(for: session)
            }

            // A2-F4 + #1464: ensure the documented `quickStart()` → `ChatView()`
            // path produces a usable chat surface on first launch, and that
            // relaunch restores the previously active conversation rather than
            // a stray blank session.
            //
            // `sessionManager.sessions` is now populated (above), so we can
            // branch on it directly rather than re-fetching from persistence.
            if let restored = await sessionManager.selectInitialSession() {
                sessionManager.activeSession = restored
                await viewModel.switchToSession(restored)
            } else {
                // No persisted sessions — mint a fresh one so the composer
                // is enabled on first launch. Subsequent relaunches will go
                // through the restore branch above.
                let initialSession = ManifoldInference.ChatSession(title: "New Chat")
                try await bootstrap.persistence.insertSession(initialSession)
                await sessionManager.loadSessions()
                sessionManager.activeSession = initialSession
                await viewModel.switchToSession(initialSession)
            }

            // Opt-in seed download: when the caller supplied a `QuickStartSeed`
            // and no model is already selectable, download the curated model
            // before the selection policy runs. This ensures first-launch chat
            // is live without any additional host code.
            //
            // `_performSeedDownload` skips the download and returns `false` when
            // HuggingFace is absent, no local backend is available, or the
            // device already has a model on disk. Letting `refresh()` run
            // unconditionally after this block is safe — if no download occurred
            // the registry reflects the unchanged on-disk state.
            if let seed {
                // Foundation check: if the Foundation backend is already
                // available there is a zero-cost model — skip the download so
                // we never fetch ~484 MB unnecessarily.
                // `foundationAvailableOverride` is a test seam: the live
                // probe depends on the host's Apple Intelligence state, which
                // would make seed-path tests skip on capable machines.
                var foundationAvailable = false
                #if canImport(FoundationModels)
                if #available(iOS 26, macOS 26, *) {
                    foundationAvailable = FoundationBackend.isAvailable
                }
                #endif
                if let foundationAvailableOverride {
                    foundationAvailable = foundationAvailableOverride
                }

                // Runtime backend gate: the seed must be loadable by a backend
                // that is actually *registered* — compiled-in or injected via
                // `backends:`. A compile-time trait check here would silently
                // no-op the GGUF starter seed for consumers whose Llama-capable
                // backend arrives from a companion package at runtime (#1749).
                let seedCompatibility = bootstrap.inferenceService.compatibility(for: seed.modelType)
                if !foundationAvailable && !seedCompatibility.isSupported {
                    Log.quickStart.info("quickStart(seed:): no registered backend can load \(String(describing: seed.modelType), privacy: .public) models — seed skipped. Register a compatible backend (e.g. quickStart(backends: [LlamaBackends.self]) with the manifold-llama companion package) to enable the starter download.")
                } else if !foundationAvailable {
                    // Download machinery is always compiled in since v0.48
                    // (PR C2 — the HuggingFace trait is retired).
                    let dm: any BackgroundDownloadManaging = downloadManagerOverride
                        ?? BackgroundDownloadManager()
                    let storageService = storageServiceOverride ?? ModelStorageService()
                    _ = await _performSeedDownload(
                        seed: seed,
                        storageService: storageService,
                        downloadManager: dm
                    )
                }
            }

            // Apply the backend-selection policy (#1612). Running after session
            // wiring means the chat surface is live regardless of whether a
            // model is chosen; the composer enables itself once `selectedModel`
            // becomes non-nil.
            //
            // `refresh()` is required before the policy runs so `availableModels`
            // reflects on-disk GGUFs + the Foundation model (when the provider
            // above returned true). Failure to scan the models directory is
            // non-fatal: the empty-state path will fire, surfacing a clear
            // placeholder rather than a silent blank composer.
            do {
                try viewModel.modelRegistry.refresh()
            } catch {
                Log.quickStart.warning("quickStart: model registry refresh failed; no model will be pre-selected: \(error, privacy: .public)")
            }

            // Per-session model/endpoint IDs restored by `switchToSession` must
            // win over the global Foundation-first policy — otherwise relaunch
            // would silently swap a persisted Ollama/cloud endpoint for Foundation.
            if viewModel.selectedModel == nil, viewModel.selectedEndpoint == nil {
                let effectivePolicy = selectionPolicy ?? ManifoldKit.defaultSelectionPolicy
                let chosen = await effectivePolicy(viewModel.modelRegistry)
                if let chosen {
                    viewModel.modelRegistry.selectModel(chosen)
                } else {
                    // Neither the built-in policy nor the host-supplied policy found
                    // a model. Leave `selectedModel` nil so the UI can surface an
                    // explicit "No model available — add one to get started" state
                    // rather than a silent blank composer.
                    Log.quickStart.info("quickStart: no model selected — host UI should prompt the user to add a model")
                }
            }

            // `switchToSession` may have restored a per-session cloud endpoint.
            // When no local model was chosen, fall back to the first configured
            // endpoint so cloud-only quickStart consumers are live without a
            // separate `loadSelectedEndpoint()` call (#1473, DX 02).
            if viewModel.selectedModel == nil, viewModel.selectedEndpoint == nil {
                do {
                    let endpoints = try await bootstrap.endpointStore.fetchEndpoints()
                    viewModel.setAvailableEndpoints(endpoints)
                    if let firstEndpoint = viewModel.availableEndpoints.first {
                        viewModel.selectedEndpoint = firstEndpoint
                    }
                } catch {
                    Log.quickStart.warning("quickStart: endpoint fetch failed during auto-select: \(error, privacy: .public)")
                }
            }

            // Selection alone does not load — `ChatViewModel` requires an
            // explicit dispatch. Mirror the manual-bootstrap recipe in
            // BuildingAChatUI (dispatch after restore) so the facade path is
            // generating when it returns.
            if viewModel.selectedModel != nil || viewModel.selectedEndpoint != nil {
                viewModel.dispatchSelectedLoad()
            }

            return QuickStartResult(bootstrap: bootstrap, viewModel: viewModel, sessionManager: sessionManager)
        } catch {
            throw ManifoldKitError.from(error)
        }
    }

    // MARK: - Backend availability diagnostic

    /// Whether the host OS meets `FoundationBackends`' Apple Intelligence
    /// floor (iOS 26 / macOS 26) — mirrors the `#available` gate inside
    /// `FoundationBackends.register(with:)` exactly, so this is `true` if and
    /// only if that registrar's `declareSupport(for: .foundation)` runs.
    /// Read live at each `_quickStart` call rather than cached, matching the
    /// registrar's own always-re-checked `#available`.
    static var foundationModelsOSAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            return true
        }
        #endif
        return false
    }

    /// The actionable diagnostics ``quickStart(configuration:)`` derives from
    /// the live registration state. Internal and pure so tests can pin the
    /// decision table without driving a full bootstrap.
    enum BackendAvailabilityDiagnostic: Equatable {
        /// Nothing is registered at all — the service can never generate.
        /// `quickStart` throws `ManifoldKitError.noBackendsRegistered`.
        case noBackends
        /// Nothing is registered, but the cause can be pinned to an OS/platform
        /// gate rather than a missing registration call — e.g. every registrar
        /// passed to `quickStart(backends:)` was `FoundationBackends` and the
        /// host is below the Apple Intelligence floor (#2157). `quickStart`
        /// logs `reason` and still throws `ManifoldKitError.noBackendsRegistered`
        /// (no dedicated public case — see that case's doc comment).
        case noBackendsOSGated(reason: String)
        /// Cloud providers are registered but no local backend is, and no
        /// endpoint has been configured — the service is degraded until the
        /// host configures one. `quickStart` logs the associated message.
        case cloudOnlyWithoutEndpoint(message: String)
    }

    /// Decides which (if any) backend-availability diagnostic applies.
    ///
    /// Runtime-registration-based on purpose: compile-time trait checks cannot
    /// see backends registered by companion packages via
    /// ``quickStart(backends:configuration:seed:)``, and once cloud registrars
    /// register unconditionally a bare "count > 0" check goes permanently
    /// quiet for the local-inference failure mode.
    ///
    /// - Parameters:
    ///   - snapshot: The live registration state (declared support only —
    ///     see ``EnabledBackends``).
    ///   - configuredEndpointCount: Number of persisted cloud endpoints.
    ///   - registrars: Every registrar `quickStart` attempted to register
    ///     (compiled-in defaults + caller-supplied), used only to distinguish
    ///     ``BackendAvailabilityDiagnostic/noBackends`` from
    ///     ``BackendAvailabilityDiagnostic/noBackendsOSGated(reason:)`` when
    ///     `snapshot` is empty. Defaults to `[]` so existing callers (and
    ///     tests pinning the pre-#2157 decision table) are unaffected.
    ///   - foundationModelsOSAvailable: Whether the host OS meets the
    ///     Foundation Models floor (iOS 26 / macOS 26). Injectable so this
    ///     stays a pure function testable on every OS version. Defaults to
    ///     `true` (i.e. "assume no OS gate") so existing callers see
    ///     unchanged behavior.
    static func backendAvailabilityDiagnostic(
        snapshot: EnabledBackends,
        configuredEndpointCount: Int,
        registrars: [any BackendRegistrar.Type] = [],
        foundationModelsOSAvailable: Bool = true
    ) -> BackendAvailabilityDiagnostic? {
        if snapshot.isEmpty {
            // Every OS-gated registrar this core package ships is
            // `FoundationBackends`: `register(with:)` always runs (it is not
            // itself `#available`-gated), but the `declareSupport(for:)` call
            // inside it only fires when the host meets the iOS 26 / macOS 26
            // floor — so a factory can be registered while `snapshot` stays
            // empty. Detecting this precisely (rather than guessing) only
            // works for the one gate this package can introspect; a
            // companion-package registrar (manifold-mlx / manifold-llama)
            // that is itself OS/hardware-gated is invisible here and still
            // falls through to the generic `.noBackends` diagnostic.
            if !foundationModelsOSAvailable,
               registrars.contains(where: { $0 == FoundationBackends.self }) {
                return .noBackendsOSGated(reason: """
                    FoundationBackends was registered, but the host OS is below the \
                    Apple Intelligence floor (iOS 26 / macOS 26) that Foundation \
                    Models requires, so it declared no supported model type. \
                    Upgrade the OS, or register a different backend — a cloud \
                    endpoint (bootstrap.endpointStore.insertEndpoint(_:)) or a \
                    companion local backend (quickStart(backends: [LlamaBackends.self]) \
                    for GGUF, [MLXBackends.self] for MLX).
                    """)
            }
            return .noBackends
        }
        if !snapshot.supportsLocalInference && configuredEndpointCount == 0 {
            return .cloudOnlyWithoutEndpoint(message: """
                quickStart: no local inference backend is registered and no cloud \
                endpoint is configured — the chat surface will launch but cannot \
                generate. To enable local inference, add a backend package \
                (manifold-llama for GGUF, manifold-mlx for MLX) and pass its \
                registrar: ManifoldKit.quickStart(backends: [LlamaBackends.self]). \
                To use a cloud provider instead, insert an APIEndpointRecord via \
                bootstrap.endpointStore and select it before the first send.
                """)
        }
        return nil
    }

    // MARK: - Built-in selection policy

    /// The default backend-selection policy applied by `quickStart()`.
    ///
    /// Priority order:
    /// 1. Foundation model — selected when running on iOS 26+ / macOS 26+ and
    ///    a Foundation-capable backend is *registered* and available at runtime.
    /// 2. First **loadable** local model — the first entry in `availableModels`
    ///    (populated by `refresh()`) whose ``ModelType`` has a registered
    ///    backend. On-disk files with no registered backend are skipped: a
    ///    GGUF on disk with no Llama-capable backend would otherwise be
    ///    "selected", compile clean, and fail confusingly on the first send.
    /// 3. Nil — no model is pre-selected; the UI must prompt the user to add one.
    ///
    /// All compatibility checks go through ``ModelRegistry/compatibility(for:)``
    /// (live registration state) rather than compile-time trait reflection, so
    /// backends injected via ``quickStart(backends:configuration:seed:)`` are
    /// honoured.
    @MainActor
    static func defaultSelectionPolicy(_ registry: ModelRegistry) async -> ModelInfo? {
        // Foundation-first: on Apple-Intelligence-capable devices the built-in
        // model is always the lowest-friction starting point — no download, no
        // disk space, no endpoint configuration required.
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            if registry.compatibility(for: .foundation).isSupported,
               let provider = registry.foundationModelProvider, provider() {
                return .builtInFoundation
            }
        }
        #endif

        // Fall back to the first local model discovered on disk *that some
        // registered backend can load*. All ModelType cases (.gguf, .mlx,
        // .foundation) represent local backends — there is no "remote"
        // ModelType in the registry (cloud backends are addressed through
        // APIEndpointRecord + APIProvider, not ModelInfo).
        for model in registry.availableModels {
            if registry.compatibility(for: model.modelType).isSupported {
                return model
            }
            Log.quickStart.info("quickStart: skipping \(model.fileName, privacy: .public) — no registered backend can load \(String(describing: model.modelType), privacy: .public) models. Add the matching backend package (manifold-llama for GGUF, manifold-mlx for MLX) and pass its registrar to quickStart(backends:).")
        }
        return nil
    }
}

/// The result returned by ``ManifoldKit/quickStart(configuration:)``.
///
/// `bootstrap` owns the inference service, SwiftData container, persistence
/// adapters, and `ConversationRuntime`. Retain it for the lifetime of the
/// chat runtime — releasing it tears down the underlying services.
///
/// `viewModel` is the `ChatViewModel` wired against `bootstrap`. Pass it to
/// `ChatView` (or your own SwiftUI surface) as you would a manually
/// constructed view model.
///
/// `sessionManager` is a `SessionManagerViewModel` configured against the
/// same bootstrap and with its initial session page already loaded (#1425).
/// Pass it to a sidebar or session-list surface alongside `viewModel` — no
/// additional `configure` or `loadSessions` call is required.
///
/// `QuickStartResult` is `Sendable` because all fields are `@MainActor`
/// reference types; the struct itself carries no mutable state.
@MainActor
public struct QuickStartResult: Sendable {
    public let bootstrap: ManifoldBootstrap
    public let viewModel: ChatViewModel
    /// A session manager pre-wired to `bootstrap` with the initial session
    /// page already loaded. Use this to drive multi-session UI (sidebar,
    /// create/delete/rename) without additional setup.
    public let sessionManager: SessionManagerViewModel

    public init(
        bootstrap: ManifoldBootstrap,
        viewModel: ChatViewModel,
        sessionManager: SessionManagerViewModel
    ) {
        self.bootstrap = bootstrap
        self.viewModel = viewModel
        self.sessionManager = sessionManager
    }

    /// Sends `text` and returns the assistant's reply as a `String`.
    ///
    /// One-hop convenience over ``ChatViewModel/respond(to:)`` so consumers can
    /// write `try await kit.respond(to: "…")` without the `.viewModel`
    /// indirection. Throws the same ``SendMessageError`` cases.
    ///
    /// This is the single spelling for this operation — the duplicate
    /// `respond(_:)` (unlabeled) form was removed in the same release that
    /// added this doc note (2026-07 API review, item 2.4): the two spellings
    /// were behaviorally identical (`sendMessage(text).content`), so keeping
    /// both was pure API surface with no functional difference. `respond(to:)`
    /// matches Swift API design guidelines (a preposition names the argument's
    /// role) and is the spelling `LLM.respond(to:)` and
    /// `ChatViewModel.respond(to:)` already use.
    @discardableResult
    public func respond(to text: String) async throws -> String {
        try await viewModel.respond(to: text)
    }
}

// MARK: - ManifoldConfiguration.default

extension ManifoldConfiguration {
    /// A sensible default configuration for demos, tests, and getting-started
    /// snippets.
    ///
    /// Equivalent to `ManifoldConfiguration()` — all init parameters take
    /// their defaults. The bundle identifier is the framework default
    /// (`com.manifoldkit`); production apps should override it so two apps
    /// using ManifoldKit don't collide on the shared SwiftData store path.
    public static var `default`: ManifoldConfiguration {
        ManifoldConfiguration()
    }
}
