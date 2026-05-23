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
    /// // kit.viewModel — a configured ChatViewModel
    /// // kit.bootstrap — keep alive for the lifetime of the app
    /// ```
    ///
    /// - Parameter configuration: The framework configuration. Defaults to
    ///   ``ManifoldInference/ManifoldConfiguration/default`` — fine for
    ///   demos and tests, but production apps should pass an explicit
    ///   configuration with their own bundle identifier.
    /// - Returns: A ``QuickStartResult`` carrying both the bootstrap and the
    ///   view model. The caller owns the bootstrap and must retain it for
    ///   the lifetime of the chat runtime.
    public static func quickStart(
        configuration: ManifoldConfiguration = .default
    ) async throws -> QuickStartResult {
        try await _quickStart(
            configuration: configuration,
            makeModelContainer: { try ModelContainerFactory.makeContainer() }
        )
    }

    /// Internal seam used by tests to inject a custom (or throwing) model
    /// container factory. Production callers go through ``quickStart(configuration:)``.
    static func _quickStart(
        configuration: ManifoldConfiguration,
        makeModelContainer: @MainActor @escaping () throws -> ModelContainer
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

            DefaultBackends.register(with: bootstrap.inferenceService)

            let viewModel = ChatViewModel(
                inferenceService: bootstrap.inferenceService,
                conversationRuntime: bootstrap.conversationRuntime
            )
            viewModel.configure(persistence: bootstrap.persistence)
            viewModel.configure(endpointStore: bootstrap.endpointStore)

            // A2-F4: ensure the documented `quickStart()` → `ChatView()` path
            // produces a usable chat surface on first launch. `ChatView`
            // disables its composer when `viewModel.activeSession == nil`, so
            // a fresh install (no persisted sessions) would otherwise render
            // a "No session selected" placeholder with no documented way to
            // create one through the high-level API.
            //
            // We auto-create a single empty session iff the store is empty.
            // When sessions already exist (relaunch, restored backup, host
            // app that created its own session first), this is a no-op and
            // the host's existing selection logic takes over.
            //
            // Model loading is intentionally orthogonal — a session with no
            // model loaded still unblocks the composer, and the welcome
            // empty-state for model selection lives in `ChatView`. See
            // A2-F1 for the separate "auto-select a model when available"
            // gap.
            let existingSessions = try await bootstrap.persistence.fetchSessions(offset: 0, limit: 1)
            if existingSessions.isEmpty {
                let initialSession = ChatSessionRecord(title: "New Chat")
                try await bootstrap.persistence.insertSession(initialSession)
                await viewModel.switchToSession(initialSession)
            } else if let mostRecent = existingSessions.first {
                await viewModel.switchToSession(mostRecent)
            }

            return QuickStartResult(bootstrap: bootstrap, viewModel: viewModel)
        } catch {
            throw ManifoldKitError.from(error)
        }
    }
}

/// The pair returned by ``ManifoldKit/ManifoldKit/quickStart(configuration:)``.
///
/// `bootstrap` owns the inference service, SwiftData container, persistence
/// adapters, and ``ConversationRuntime``. Retain it for the lifetime of the
/// chat runtime — releasing it tears down the underlying services.
///
/// `viewModel` is the ``ChatViewModel`` wired against `bootstrap`. Pass it to
/// `ChatView` (or your own SwiftUI surface) as you would a manually
/// constructed view model.
///
/// `QuickStartResult` is `Sendable` because both fields are `@MainActor`
/// reference types; the struct itself carries no mutable state.
@MainActor
public struct QuickStartResult: Sendable {
    public let bootstrap: ManifoldBootstrap
    public let viewModel: ChatViewModel

    public init(bootstrap: ManifoldBootstrap, viewModel: ChatViewModel) {
        self.bootstrap = bootstrap
        self.viewModel = viewModel
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
