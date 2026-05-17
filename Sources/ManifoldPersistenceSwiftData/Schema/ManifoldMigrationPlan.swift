import SwiftData

public enum ManifoldMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [
            ManifoldSchemaV3.self,
            ManifoldSchemaV4.self,
            ManifoldSchemaV5.self,
            ManifoldSchemaV6.self,
            ManifoldSchemaV7.self,
            ManifoldSchemaV8.self,
        ]
    }

    public static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: ManifoldSchemaV3.self, toVersion: ManifoldSchemaV4.self),
            .lightweight(fromVersion: ManifoldSchemaV4.self, toVersion: ManifoldSchemaV5.self),
            // V6 adds TurnUsageRecordModel — purely additive, no existing column changes.
            .lightweight(fromVersion: ManifoldSchemaV5.self, toVersion: ManifoldSchemaV6.self),
            // V7 adds kindRaw (default "chat") and citationsJSON (default nil) to ChatMessage.
            .lightweight(fromVersion: ManifoldSchemaV6.self, toVersion: ManifoldSchemaV7.self),
            // V8 adds isPinned (default false) and pinnedAt (default nil) to ChatSession.
            .lightweight(fromVersion: ManifoldSchemaV7.self, toVersion: ManifoldSchemaV8.self),
        ]
    }
}
