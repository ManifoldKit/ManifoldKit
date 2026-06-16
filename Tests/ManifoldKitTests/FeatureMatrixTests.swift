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
