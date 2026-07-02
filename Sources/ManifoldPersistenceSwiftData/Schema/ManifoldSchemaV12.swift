import Foundation
import ManifoldRuntime
@preconcurrency import SwiftData

/// ManifoldKit SwiftData schema version 12.
///
/// Adds durable storage for the persona/prompt library (saved, named system
/// prompts): one new `@Model` type mapping ``ManifoldRuntime/PersonaRecord``.
///
/// - ``Persona`` — one row per saved persona, storing `id`, `name`,
///   `systemPrompt`, and `createdAt`.
///
/// The new type is purely additive — no existing column changes, no data
/// motion. Every other model type (ChatSession, ChatMessage, Agent, sampler
/// preset, API endpoint, benchmark cache, RAG document, usage record,
/// conversation run, run step, tool-call conformance) is carried forward
/// from V11 unchanged.
public enum ManifoldSchemaV12: VersionedSchema {
    public static let versionIdentifier = Schema.Version(12, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            // Carried forward verbatim from V11 — V12 does not redefine these.
            ManifoldSchemaV9.ChatMessage.self,
            ManifoldSchemaV9.ChatSession.self,
            ManifoldSchemaV9.Agent.self,
            ManifoldSchemaV4.SamplerPreset.self,
            ManifoldSchemaV4.APIEndpoint.self,
            ManifoldSchemaV4.ModelBenchmarkCache.self,
            ManifoldSchemaV5.RagDocument.self,
            ManifoldSchemaV6.TurnUsageModel.self,
            ManifoldSchemaV10.ConversationRunModel.self,
            ManifoldSchemaV10.RunStepModel.self,
            ManifoldSchemaV11.ToolCallConformanceRecord.self,
            // New in V12.
            Persona.self,
        ]
    }

    // MARK: - Persona (V12 — new model)

    /// SwiftData row backing a saved persona (named, reusable system prompt).
    @Model
    public final class Persona {
        public var id: UUID
        public var name: String
        public var systemPrompt: String
        public var createdAt: Date

        public init(
            id: UUID = UUID(),
            name: String,
            systemPrompt: String,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.name = name
            self.systemPrompt = systemPrompt
            self.createdAt = createdAt
        }
    }
}
