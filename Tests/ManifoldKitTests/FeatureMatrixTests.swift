// FeatureMatrixTests.swift
//
// Audits FeatureMatrix.traits against the trait list in Package.swift.
// The whole point of this file: when someone adds a trait to Package.swift
// they get a CI failure here that says "update Sources/ManifoldKit/FeatureMatrix.swift".
//
// Uses #filePath + text regex on Package.swift rather than SwiftPM's manifest
// API — loading the manifest from a test target is overkill for "give me the
// list of trait names declared in the package".

import XCTest
@testable import ManifoldKit

final class FeatureMatrixTests: XCTestCase {

    // Traits that intentionally don't unlock a runtime capability (harness or
    // build-time levers). Listed here so the "non-empty unlocks" assertion
    // doesn't have to lie about them.
    private let pendingMapping: Set<String> = [
        // WWDC 2026 pre-emptive stubs, resolved against the macOS 27 beta SDK
        // (#1577, see docs/wwdc-2026-trait-stubs.md): SystemAIProviderExtension
        // has no SDK symbol (the real seam is FoundationModels.LanguageModelExecutor,
        // a deferred either/or); CoreAI is a confirmed dead end (.aimodel runtime,
        // no LM protocol). Both keep unlocks: [] and so must stay in this set —
        // removing either fails the "non-empty unlocks" assertion below.
        "SystemAIProviderExtension",
        "CoreAI",
    ]

    func testEveryMatrixTraitExistsInPackageManifest() throws {
        let manifestTraits = try parsePackageManifestTraits()
        let matrixNames = Set(FeatureMatrix.traits.map(\.name))
        let missingFromManifest = matrixNames.subtracting(manifestTraits)
        XCTAssertTrue(
            missingFromManifest.isEmpty,
            "FeatureMatrix lists trait(s) that aren't declared in Package.swift: \(missingFromManifest.sorted()). Remove them from FeatureMatrix.swift or add them to the package manifest."
        )
    }

    func testEveryPackageManifestTraitHasMatrixEntry() throws {
        let manifestTraits = try parsePackageManifestTraits()
        let matrixNames = Set(FeatureMatrix.traits.map(\.name))
        let missingFromMatrix = manifestTraits.subtracting(matrixNames)
        XCTAssertTrue(
            missingFromMatrix.isEmpty,
            "Package.swift declares trait(s) not in FeatureMatrix.swift: \(missingFromMatrix.sorted()). Add them to FeatureMatrix.traits with the capabilities they unlock (or unlocks: [] plus an entry in pendingMapping if it's a harness/build lever)."
        )
    }

    func testEveryTraitHasNonEmptyUnlocksUnlessPending() {
        for trait in FeatureMatrix.traits {
            if pendingMapping.contains(trait.name) { continue }
            XCTAssertFalse(
                trait.unlocks.isEmpty,
                "Trait `\(trait.name)` has no capabilities listed. Either map it to one or more ManifoldCapability cases, or add it to FeatureMatrixTests.pendingMapping with a comment explaining why."
            )
        }
    }

    func testTraitNamesAreUnique() {
        let names = FeatureMatrix.traits.map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "Duplicate trait name in FeatureMatrix.traits")
    }

    func testCapabilitiesLookupRoundTrip() {
        // For every trait, every capability it unlocks should list it back.
        for trait in FeatureMatrix.traits {
            for capability in trait.unlocks {
                let traitsForCap = FeatureMatrix.traits(unlocking: capability)
                XCTAssertTrue(
                    traitsForCap.contains(where: { $0.name == trait.name }),
                    "traits(unlocking: .\(capability.rawValue)) missing `\(trait.name)`"
                )
            }
        }
    }

    func testCapabilitiesForUnknownTraitReturnsEmpty() {
        XCTAssertEqual(FeatureMatrix.capabilities(for: "DefinitelyNotATrait"), [])
    }

    func testMarkdownContainsEveryTrait() {
        let markdown = FeatureMatrix.markdown()
        for trait in FeatureMatrix.traits {
            XCTAssertTrue(
                markdown.contains("`\(trait.name)`"),
                "markdown() output missing trait `\(trait.name)`"
            )
        }
    }

    /// Freshness guard for the checked-in generated doc (finding #42,
    /// inert-code audit 2026-07-03). `docs/FeatureMatrix.md` claims to be
    /// generated from this file by `scripts/render-feature-matrix.sh`, but
    /// nothing previously verified that claim — the doc silently drifted
    /// from `FeatureMatrix.swift`'s live descriptions after a post-WWDC-beta
    /// rewrite. This test fails CI whenever the checked-in file and
    /// `FeatureMatrix.markdown()` diverge, so drift is caught the same PR it
    /// lands in rather than discovered later by audit.
    ///
    /// Compares `FeatureMatrix.markdown()`'s output against the on-disk file
    /// rather than shelling out to `render-feature-matrix.sh` — the script
    /// re-derives the same trait table via a source-level regex specifically
    /// so it doesn't need to link the whole `ManifoldKit` module graph, but
    /// this test already has `@testable import ManifoldKit`, so calling the
    /// canonical Swift implementation directly is both simpler and a more
    /// faithful "did the doc drift from the code" check.
    func testFeatureMatrixDocMatchesGeneratedMarkdown() throws {
        let docURL = try locateFeatureMatrixDoc()
        let onDisk = try String(contentsOf: docURL, encoding: .utf8)
        let generated = FeatureMatrix.markdown()
        XCTAssertEqual(
            onDisk,
            generated,
            "docs/FeatureMatrix.md is stale — re-run scripts/render-feature-matrix.sh and commit the result."
        )
    }

    /// Walk up from this test file to the repo root, then down to
    /// `docs/FeatureMatrix.md`. Mirrors `locatePackageManifest()`'s walk-up
    /// strategy so both helpers tolerate the test bundle's working directory
    /// varying between `swift test` and Xcode.
    private func locateFeatureMatrixDoc() throws -> URL {
        let fileURL = URL(fileURLWithPath: #filePath)
        var dir = fileURL.deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("docs/FeatureMatrix.md")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw NSError(
            domain: "FeatureMatrixTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "could not locate docs/FeatureMatrix.md starting from \(fileURL.path)"]
        )
    }

    // MARK: - Manifest parser

    /// Returns the set of trait names declared in Package.swift's `traits:` block.
    /// Skips the `.default(enabledTraits: ...)` entry — those are references,
    /// not declarations.
    private func parsePackageManifestTraits() throws -> Set<String> {
        let manifestURL = try locatePackageManifest()
        let source = try String(contentsOf: manifestURL, encoding: .utf8)

        // Match `.trait(name: "X"` — the canonical declaration form.
        let pattern = #"\.trait\s*\(\s*name:\s*"([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        var names: Set<String> = []
        regex.enumerateMatches(in: source, options: [], range: range) { match, _, _ in
            guard let m = match,
                  let nameRange = Range(m.range(at: 1), in: source) else { return }
            names.insert(String(source[nameRange]))
        }
        XCTAssertFalse(names.isEmpty, "parsed zero traits from Package.swift — manifest format changed?")
        return names
    }

    /// Walk up from this test file until we find Package.swift. Stops at the
    /// repo root or at filesystem root (whichever comes first).
    private func locatePackageManifest() throws -> URL {
        let fileURL = URL(fileURLWithPath: #filePath)
        var dir = fileURL.deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw NSError(
            domain: "FeatureMatrixTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "could not locate Package.swift starting from \(fileURL.path)"]
        )
    }
}
