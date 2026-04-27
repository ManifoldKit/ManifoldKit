import Foundation
import BaseChatCore
import BaseChatInference
import BaseChatTools

/// Composition root for the demo's tool layer.
///
/// Resolves an app-owned sandbox directory, seeds it with a small fixture
/// "workspace" on first launch, and registers the reference toolset on a
/// ``ToolRegistry``. The seeded fixture exists so the demo's hero tool
/// (``SampleRepoSearchTool``) has something to search without the user
/// having to drop their own files in.
enum DemoTools {

    /// Names of the tools registered by ``register(on:root:)``. Used by the
    /// scenario runner to clear out variant executors and snap back to the
    /// baseline set when a scenario starts.
    static let baselineNames: [String] = [
        "calc",
        "now",
        "read_file",
        "list_dir",
        "sample_repo_search",
        "write_file"
    ]

    /// Registers the full reference toolset on `registry`.
    ///
    /// Runs synchronously on the main actor because ``ToolRegistry`` is
    /// MainActor-isolated. Seeding is idempotent — the on-disk fixture is
    /// only written when absent, so repeated launches are cheap.
    @MainActor
    static func register(on registry: ToolRegistry, root: URL = DemoToolRoot.resolve()) {
        do {
            try DemoToolRoot.seedIfNeeded(at: root)
        } catch {
            // Fail open: the tools still work for files the user adds later,
            // and the seed content is a nice-to-have rather than a contract.
            Log.inference.warning("DemoTools: failed to seed fixture workspace at \(root.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }

        registry.register(CalcTool.makeExecutor())
        registry.register(DemoNowTool.makeExecutor())
        registry.register(ReadFileTool.makeExecutor(root: root))
        registry.register(ListDirTool.makeExecutor(root: root))
        registry.register(SampleRepoSearchTool.makeExecutor(root: root))
        registry.register(WriteFileTool.makeExecutor(root: root))
    }

    /// Restores `registry` to the baseline tool set.
    ///
    /// Used by ``DemoScenarioRunner`` to drop any variant executors a previous
    /// scenario may have installed (e.g. a deliberately-slow `sample_repo_search`
    /// for the cancellation scenario) before starting a new one. Idempotent.
    @MainActor
    static func resetToDefaults(on registry: ToolRegistry, root: URL = DemoToolRoot.resolve()) {
        for name in baselineNames {
            registry.unregister(name: name)
        }
        register(on: registry, root: root)
    }
}

/// Resolves and seeds the demo's filesystem-tool sandbox.
enum DemoToolRoot {

    /// Returns the app-owned sandbox root. Creates the parent directory lazily.
    static func resolve() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory

        let root = base
            .appendingPathComponent("BaseChatDemo", isDirectory: true)
            .appendingPathComponent("ToolRoot", isDirectory: true)

        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Writes the bundled fixture workspace under `root` when it isn't there.
    ///
    /// The seed is keyed by a marker file; we do not diff contents across
    /// launches. If the user edits a seeded file we respect their choice. If
    /// they delete the entire workspace (leaving only the marker, or nothing
    /// at all) we re-seed so demo scenarios that search the fixture don't
    /// silently look broken.
    static func seedIfNeeded(at root: URL) throws {
        let fm = FileManager.default
        let marker = root.appendingPathComponent(".seeded", isDirectory: false)

        if fm.fileExists(atPath: marker.path) {
            // Re-seed only when the marker is the sole survivor — not when
            // user content lives alongside it.
            let contents = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
            let nonMarker = contents.filter { $0 != ".seeded" }
            if !nonMarker.isEmpty { return }
        }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, contents) in Self.fixture {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try Data("1".utf8).write(to: marker)
    }

    private static let fixture: [(String, String)] = [
        ("README.md", """
        # Sample Workspace

        This is a small fixture workspace the demo uses to showcase tool calling.
        Ask the assistant to summarize the README files, search for a keyword,
        or read a specific file — it will invoke the sandboxed filesystem tools.
        """),
        ("notes/ideas.md", """
        # Product Ideas

        - Offline-first note app with local embeddings.
        - A CLI that replays a chat transcript through a different model.
        - Voice memos transcribed via on-device speech, summarized at close of day.
        - A fuzzer harness for long-context chat backends.
        """),
        ("notes/meeting-2026-04-15.md", """
        # Planning meeting — April 15 2026

        Attendees: Rory, Claude
        Decisions:
        - Ship tool-calling UI before 1.0.
        - Defer voice module until post-launch.
        - Unify deep-link / AppIntent / share-extension handoff behind InboundPayload.
        """),
        ("docs/architecture.md", """
        # Architecture Overview

        BaseChatKit has five public targets:
        - BaseChatInference — protocols and orchestration.
        - BaseChatCore — SwiftData persistence.
        - BaseChatBackends — MLX, llama.cpp, Foundation, and cloud backends.
        - BaseChatUI — SwiftUI views and view models.
        - BaseChatTools — reference tools and the fuzzing harness.
        """),
        ("docs/tool-calling.md", """
        # Tool Calling

        Register a ToolExecutor on the ToolRegistry you pass to InferenceService.
        The GenerationCoordinator dispatches ToolCall events through the registry
        and threads the ToolResult back into the conversation.
        """),
        ("projects/scout/spec.md", """
        # Scout — local research companion (draft)

        Scout is a Mac-first agent app built on BaseChatKit. It surfaces:
        - Filesystem tool calling with per-call approval.
        - Live thinking streams from reasoning models.
        - MCP server integration for third-party tools.
        """),
        ("projects/scout/roadmap.md", """
        # Roadmap

        - [ ] Tool approval UI
        - [ ] MCP client
        - [ ] Share Extension summarize-selection flow
        - [ ] App Intents for Spotlight and Siri
        """),
        ("shopping-list.txt", """
        milk
        eggs
        coffee
        olive oil
        """),
        ("journal/2026-04-22.md", """
        # 22 Apr 2026

        Shipped the thinking-tokens super-session. 11 PRs merged, four reviews
        came back in parallel, scope held. Next up: tool-calling demo in the
        example app.
        """),
        ("journal/2026-04-23.md", """
        # 23 Apr 2026

        Pivoted on the demo strategy — instead of a third example app, we're
        upgrading BaseChatDemo in place. Plan approved after PM / architect /
        engineer / QA reviews.
        """),
    ]
}
