import Foundation
import XCTest

/// Guards the tier-4 human cold-start cache against stale build-output reuse.
///
/// A pull-request run can restore caches from its own ref and from `main`, but
/// cannot see matching caches stored by other PRs. Before #2423, the broad
/// prefix fallback therefore selected a weeks-old `main` build path whenever
/// an exact key had only been written by another PR. That made the README
/// consumer's diagnostics non-reproducible from the checked-out source.
///
/// The workflow must consequently use an exact key only and include a UTC-day
/// generation, which bounds a hit to less than 24 hours. A miss is valid and
/// explicitly logged. An exact hit must log the current key plus the cache's
/// ID, creation time, and ref, and it must fail rather than guess when Actions
/// metadata cannot unambiguously identify an eligible cache.
final class ColdStartHumanCacheAuditTest: XCTestCase {

    func test_coldStartHumanCacheIsExactOnlyAndProvenanced() throws {
        let workflow = try Self.workflowContents()
        let violations = Self.cachePolicyViolations(workflow: workflow)

        XCTAssertTrue(
            violations.isEmpty,
            """
            cold-start-human's build cache can no longer prove it restored current
            output. A cache miss is intentional; do not add a broad restore prefix.

            Violations:
            \(violations.map { "  - \($0)" }.joined(separator: "\n"))
            """
        )
    }

    // MARK: - Sabotage

    /// Exercises the production predicate against the regressions that would
    /// otherwise make a green run indistinguishable from stale output: a broad
    /// fallback, an unbounded exact key, widened provenance lookup, and a hit
    /// without provenance evidence.
    func test_sabotage_cachePolicyFlagsBroadRestoreMissingFreshnessAndMissingProvenance() throws {
        let workflow = try Self.workflowContents()

        let withBroadRestore = workflow.replacingOccurrences(
            of: "          key: ${{ env.COLD_START_HUMAN_CACHE_KEY }}",
            with: """
            key: ${{ env.COLD_START_HUMAN_CACHE_KEY }}
            restore-keys: |
              macOS-arm64-xcode-26.3-cs-human-
            """
        )
        let restoreViolations = Self.cachePolicyViolations(workflow: withBroadRestore)
        XCTAssertTrue(
            restoreViolations.contains { $0.contains("restore-keys") },
            "A broad cache fallback must be rejected; got \(restoreViolations)"
        )

        let withoutFreshness = workflow.replacingOccurrences(
            of: "-d${{ steps.cold-start-cache-generation.outputs.value }}",
            with: ""
        )
        let freshnessViolations = Self.cachePolicyViolations(workflow: withoutFreshness)
        XCTAssertTrue(
            freshnessViolations.contains { $0.contains("UTC-day") },
            "An exact key without its UTC-day freshness generation must be rejected; got \(freshnessViolations)"
        )

        let widenedFallback = workflow.replacingOccurrences(
            of: "if [[ \"${cache_count}\" == \"0\" ]]; then",
            with: "if [[ \"${cache_count}\" -ge \"0\" ]]; then"
        )
        let fallbackViolations = Self.cachePolicyViolations(workflow: widenedFallback)
        XCTAssertTrue(
            fallbackViolations.contains { $0.contains("only after the current-ref lookup returns zero") },
            "The default-branch fallback must be rejected unless the current ref has no cache; got \(fallbackViolations)"
        )

        let withoutCurrentRef = workflow.replacingOccurrences(
            of: "          cache_ref=\"${GITHUB_REF}\"\n",
            with: ""
        )
        let currentRefViolations = Self.cachePolicyViolations(workflow: withoutCurrentRef)
        XCTAssertTrue(
            currentRefViolations.contains { $0.contains("current PR ref") },
            "The current PR ref must be queried before considering main; got \(currentRefViolations)"
        )

        let withoutCacheKeyExtraction = workflow.replacingOccurrences(
            of: "          restored_cache_key=\"$(printf '%s' \"${cache_metadata}\" | jq -er '.actions_caches[0].key')\"\n",
            with: ""
        )
        let keyExtractionViolations = Self.cachePolicyViolations(workflow: withoutCacheKeyExtraction)
        XCTAssertTrue(
            keyExtractionViolations.contains { $0.contains("cache_key extraction") },
            "A provenance record must extract the restored cache key; got \(keyExtractionViolations)"
        )

        let withoutCacheKeyEquality = workflow.replacingOccurrences(
            of: "          if [[ \"${restored_cache_key}\" != \"${CACHE_KEY}\" ]]; then\n",
            with: ""
        )
        let keyEqualityViolations = Self.cachePolicyViolations(workflow: withoutCacheKeyEquality)
        XCTAssertTrue(
            keyEqualityViolations.contains { $0.contains("equality guard") },
            "A provenance record must fail closed when the restored key differs; got \(keyEqualityViolations)"
        )

        let equalityGuardWithoutExit = workflow.replacingOccurrences(
            of: "            exit 1\n          fi\n\n          echo \"cold-start cache provenance: id=${cache_id} key=${restored_cache_key} createdAt=${cache_created_at} ref=${cache_ref}\"",
            with: "          fi\n\n          echo \"cold-start cache provenance: id=${cache_id} key=${restored_cache_key} createdAt=${cache_created_at} ref=${cache_ref}\""
        )
        let guardExitViolations = Self.cachePolicyViolations(workflow: equalityGuardWithoutExit)
        XCTAssertTrue(
            guardExitViolations.contains { $0.contains("equality guard") },
            "A cache-key mismatch guard without a failing exit must be rejected; got \(guardExitViolations)"
        )

        let withoutProvenance = workflow.replacingOccurrences(
            of: "          cache_created_at=\"$(printf '%s' \"${cache_metadata}\" | jq -er '.actions_caches[0].created_at')\"\n",
            with: ""
        )
        let provenanceViolations = Self.cachePolicyViolations(workflow: withoutProvenance)
        XCTAssertTrue(
            provenanceViolations.contains { $0.contains("cache_created_at") },
            "An exact hit without createdAt evidence must be rejected; got \(provenanceViolations)"
        )
    }

    // MARK: - Detection

    /// Pure predicate over workflow text so the sabotage test covers the same
    /// checks that guard the shipped YAML rather than a replica.
    static func cachePolicyViolations(workflow: String) -> [String] {
        var violations: [String] = []
        let cacheStep = step(named: "Cache cold-start consumer build path", in: workflow)
        let provenanceStep = step(named: "Report cold-start cache provenance", in: workflow)
        let generationStep = step(named: "Calculate cold-start cache generation", in: workflow)

        if !workflow.contains("actions: read") {
            violations.append("The workflow must grant actions: read so exact cache-hit provenance can be verified.")
        }
        if generationStep.isEmpty ||
            !generationStep.contains("id: cold-start-cache-generation") ||
            !generationStep.contains("date -u +%Y-%m-%d") ||
            !generationStep.contains("${GITHUB_OUTPUT}") {
            violations.append("The workflow must calculate and export a UTC-day freshness generation before cache restore.")
        }
        if cacheStep.isEmpty {
            violations.append("The cold-start consumer cache step is missing.")
        } else {
            let cacheKeyExpression = "${{ runner.os }}-${{ runner.arch }}-xcode-26.3-cs-human-v3-d${{ steps.cold-start-cache-generation.outputs.value }}-${{ hashFiles('Package.resolved', 'scripts/cold-start-human.sh') }}"
            if !cacheStep.contains("COLD_START_HUMAN_CACHE_KEY: \(cacheKeyExpression)") {
                violations.append("The cache step must declare the current key with a UTC-day freshness generation and the dependency/script hash.")
            }
            if !cacheStep.contains("id: cold-start-human-cache") {
                violations.append("The cache step needs a stable id so the provenance step can read cache-hit.")
            }
            if !cacheStep.contains("key: ${{ env.COLD_START_HUMAN_CACHE_KEY }}") {
                violations.append("The cache step must restore only the declared current cache key.")
            }
            if cacheStep.contains("restore-keys:") {
                violations.append("The cache step must not define restore-keys; a broad fallback admits stale main-scoped output.")
            }
        }
        if provenanceStep.isEmpty {
            violations.append("The workflow must report cold-start cache provenance before compiling the README consumer.")
        } else {
            let requiredFragments = [
                "CACHE_HIT: ${{ steps.cold-start-human-cache.outputs.cache-hit }}",
                "CACHE_KEY: ${{ runner.os }}-${{ runner.arch }}-xcode-26.3-cs-human-v3-d${{ steps.cold-start-cache-generation.outputs.value }}-${{ hashFiles('Package.resolved', 'scripts/cold-start-human.sh') }}",
                "cold-start cache key: ${CACHE_KEY}",
                "Intentional clean miss",
                "exact-key-only restore policy",
                "curl --fail",
                "/actions/caches",
                "cache_created_at=",
                "created_at",
                "createdAt=${cache_created_at}",
                "ref=${cache_ref}",
                "${cache_count}\" != \"1\"",
            ]
            for fragment in requiredFragments where !provenanceStep.contains(fragment) {
                violations.append("The provenance step is missing required evidence: `\(fragment)`.")
            }

            let currentRefSelection = "cache_ref=\"${GITHUB_REF}\""
            let currentRefLookup = "cache_metadata=\"$(fetch_cache_metadata \"${cache_ref}\")\""
            let currentRefCount = "cache_count=\"$(printf '%s' \"${cache_metadata}\" | jq -er '.total_count')\""
            let zeroCountFallback = "if [[ \"${cache_count}\" == \"0\" ]]; then"
            let defaultBranchFallback = "cache_ref=\"refs/heads/${DEFAULT_BRANCH}\""
            let currentRefIndex = provenanceStep.range(of: currentRefSelection)?.lowerBound
            let currentRefLookupIndex = provenanceStep.range(of: currentRefLookup)?.lowerBound
            let currentRefCountIndex = provenanceStep.range(of: currentRefCount)?.lowerBound
            let zeroCountIndex = provenanceStep.range(of: zeroCountFallback)?.lowerBound
            let defaultBranchIndex = provenanceStep.range(of: defaultBranchFallback)?.lowerBound
            let firstCacheRefAssignment = provenanceStep.range(of: "cache_ref=")?.lowerBound
            if currentRefIndex == nil || currentRefIndex != firstCacheRefAssignment {
                violations.append("The provenance lookup must start with the current PR ref (GITHUB_REF).")
            }
            if let currentRefIndex, let currentRefLookupIndex, let currentRefCountIndex,
               let zeroCountIndex, let defaultBranchIndex {
                if currentRefIndex > currentRefLookupIndex ||
                    currentRefLookupIndex > currentRefCountIndex ||
                    currentRefCountIndex > zeroCountIndex ||
                    zeroCountIndex > defaultBranchIndex {
                    violations.append("The default-branch fallback may run only after the current-ref lookup returns zero cache records.")
                }
            } else {
                violations.append("The default-branch fallback may run only after the current-ref lookup returns zero cache records.")
            }

            let cacheKeyExtraction = "restored_cache_key=\"$(printf '%s' \"${cache_metadata}\" | jq -er '.actions_caches[0].key')\""
            if !provenanceStep.contains(cacheKeyExtraction) {
                violations.append("The provenance step is missing cache_key extraction from Actions metadata.")
            }
            let cacheKeyEqualityGuard = "if [[ \"${restored_cache_key}\" != \"${CACHE_KEY}\" ]]; then"
            let cacheKeyGuardBody = provenanceStep.range(of: cacheKeyEqualityGuard).flatMap { guardStart in
                let suffix = provenanceStep[guardStart.upperBound...]
                return suffix.range(of: "\n          fi").map { guardEnd in
                    String(provenanceStep[guardStart.lowerBound..<guardEnd.lowerBound])
                }
            }
            if !provenanceStep.contains(cacheKeyEqualityGuard) ||
                cacheKeyGuardBody?.contains("Cache metadata key ${restored_cache_key} does not match current key ${CACHE_KEY}") != true ||
                cacheKeyGuardBody?.contains("exit 1") != true {
                violations.append("The provenance step needs a fail-closed cache-key equality guard.")
            }
        }

        return violations
    }

    private static func step(named name: String, in workflow: String) -> String {
        let marker = "      - name: \(name)"
        guard let start = workflow.range(of: marker)?.lowerBound else { return "" }
        let suffix = String(workflow[start...])
        guard let next = suffix.dropFirst(marker.count).range(of: "\n      - name: ")?.lowerBound else {
            return suffix
        }
        return String(suffix[..<next])
    }

    private static func workflowContents(filePath: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while directory.path != "/" {
            let workflow = directory.appendingPathComponent(".github/workflows/cold-start-human.yml")
            if FileManager.default.fileExists(atPath: workflow.path) {
                return try String(contentsOf: workflow, encoding: .utf8)
            }
            directory.deleteLastPathComponent()
        }
        throw NSError(
            domain: "ColdStartHumanCacheAuditTest",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate .github/workflows/cold-start-human.yml from #filePath."]
        )
    }
}
