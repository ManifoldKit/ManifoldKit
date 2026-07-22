import Foundation
import ManifoldRuntime
@preconcurrency import SwiftData

/// ManifoldKit SwiftData schema version 11.
///
/// Adds durable storage for tool-call conformance verdicts
/// (follow-up to #2030): one new `@Model` type mapping the
/// ``ManifoldRuntime/ToolCallConformance`` value type keyed by
/// ``ManifoldRuntime/ToolCallConformanceKey`` (`model × quant × backend`).
///
/// - ``ToolCallConformanceRecord`` — one row per `(model, quant, backend)`
///   cell; stores enums as their raw strings and optional metric doubles
///   directly as nullable columns.
///
/// The new type is purely additive — no existing column changes, no data
/// motion. Every other model type (ChatSession, ChatMessage, Agent, sampler
/// preset, API endpoint, benchmark cache, RAG document, usage record,
/// conversation run, run step) is carried forward from V10 unchanged.
public enum ManifoldSchemaV11: VersionedSchema {
    public static let versionIdentifier = Schema.Version(11, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            // Carried forward verbatim from V10 — V11 does not redefine these.
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
            // New in V11.
            ToolCallConformanceRecord.self,
        ]
    }

    // MARK: - ToolCallConformanceRecord (V11 — new model)

    /// SwiftData row backing a ``ToolCallConformance`` verdict for one
    /// `(model × quant × backend)` cell.
    ///
    /// The ``ToolCallConformanceKey`` coordinates are stored as three flat
    /// columns (`modelName`, `quant`, `backend`) — `quant` is nullable,
    /// matching the value type's optional. Enum fields (`capabilityRaw`,
    /// `sourceRaw`) are stored as their ``String`` raw values so the schema
    /// is stable across case-reordering. Metric doubles are nullable columns
    /// that decode to `nil` when absent, matching the value type.
    ///
    /// The composite uniqueness constraint `(modelName, quant, backend)` was
    /// enforced in application code (delete-then-insert), not by a SwiftData
    /// `@Attribute(.unique)` triple — SwiftData V1 does not support
    /// multi-column unique constraints.
    ///
    /// > Note: The `ToolCallConformanceCache` port and its
    /// > `SwiftDataToolCallConformanceCache` adapter (the reader/writer of these
    /// > rows) were removed 2026-07-22 (issue #2128 inert-surface sweep) — the
    /// > path was never wired to a reader and had zero external adopters. This
    /// > `@Model` and its V11 schema are **deliberately retained**: dropping a
    /// > persisted model requires a new schema version + lightweight migration,
    /// > a cost not worth paying for dead storage. Delete this type (and fold
    /// > its removal into a migration) at the next schema revision. The
    /// > value-type conversion helpers below still compile against the retained
    /// > ``ManifoldRuntime/ToolCallConformance`` vocabulary.
    @Model
    public final class ToolCallConformanceRecord {

        // MARK: Key columns

        /// ``ToolCallConformanceKey/model`` — the model identity
        /// (e.g. `"Qwen2.5-7B-Instruct"`).
        public var modelName: String

        /// ``ToolCallConformanceKey/quant`` — the quantization label, or `nil`
        /// when the artifact carries no meaningful quant.
        public var quant: String?

        /// ``ToolCallConformanceKey/backend`` — the backend family that
        /// rendered and parsed the calls (e.g. `"llama"`, `"ollama"`).
        public var backend: String

        // MARK: Verdict columns

        /// ``ToolCallCapability/rawValue`` for the stored verdict.
        public var capabilityRaw: String

        /// ``ToolCallConformanceSource/rawValue`` for the verdict source.
        public var sourceRaw: String

        /// Raw dialect family name observed during the soak, if any.
        public var observedDialect: String?

        // MARK: Metric columns (nullable — absent for static verdicts)

        public var precision: Double?
        public var recall: Double?
        public var f1: Double?

        /// When the measurement was taken, for provenance. Not used for expiry.
        public var measuredAt: Date?

        /// How many scenarios/samples backed the measurement. `0` for purely
        /// static (template/render) verdicts.
        public var sampleCount: Int

        // MARK: - Init

        public init(key: ToolCallConformanceKey, conformance: ToolCallConformance) {
            self.modelName = key.model
            self.quant = key.quant
            self.backend = key.backend
            self.capabilityRaw = conformance.capability.rawValue
            self.sourceRaw = conformance.source.rawValue
            self.observedDialect = conformance.observedDialect
            self.precision = conformance.precision
            self.recall = conformance.recall
            self.f1 = conformance.f1
            self.measuredAt = conformance.measuredAt
            self.sampleCount = conformance.sampleCount
        }

        // MARK: - Conversion helpers

        /// Reconstitutes the ``ToolCallConformanceKey`` from this row.
        public func toKey() -> ToolCallConformanceKey {
            ToolCallConformanceKey(model: modelName, quant: quant, backend: backend)
        }

        /// Reconstitutes a ``ToolCallConformance`` value from this row.
        /// Unknown raw values fall back to the `.unknown` / `.templateExpressible`
        /// defaults rather than crashing.
        public func toConformance() -> ToolCallConformance {
            ToolCallConformance(
                capability: ToolCallCapability(rawValue: capabilityRaw) ?? .unknown,
                observedDialect: observedDialect,
                source: ToolCallConformanceSource(rawValue: sourceRaw) ?? .templateExpressible,
                precision: precision,
                recall: recall,
                f1: f1,
                measuredAt: measuredAt,
                sampleCount: sampleCount
            )
        }

        /// Mutating in-place update from a ``ToolCallConformance`` value.
        /// Key columns (`modelName`, `quant`, `backend`) are left untouched.
        public func update(from conformance: ToolCallConformance) {
            capabilityRaw = conformance.capability.rawValue
            sourceRaw = conformance.source.rawValue
            observedDialect = conformance.observedDialect
            precision = conformance.precision
            recall = conformance.recall
            f1 = conformance.f1
            measuredAt = conformance.measuredAt
            sampleCount = conformance.sampleCount
        }
    }
}
