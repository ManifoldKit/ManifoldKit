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
            ManifoldSchemaV9.self,
            ManifoldSchemaV10.self,
            ManifoldSchemaV11.self,
            ManifoldSchemaV12.self,
            ManifoldSchemaV13.self,
        ]
    }

    public static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: ManifoldSchemaV3.self, toVersion: ManifoldSchemaV4.self),
            .lightweight(fromVersion: ManifoldSchemaV4.self, toVersion: ManifoldSchemaV5.self),
            // V6 adds TurnUsageModel — purely additive, no existing column changes.
            .lightweight(fromVersion: ManifoldSchemaV5.self, toVersion: ManifoldSchemaV6.self),
            // V7 adds kindRaw (default "chat") and citationsJSON (default nil) to ChatMessage.
            .lightweight(fromVersion: ManifoldSchemaV6.self, toVersion: ManifoldSchemaV7.self),
            // V8 adds isPinned (default false) and pinnedAt (default nil) to ChatSession.
            .lightweight(fromVersion: ManifoldSchemaV7.self, toVersion: ManifoldSchemaV8.self),
            // V9 adds activeAgentID, activeSkillName, agents (cascade) to ChatSession,
            // agentID to ChatMessage, and a new Agent @Model. All new fields default
            // to nil/empty so no data motion is required.
            .lightweight(fromVersion: ManifoldSchemaV8.self, toVersion: ManifoldSchemaV9.self),
            // V10 adds ConversationRunModel + RunStepModel for resumable runs
            // (P3b #1784). Two new @Model types, purely additive — no existing
            // column changes, no data motion.
            .lightweight(fromVersion: ManifoldSchemaV9.self, toVersion: ManifoldSchemaV10.self),
            // V11 adds ToolCallConformanceRecord for durable tool-call conformance
            // verdicts (follow-up to #2030). One new @Model type, purely additive
            // — no existing column changes, no data motion.
            .lightweight(fromVersion: ManifoldSchemaV10.self, toVersion: ManifoldSchemaV11.self),
            // V12 adds Persona for the persona/prompt library (saved, named
            // system prompts). One new @Model type, purely additive — no
            // existing column changes, no data motion.
            .lightweight(fromVersion: ManifoldSchemaV11.self, toVersion: ManifoldSchemaV12.self),
            // V13 adds branchOriginSessionID and branchOriginTitleSnapshot to
            // ChatSession (#2307 branch-origin chip). Both new fields default
            // to nil, no existing column changes, no data motion.
            .lightweight(fromVersion: ManifoldSchemaV12.self, toVersion: ManifoldSchemaV13.self),
        ]
    }
}
