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
import ManifoldBackends
import ManifoldUI

/// The umbrella namespace for ManifoldKit's high-level entry points.
///
/// Today this hosts ``ManifoldKit/ManifoldKit/quickStart(configuration:)``;
/// future top-level conveniences will land here so adopters have one
/// well-known place to look.
@MainActor
public enum ManifoldKit {

    /// Bootstraps a working chat runtime with sensible defaults in one call.
    ///
    /// Internally this:
    /// 1. Drives ``ManifoldBootstrap/build(configuration:inferenceService:imageGenerationService:diagnostics:makeModelContainer:)``
    ///    to completion (consuming its progress milestones).
    /// 2. Registers the compiled-in default backends via
    ///    ``DefaultBackends/register(with:)``.
    /// 3. Constructs a ``ChatViewModel`` wired to the bootstrap's shared
    ///    ``InferenceService``, persistence stores, and ``ConversationRuntime``.
    ///
    /// Errors thrown by any step are reduced through ``ManifoldKitError/from(_:)``
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
    ///   ``ManifoldInference/ManifoldConfiguration/default`` — fine for
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

    /// Internal seam used by tests to inject a custom (or throwing) model
    /// container factory and an optional selection policy. Production callers
    /// go through ``quickStart(configuration:)``.
    ///
    /// - Parameters:
    ///   - configuration: The framework configuration.
    ///   - makeModelContainer: Factory closure that produces the SwiftData container.
    ///   - selectionPolicy: An optional closure that receives the populated
    ///     `ModelRegistry` and returns the `ModelInfo` to select, or `nil` to
    ///     leave no model selected. When `nil` (the default), the built-in
    ///     Foundation-first → first-local → labeled-empty-state policy runs.
    static func _quickStart(
        configuration: ManifoldConfiguration,
        makeModelContainer: @MainActor @escaping () throws -> ModelContainer,
        selectionPolicy: (@MainActor (ModelRegistry) async -> ModelInfo?)? = nil
    ) async throws -> QuickStartResult {
        do {
            // Drive the bootstrap stream to completion. We don't surface
            // milestones from the simple facade — `quickStart()` is the
            // "no progress UI" path. Consumers that want a launch
            // progress bar should call `ManifoldBootstrap.build` directly.
            let (progress, task) = ManifoldBootstrap.build(
                configuration: configuration,
                makeModelContainer: makeModelContainer
            )
            for await _ in progress {
                // Consume so the buffered stream doesn't grow unboundedly.
                // The bootstrap task drives `continuation.finish()` itself.
            }

            let bootstrap = try await task.value

            // Fail fast when the build compiled in zero backends for the active
            // trait / OS combination. Without this the app launches fully wired
            // — persistence, session list, composer enabled — then throws on the
            // first turn with a confusing "No model loaded". Surfacing it here,
            // at the assembly boundary, names the actual cause (missing traits).
            let registeredBackends = DefaultBackends.register(with: bootstrap.inferenceService)
            guard registeredBackends > 0 else {
                throw ManifoldKitError.noBackendsRegistered
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

            return QuickStartResult(bootstrap: bootstrap, viewModel: viewModel, sessionManager: sessionManager)
        } catch {
            throw ManifoldKitError.from(error)
        }
    }

    // MARK: - Built-in selection policy

    /// The default backend-selection policy applied by `quickStart()`.
    ///
    /// Priority order:
    /// 1. Foundation model — selected when running on iOS 26+ / macOS 26+ and
    ///    the Foundation backend is compiled in and available at runtime.
    /// 2. First local model — the first entry in `availableModels` (populated
    ///    by `refresh()`), which skips cloud/endpoint-configured backends that
    ///    have no `ModelInfo` representation in the registry.
    /// 3. Nil — no model is pre-selected; the UI must prompt the user to add one.
    @MainActor
    static func defaultSelectionPolicy(_ registry: ModelRegistry) async -> ModelInfo? {
        // Foundation-first: on Apple-Intelligence-capable devices the built-in
        // model is always the lowest-friction starting point — no download, no
        // disk space, no endpoint configuration required.
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            if DefaultBackends.canLoad(modelType: .foundation),
               let provider = registry.foundationModelProvider, provider() {
                return .builtInFoundation
            }
        }
        #endif

        // Fall back to the first local model discovered on disk. All ModelType
        // cases (.gguf, .mlx, .foundation) represent local backends — there is
        // no "remote" ModelType in the registry (cloud backends are addressed
        // through APIEndpointRecord + APIProvider, not ModelInfo).
        return registry.availableModels.first
    }
}

/// The result returned by ``ManifoldKit/ManifoldKit/quickStart(configuration:)``.
///
/// `bootstrap` owns the inference service, SwiftData container, persistence
/// adapters, and ``ConversationRuntime``. Retain it for the lifetime of the
/// chat runtime — releasing it tears down the underlying services.
///
/// `viewModel` is the ``ChatViewModel`` wired against `bootstrap`. Pass it to
/// `ChatView` (or your own SwiftUI surface) as you would a manually
/// constructed view model.
///
/// `sessionManager` is a ``SessionManagerViewModel`` configured against the
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
