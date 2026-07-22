// ManifoldBootstrap+GenerationToolSources.swift
//
// Convenience wiring that bridges ManifoldPersistenceSwiftData (ManifoldBootstrap)
// with ManifoldUI (ImageGenerationToolSource, VideoGenerationToolSource, ChatViewModel).
// Lives in the ManifoldKit umbrella — the only target that imports both modules —
// to avoid a layering violation.

import ManifoldPersistenceSwiftData
import ManifoldUI

extension ManifoldBootstrap {

    /// Registers `ImageGenerationToolSource` and `VideoGenerationToolSource`
    /// on the bootstrap's runtime so the active language model can invoke
    /// the `generate_image` and `generate_video` tools.
    ///
    /// Call after wiring the `ChatViewModel` and after the bootstrap has been
    /// fully configured:
    ///
    /// ```swift
    /// await bootstrap.addGenerationToolSources(viewModel: chatViewModel)
    /// ```
    ///
    /// Each source is only active when the bootstrap has the corresponding
    /// surface wired: `ImageGenerationToolSource` requires
    /// `imageGenerationService` to be non-nil;
    /// `VideoGenerationToolSource` requires
    /// `videoGenerationService` to be non-nil;
    /// `WebSearchToolSource` requires
    /// `webSearchRuntime` to be non-nil. Sources for
    /// unwired surfaces are silently skipped so the call is safe to issue
    /// unconditionally regardless of which generation surfaces your app enables.
    ///
    /// This replaces the more verbose:
    /// ```swift
    /// await bootstrap.addToolSources([
    ///     ImageGenerationToolSource(viewModel: chatVM),
    ///     VideoGenerationToolSource(viewModel: chatVM),
    ///     WebSearchToolSource(viewModel: chatVM)
    /// ])
    /// ```
    @MainActor
    public func addGenerationToolSources(viewModel: ChatViewModel) async {
        var sources: [any SessionToolSource] = []
        if imageGenerationService != nil {
            sources.append(ImageGenerationToolSource(viewModel: viewModel))
        }
        if videoGenerationService != nil {
            sources.append(VideoGenerationToolSource(viewModel: viewModel))
        }
        if webSearchRuntime != nil {
            sources.append(WebSearchToolSource(viewModel: viewModel))
        }
        guard !sources.isEmpty else {
            // `ManifoldKit.quickStart(...)` never passes imageGenerationService /
            // videoGenerationService / webSearchRuntime to `ManifoldBootstrap.build`
            // (see docs/plans/inert-code-audit-2026-07.md #41), so a bootstrap
            // built via quickStart always lands here. Warn loudly instead of
            // returning silently — a host that followed the documented
            // `addGenerationToolSources(viewModel:)` recipe would otherwise see
            // no tool calls and no signal explaining why.
            Log.ui.warning("addGenerationToolSources: no generation surfaces wired — imageGenerationService, videoGenerationService, and webSearchRuntime are all nil on this ManifoldBootstrap, so no tool sources were registered. Pass one or more of these directly to ManifoldBootstrap.build(...) before calling addGenerationToolSources(viewModel:); ManifoldKit.quickStart(...) does not wire them (tracked in #1903).")
            return
        }
        await addToolSources(sources)
    }
}
