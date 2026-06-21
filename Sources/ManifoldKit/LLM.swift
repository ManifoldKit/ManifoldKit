// LLM — value-typed convenience front door (#1942 D2).
//
// A two-line entry point in the spirit of LLM.swift: construct an `LLM`, call
// `.respond(to:)`. It wraps the existing `quickStart` plumbing — there is no
// new bootstrap path here. `LLM.init` drives `ManifoldKit.quickStart(...)`,
// retains the resulting `QuickStartResult` (which owns the bootstrap lifetime),
// and exposes a String-typed `respond(to:)` over the wrapped `ChatViewModel`.
//
// Registrar default (#1942 D2, decided): `backends:` defaults to
// `ManifoldKit.defaultBackendRegistrars` (the compiled-in cloud + Foundation
// families). A cloud/Foundation `LLM` is therefore genuinely two lines; a LOCAL
// model requires the caller to pass `backends: [LlamaBackends.self]` (and import
// the manifold-llama companion package). See the doc-comment on `init`.

import Foundation
import ManifoldInference
import ManifoldUI

/// A value-typed convenience front door to a working chat runtime.
///
/// `LLM` collapses bootstrap + model selection + a single-turn reply into two
/// lines, in the spirit of LLM.swift:
///
/// ```swift
/// let llm = try await LLM(from: .recommendedSmallModel())
/// let answer = try await llm.respond(to: "Explain monads in one sentence.")
/// ```
///
/// It is a thin wrapper over ``ManifoldKit/quickStart(backends:configuration:seed:)``:
/// the initializer drives that plumbing and retains the resulting
/// ``QuickStartResult`` (which owns the bootstrap and therefore the underlying
/// services). Releasing the `LLM` releases the runtime.
///
/// ### Backends
///
/// `backends:` defaults to ``ManifoldKit/defaultBackendRegistrars`` — the
/// compiled-in cloud (Ollama + SaaS) and Apple Foundation families. So a
/// cloud/Foundation `LLM` is genuinely two lines. A **local** model needs a
/// companion-package registrar:
///
/// ```swift
/// import ManifoldKit
/// import ManifoldLlama   // manifold-llama companion package
///
/// let llm = try await LLM(
///     from: .recommendedSmallModel(),
///     backends: [LlamaBackends.self]
/// )
/// ```
///
/// ### Templates
///
/// `template:` accepts a ``ChatTemplate`` to override the model's formatting.
/// For a ``ChatTemplate`` built from the hand-rolled enum fallback
/// (`ChatTemplate(builtIn:)`) the override is applied to the live render path.
/// An embedded-Jinja template (`ChatTemplate(embeddedJinja:)`) is **not** yet
/// wired — the raw-template channel has no public injection seam (it is set only
/// at model load). Passing one is harmless: construction succeeds and the
/// model's own embedded template is used.
@MainActor
public struct LLM {

    /// The retained bootstrap + view model + session manager from `quickStart`.
    /// `LLM` owns this for its lifetime; releasing the `LLM` tears down the
    /// underlying services.
    private let result: QuickStartResult

    /// The wrapped chat view model, exposed for callers that need to drop down
    /// to the full ``ChatViewModel`` surface (model selection, session
    /// management, the full ``ChatMessage`` from a turn). The String-typed
    /// ``respond(to:)`` covers the common case.
    public var viewModel: ChatViewModel { result.viewModel }

    /// Constructs a working chat runtime seeded for `model`.
    ///
    /// Drives ``ManifoldKit/quickStart(backends:configuration:seed:)`` to a live
    /// runtime: the seed downloads the curated model on first launch when no
    /// model is already selectable (Foundation available, or a model on disk),
    /// then the selection policy picks it. Errors are surfaced through the same
    /// unified ``ManifoldKitError`` rim as `quickStart`.
    ///
    /// - Parameters:
    ///   - model: The model seed. Use ``QuickStartSeed/recommendedSmallModel(onProgress:)``
    ///     for the curated 0.6B floor, or ``QuickStartSeed/recommended(useCase:device:foundationAvailable:onProgress:)``
    ///     for a device-aware pick. The seed is a no-op when a model is already
    ///     selectable or no registered backend can load its type.
    ///   - template: Optional formatting override. A ``ChatTemplate(builtIn:)``
    ///     is applied to the render path; a ``ChatTemplate(embeddedJinja:)`` is
    ///     accepted but not yet wired (see the type doc-comment). `nil` (the
    ///     default) uses the model's embedded/default template.
    ///   - backends: Backend registrars. Defaults to
    ///     ``ManifoldKit/defaultBackendRegistrars`` (cloud + Foundation). Pass a
    ///     companion-package registrar (e.g. `[LlamaBackends.self]`) for local
    ///     models.
    ///   - configuration: Framework configuration. Defaults to
    ///     `ManifoldConfiguration.default`.
    public init(
        from model: QuickStartSeed,
        template: ChatTemplate? = nil,
        backends: [any BackendRegistrar.Type] = ManifoldKit.defaultBackendRegistrars,
        configuration: ManifoldConfiguration = .default
    ) async throws {
        let result = try await ManifoldKit.quickStart(
            backends: backends,
            configuration: configuration,
            seed: model
        )
        Self.apply(template: template, to: result.viewModel)
        self.result = result
    }

    /// Test/host seam: wraps a pre-assembled ``QuickStartResult`` (e.g. one
    /// built over an in-memory bootstrap with a mock backend) without standing
    /// up a real model download. Production callers use ``init(from:template:backends:configuration:)``.
    package init(result: QuickStartResult, template: ChatTemplate? = nil) {
        Self.apply(template: template, to: result.viewModel)
        self.result = result
    }

    /// Applies a caller-supplied template to the live render path where a public
    /// seam exists.
    ///
    /// Only the ``ChatTemplate/builtInPromptTemplate`` (enum-fallback) channel is
    /// reachable today via ``ChatViewModel/selectedPromptTemplate``. The embedded
    /// raw-Jinja channel (`selectedChatTemplateRaw`) is `private(set)` and set
    /// only at model load, so a full override there needs render-seam work.
    // TODO(#1942 D2): full template override pending render-seam work — wire the
    // embedded-Jinja channel once `selectedChatTemplateRaw` has a public setter.
    private static func apply(template: ChatTemplate?, to viewModel: ChatViewModel) {
        guard let promptTemplate = template?.builtInPromptTemplate else { return }
        viewModel.selectedPromptTemplate = promptTemplate
    }

    /// Sends `text` and returns the assistant's reply as a `String`.
    ///
    /// Delegates to ``ChatViewModel/respond(to:)`` (#1942 D1) — the stream
    /// drain, persistence, and single-turn drive are inherited unchanged.
    /// Throws the same ``SendMessageError`` cases.
    @discardableResult
    public func respond(to text: String) async throws -> String {
        try await result.respond(to: text)
    }
}
