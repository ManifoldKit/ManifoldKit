// GenerationComponentsDocLivenessTest.swift
//
// Tripwire for the "quickStart() + addGenerationToolSources(viewModel:) is a
// silent no-op" trap (audit item #41 in docs/plans/inert-code-audit-2026-07.md,
// tracked under #2128 / #1903).
//
// `ManifoldKit.quickStart(...)` never passes `imageGenerationService` /
// `videoGenerationService` / `webSearchRuntime` through to
// `ManifoldBootstrap.build(...)`, so a bootstrap built via quickStart always
// has all three nil. `ManifoldBootstrap.addGenerationToolSources(viewModel:)`
// only registers a tool source when its corresponding service is non-nil, so
// calling it against a quickStart bootstrap registers zero sources. Two
// things must stay true together:
//
//   1. That behavior is real (verified against source, not assumed).
//   2. GenerationComponents.md's "Registering tool sources" recipe does not
//      claim the bare `quickStart()` + `addGenerationToolSources` combination
//      works — it must carry the caveat.
//
// If a future edit "simplifies" the doc back to the bare recipe without the
// caveat, this test must fail.

import XCTest
import SwiftData
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldKit

@MainActor
final class GenerationComponentsDocLivenessTest: XCTestCase {

    // MARK: - Behavior: quickStart wires none of the three generation surfaces

    /// A bootstrap built the way `quickStart()` builds one — no
    /// `imageGenerationService` / `videoGenerationService` / `webSearchRuntime`
    /// passed to `ManifoldBootstrap.build(...)` — must have all three nil.
    /// `addGenerationToolSources(viewModel:)`'s mapping is exactly
    /// `service != nil ? append : skip` for each of the three, so this proves
    /// the call registers zero tool sources without requiring a new
    /// tool-source-count accessor on `ConversationRuntime` (out of scope here
    /// per the "no new public API" guard).
    func test_plainQuickStartBootstrap_hasNoGenerationSurfacesWired() async throws {
        let result = try await ManifoldKit._quickStart(
            configuration: .default,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        XCTAssertNil(result.bootstrap.imageGenerationService,
            "quickStart() must not wire imageGenerationService (see #1903) — if this now passes, addGenerationToolSources is live for image gen and GenerationComponents.md's caveat needs updating.")
        XCTAssertNil(result.bootstrap.videoGenerationService,
            "quickStart() must not wire videoGenerationService (see #1903) — if this now passes, addGenerationToolSources is live for video gen and GenerationComponents.md's caveat needs updating.")
        XCTAssertNil(result.bootstrap.webSearchRuntime,
            "quickStart() must not wire webSearchRuntime (see #1903) — if this now passes, addGenerationToolSources is live for web search and GenerationComponents.md's caveat needs updating.")

        // Exercise the real call path — must not crash, and (per the source
        // above) resolves to the empty-sources branch that now logs a
        // warning instead of returning silently.
        await result.bootstrap.addGenerationToolSources(viewModel: result.viewModel)
    }

    // MARK: - Doc-scan: GenerationComponents.md must not claim the bare recipe works

    /// Detects the trap pattern: an `addGenerationToolSources` recipe with no
    /// caveat telling the reader that `quickStart(...)` does not wire the
    /// generation services the call depends on. Deliberately a coarse,
    /// whole-document substring check (mirrors `AgentsMdAuditTest`'s
    /// philosophy: greppy checks survive markdown reflow; a doc parser would
    /// couple the test to layout).
    ///
    /// Returns a non-nil violation message when the doc mentions
    /// `addGenerationToolSources` without ALSO carrying a caveat that names
    /// both `quickStart` and an explicit "does not wire" / "no parameter"
    /// style disclaimer.
    static func bareQuickStartRecipeViolation(in body: String) -> String? {
        guard body.contains("addGenerationToolSources") else {
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
            return "documents addGenerationToolSources(viewModel:) without a caveat stating that ManifoldKit.quickStart(...) does not wire imageGenerationService/videoGenerationService/webSearchRuntime — the recipe reads as if plain quickStart() output works, but it silently (now: loudly) registers zero tool sources. See #1903 / docs/plans/inert-code-audit-2026-07.md #41."
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

    /// The old (pre-fix) recipe text — bare `addGenerationToolSources` call
    /// with no caveat — must be flagged.
    func test_sabotage_bareQuickStartRecipeViolationDetectsPlantedTrap() {
        let trap = """
        When importing `ManifoldKit` (the umbrella module), use the one-liner convenience:

        ```swift,no-build
        // One call registers whichever generation services are wired in the bootstrap.
        // Sources for nil services are silently skipped.
        await kit.bootstrap.addGenerationToolSources(viewModel: kit.viewModel)
        ```
        """
        XCTAssertNotNil(
            Self.bareQuickStartRecipeViolation(in: trap),
            "Detection function must flag addGenerationToolSources documented with no quickStart caveat."
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
        await bootstrap.addGenerationToolSources(viewModel: viewModel)
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
