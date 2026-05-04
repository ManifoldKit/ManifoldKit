import SwiftData

public enum BaseChatMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [
            BaseChatSchemaV3.self,
            BaseChatSchemaV4.self,
        ]
    }

    public static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: BaseChatSchemaV3.self, toVersion: BaseChatSchemaV4.self),
        ]
    }
}
