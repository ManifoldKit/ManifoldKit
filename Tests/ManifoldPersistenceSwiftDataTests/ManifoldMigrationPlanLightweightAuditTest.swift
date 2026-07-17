import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData

/// Tripwire for docs/RELEASE-1.0.md Policy 3 (SwiftData schema stability):
/// every stage in `ManifoldMigrationPlan.stages` must be `.lightweight`
/// within a major version. A destructive migration is a major-version
/// event, never a silent addition — this test forces that decision into
/// the open instead of letting it slip in unnoticed.
///
/// `MigrationStage` has no public case-introspection API, so this compares
/// against `String(describing:)` of the stage. `.lightweight(fromVersion:toVersion:)`
/// stringifies as `"lightweight(...)"`; `.custom(fromVersion:toVersion:willMigrate:didMigrate:)`
/// stringifies as `"custom(...)"`. That's coarse but sufficient: the only
/// two `MigrationStage` cases SwiftData ships are `.lightweight` and
/// `.custom`, so failing to match the `lightweight` prefix means the stage
/// is a `.custom` (destructive-migration-capable) stage.
final class ManifoldMigrationPlanLightweightAuditTest: XCTestCase {
    /// The audit's real detection predicate. Extracted so a sabotage test can
    /// call the exact same logic the audit uses, rather than a hand-copied
    /// replica (docs/QA-PRACTICES.md — replicas are the reason the old
    /// nightly sabotage suite was retired). Operates on `String(describing:)`
    /// of a `MigrationStage` rather than the stage itself, matching the
    /// audit's own approach: `MigrationStage` has no public case-introspection
    /// API, so a synthetic description string is the only way to exercise
    /// this function without constructing two real `VersionedSchema` types
    /// (not worth it for a coarse prefix check).
    private func isLightweight(stageDescription: String) -> Bool {
        stageDescription.hasPrefix("lightweight(")
    }

    func test_everyMigrationStageIsLightweight() {
        let stages = ManifoldMigrationPlan.stages
        XCTAssertFalse(stages.isEmpty, "Expected ManifoldMigrationPlan to declare at least one stage")

        for stage in stages {
            let description = String(describing: stage)
            XCTAssertTrue(
                isLightweight(stageDescription: description),
                """
                ManifoldMigrationPlan stage \(description) is not `.lightweight`.
                Policy 3 (docs/RELEASE-1.0.md) requires every stage to migrate \
                existing stores without data loss within a major version. A \
                `.custom` (destructive) stage is only allowed at a major-version \
                boundary with a documented export path — see docs/RELEASE-1.0.md.
                """
            )
        }
    }

    /// Feeds `isLightweight(stageDescription:)` — the audit's real detection
    /// function, not a copy — a synthetic `.custom(...)` description and
    /// confirms it is flagged (not lightweight). Also checks the inverse
    /// with a synthetic `.lightweight(...)` description, so this can't pass
    /// by the predicate trivially returning `false` for everything.
    func test_sabotage_customStageIsFlaggedAsNotLightweight() {
        let customDescription = "custom(fromVersion: SchemaV1, toVersion: SchemaV2, willMigrate: nil, didMigrate: nil)"
        XCTAssertFalse(
            isLightweight(stageDescription: customDescription),
            "A .custom stage description must NOT be classified as lightweight — the audit should have caught this."
        )

        let lightweightDescription = "lightweight(fromVersion: SchemaV1, toVersion: SchemaV2)"
        XCTAssertTrue(
            isLightweight(stageDescription: lightweightDescription),
            "A .lightweight stage description must be classified as lightweight."
        )
    }
}
