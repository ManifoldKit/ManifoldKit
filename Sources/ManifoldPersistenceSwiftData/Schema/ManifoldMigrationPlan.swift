import SwiftData

public enum ManifoldMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [
            ManifoldSchemaV3.self,
            ManifoldSchemaV4.self,
            ManifoldSchemaV5.self,
            ManifoldSchemaV6.self,
        ]
    }

    public static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: ManifoldSchemaV3.self, toVersion: ManifoldSchemaV4.self),
            .lightweight(fromVersion: ManifoldSchemaV4.self, toVersion: ManifoldSchemaV5.self),
            // V6 adds TurnUsageRecordModel — purely additive, no existing column changes.
            .lightweight(fromVersion: ManifoldSchemaV5.self, toVersion: ManifoldSchemaV6.self),
        ]
    }
}
