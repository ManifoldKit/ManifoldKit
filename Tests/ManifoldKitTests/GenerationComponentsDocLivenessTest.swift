// GenerationComponentsDocLivenessTest.swift
//
// Tripwire for the "quickStart() + addToolSources(_:) silently registers a
// non-functional generation tool" trap (audit item #41 in
// docs/plans/inert-code-audit-2026-07.md, tracked under #2128 / #1903).
//
// `ManifoldKit.quickStart(...)` never passes `imageGenerationService` /
// `videoGenerationService` / `webSearchRuntime` through to
// `ManifoldBootstrap.build(...)`, so a bootstrap built via quickStart always
// has all three nil. Registering `ImageGenerationToolSource` /
// `VideoGenerationToolSource` / `WebSearchToolSource` against such a
// bootstrap via `addToolSources(_:)` still advertises the tool to the model
// — NEITHER of the three throws when invoked (a #2441 review correction:
// this file previously and incorrectly claimed they did). Each reports the
// failure as a `ToolResult` instead, and the shape differs by source:
// `ImageGenerationToolSource` / `VideoGenerationToolSource` preflight the
// missing service and return `errorKind: .permanent`; `WebSearchToolSource`
// has no preflight, forwards to `ChatViewModel.searchWeb(query:)` (which
// does throw `ChatViewModelWebSearchError.notConfigured`), and its
// catch-all reports that as `errorKind: .transient` — retryable-looking to
// the model, unlike the other two. (The wrapper that used to skip-and-warn
// on this case, `addGenerationToolSources(viewModel:)`, was retired in
// #2440 along with the clobbering bug it was hiding — see
// docs/MIGRATION-additive-tool-sources.md.)
// Two things must stay true together:
//
//   1. That behavior is real (verified against source, not assumed).
//   2. GenerationComponents.md's "Registering tool sources" recipe does not
//      claim the bare `quickStart()` + `addToolSources(_:)` combination
//      works — it must carry the caveat.
//
// If a future edit "simplifies" the doc back to the bare recipe without the
// caveat, this test must fail.

import XCTest
import SwiftData
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldKit
// NOTE: ImageGenerationToolSource / VideoGenerationToolSource /
// WebSearchToolSource (ManifoldUI) are used below without an explicit
// `import ManifoldUI` — ManifoldKit's umbrella `@_exported import ManifoldUI`
// (Sources/ManifoldKit/Exports.swift) re-exports them to any file that
// imports ManifoldKit, testable or not. Confirmed by this file compiling
// with no direct ManifoldKitTests -> ManifoldUI Package.swift edge (#2441
// review F3) — do not add one back without checking this still holds.

@MainActor
final class GenerationComponentsDocLivenessTest: XCTestCase {

    // MARK: - Behavior: quickStart wires none of the three generation surfaces

    /// A bootstrap built the way `quickStart()` builds one — no
    /// `imageGenerationService` / `videoGenerationService` / `webSearchRuntime`
    /// passed to `ManifoldBootstrap.build(...)` — must have all three nil.
    /// Registering the three generation tool sources via `addToolSources(_:)`
    /// against such a bootstrap must not crash. Proven without requiring a
    /// new tool-source-count accessor on `ConversationRuntime` (out of scope
    /// here per the "no new public API" guard).
    ///
    /// Then actually invokes each source's `resolve(toolName:arguments:session:)`
    /// and asserts the `ToolResult.errorKind` this file's header comment (and
    /// GenerationComponents.md's caveat) claims — proving the doc-scan test
    /// below isn't asserting something nobody checked against real behavior
    /// (#2441 review F6).
    func test_plainQuickStartBootstrap_hasNoGenerationSurfacesWired() async throws {
        let result = try await ManifoldKit._quickStart(
            configuration: .default,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        XCTAssertNil(result.bootstrap.imageGenerationService,
            "quickStart() must not wire imageGenerationService (see #1903) — if this now passes, the generation tool sources are live for image gen and GenerationComponents.md's caveat needs updating.")
        XCTAssertNil(result.bootstrap.videoGenerationService,
            "quickStart() must not wire videoGenerationService (see #1903) — if this now passes, the generation tool sources are live for video gen and GenerationComponents.md's caveat needs updating.")
        XCTAssertNil(result.bootstrap.webSearchRuntime,
            "quickStart() must not wire webSearchRuntime (see #1903) — if this now passes, the generation tool sources are live for web search and GenerationComponents.md's caveat needs updating.")

        // Exercise the real call path — the documented recipe, against a
        // quickStart bootstrap where every backing service is nil. Must not
        // crash.
        await result.bootstrap.addToolSources([
            ImageGenerationToolSource(viewModel: result.viewModel),
            VideoGenerationToolSource(viewModel: result.viewModel),
            WebSearchToolSource(viewModel: result.viewModel)
        ])

        // Now actually invoke each source and check what the model would see.
        // `session` isn't consulted on the not-configured path of any of the
        // three sources, so a bare placeholder is enough.
        let session = ChatSession(title: "doc-liveness")

        let imageResult = try await ImageGenerationToolSource(viewModel: result.viewModel).resolve(
            toolName: "generate_image",
            arguments: #"{"prompt": "a cat"}"#,
            session: session
        )
        XCTAssertEqual(imageResult.errorKind, .permanent,
            "ImageGenerationToolSource must preflight the missing imageRuntime and report errorKind: .permanent — it does NOT throw. If this fails, GenerationComponents.md's behavior claim needs updating.")

        let videoResult = try await VideoGenerationToolSource(viewModel: result.viewModel).resolve(
            toolName: "generate_video",
            arguments: #"{"prompt": "a cat"}"#,
            session: session
        )
        XCTAssertEqual(videoResult.errorKind, .permanent,
            "VideoGenerationToolSource must preflight the missing videoRuntime and report errorKind: .permanent — it does NOT throw. If this fails, GenerationComponents.md's behavior claim needs updating.")

        let searchResult = try await WebSearchToolSource(viewModel: result.viewModel).resolve(
            toolName: "search_web",
            arguments: #"{"query": "cats"}"#,
            session: session
        )
        XCTAssertEqual(searchResult.errorKind, .transient,
            "WebSearchToolSource has no preflight — it forwards to ChatViewModel.searchWeb(query:), which throws ChatViewModelWebSearchError.notConfigured, and the source's catch-all reports that as errorKind: .transient (retryable-looking), not .permanent like the other two. If this fails, GenerationComponents.md's behavior claim needs updating.")
        // Sabotage-evidence: change any of the three expected errorKind
        //   values to the wrong one (e.g. assert .permanent for search) →
        //   the corresponding XCTAssertEqual trips, proving these assertions
        //   are actually load-bearing against real source behavior.
    }

    // MARK: - Doc-scan: GenerationComponents.md must not claim the bare recipe works

    /// Detects the trap pattern: an `addToolSources(_:)` generation-tool
    /// recipe with no caveat telling the reader that `quickStart(...)` does
    /// not wire the generation services those tool sources depend on.
    /// Deliberately a coarse, whole-document substring check (mirrors
    /// `AgentsMdAuditTest`'s philosophy: greppy checks survive markdown
    /// reflow; a doc parser would couple the test to layout).
    ///
    /// Returns a non-nil violation message when the doc mentions
    /// `addToolSources` without ALSO carrying a caveat that names
    /// both `quickStart` and an explicit "does not wire" / "no parameter"
    /// style disclaimer.
    static func bareQuickStartRecipeViolation(in body: String) -> String? {
        guard body.contains("addToolSources") else {
            // Nothing to check — the doc doesn't mention the API at all.
            return nil
        }
        // Strip markdown emphasis markers so "does **not** wire" still reads
        // as "does not wire" for the substring check below.
        let stripped = body.replacingOccurrences(of: "**", with: "")
        let mentionsQuickStart = stripped.contains("quickStart")
        let mentionsNoWiring = stripped.contains("does not wire") || stripped.contains("not wired")
            || stripped.contains("no parameter")
        guard mentionsQuickStart, mentionsNoWiring else {
            return "documents addToolSources(_:) with generation tool sources without a caveat stating that ManifoldKit.quickStart(...) does not wire imageGenerationService/videoGenerationService/webSearchRuntime — the recipe reads as if plain quickStart() output works, but the registered sources fail (as a ToolResult errorKind, not a throw) with no build-time or registration-time warning. See #1903 / docs/plans/inert-code-audit-2026-07.md #41."
        }
        return nil
    }

    /// This test's entire purpose is to catch GenerationComponents.md going
    /// stale — a missing Package.swift (repo layout changed) or a missing
    /// doc article (moved/renamed) must fail loudly so the path constants
    /// here get updated, not silently skip and report green.
    private static func locateRepoRoot() throws -> URL {
        let fileURL = URL(fileURLWithPath: #filePath)
        var dir = fileURL.deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        XCTFail("could not locate Package.swift starting from \(fileURL.path) — the repo-root walk (12 levels) failed; if this test file moved, update the walk depth or the path here.")
        throw NSError(
            domain: "GenerationComponentsDocLivenessTest",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Package.swift not found starting from \(fileURL.path)"]
        )
    }

    func test_generationComponentsDoc_doesNotClaimBareQuickStartRecipeWorks() throws {
        let root = try Self.locateRepoRoot()
        let docURL = root.appendingPathComponent(
            "Sources/ManifoldUI/ManifoldUI.docc/Articles/GenerationComponents.md"
        )
        guard let body = try? String(contentsOf: docURL, encoding: .utf8) else {
            XCTFail("GenerationComponents.md not found at \(docURL.path) — if this article moved or was renamed, update the path here rather than letting this liveness check go quiet.")
            return
        }
        if let violation = Self.bareQuickStartRecipeViolation(in: body) {
            XCTFail("GenerationComponents.md \(violation)")
        }
    }

    // MARK: - Sabotage (exercises the shared detection function above)

    /// The old (pre-fix) recipe text — bare `addToolSources` call with the
    /// generation tool sources and no caveat — must be flagged.
    func test_sabotage_bareQuickStartRecipeViolationDetectsPlantedTrap() {
        let trap = """
        When importing `ManifoldKit` (the umbrella module), register the generation tool sources:

        ```swift,no-build
        await kit.bootstrap.addToolSources([
            ImageGenerationToolSource(viewModel: kit.viewModel),
            VideoGenerationToolSource(viewModel: kit.viewModel),
            WebSearchToolSource(viewModel: kit.viewModel)
        ])
        ```
        """
        XCTAssertNotNil(
            Self.bareQuickStartRecipeViolation(in: trap),
            "Detection function must flag addToolSources documented with no quickStart caveat."
        )
    }

    /// The fixed recipe text — carries the caveat — must NOT be flagged.
    func test_sabotage_bareQuickStartRecipeViolationAllowsCaveatedRecipe() {
        let fixed = """
        > Important: `ManifoldKit.quickStart(...)` does **not** wire
        > `imageGenerationService`, `videoGenerationService`, or `webSearchRuntime` —
        > none of its overloads pass those parameters through to
        > `ManifoldBootstrap.build(...)` (tracked in #1903).

        ```swift,no-build
        await bootstrap.addToolSources([
            ImageGenerationToolSource(viewModel: viewModel)
        ])
        ```
        """
        XCTAssertNil(
            Self.bareQuickStartRecipeViolation(in: fixed),
            "Detection function must not flag a recipe that already carries the quickStart caveat."
        )
    }

    /// A document that never mentions the API at all is trivially safe.
    func test_sabotage_bareQuickStartRecipeViolationIgnoresUnrelatedDoc() {
        XCTAssertNil(Self.bareQuickStartRecipeViolation(in: "This document is about something else entirely."))
    }
}
