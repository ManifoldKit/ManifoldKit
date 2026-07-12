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
    func test_everyMigrationStageIsLightweight() {
        let stages = ManifoldMigrationPlan.stages
        XCTAssertFalse(stages.isEmpty, "Expected ManifoldMigrationPlan to declare at least one stage")

        for stage in stages {
            let description = String(describing: stage)
            XCTAssertTrue(
                description.hasPrefix("lightweight("),
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
}
