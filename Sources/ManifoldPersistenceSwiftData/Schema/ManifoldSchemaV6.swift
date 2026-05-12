import Foundation
import ManifoldInference
import ManifoldRuntime
@preconcurrency import SwiftData

/// ManifoldKit SwiftData schema version 6.
///
/// Adds ``TurnUsageRecordModel`` for per-turn token accounting. All V5 model
/// types (including ``ManifoldSchemaV5/RagDocument``) are carried forward
/// unchanged via a lightweight migration stage.
public enum ManifoldSchemaV6: VersionedSchema {
    public static let versionIdentifier = Schema.Version(6, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            ManifoldSchemaV4.ChatMessage.self,
            ManifoldSchemaV4.ChatSession.self,
            ManifoldSchemaV4.SamplerPreset.self,
            ManifoldSchemaV4.APIEndpoint.self,
            ManifoldSchemaV4.ModelBenchmarkCache.self,
            ManifoldSchemaV5.RagDocument.self,
            TurnUsageRecordModel.self,
        ]
    }

    // MARK: - TurnUsageRecordModel

    /// Persists one ``TurnUsageRecord`` value type from `ManifoldRuntime`.
    ///
    /// SwiftData `@Model` types must be classes, so this is the mutable class
    /// backing for the immutable ``TurnUsageRecord`` value. Callers always read
    /// and write via the port layer (``SwiftDataUsageStore``) rather than
    /// touching this model directly.
    @Model
    public final class TurnUsageRecordModel {
        public var id: UUID
        public var sessionID: UUID
        /// Nullable so on-device backends (MLX, Llama, Foundation) that have no
        /// cloud endpoint can still produce records.
        public var endpointID: UUID?
        public var modelIdentifier: String
        public var timestamp: Date
        public var promptTokens: Int
        public var completionTokens: Int
        /// Anthropic prompt-cache hit tokens; `nil` for backends that don't
        /// report cache metrics.
        public var cachedInputTokens: Int?
        /// Anthropic cache-creation tokens; `nil` for backends that don't
        /// report cache metrics.
        public var cacheWriteTokens: Int?

        public init(
            id: UUID,
            sessionID: UUID,
            endpointID: UUID?,
            modelIdentifier: String,
            timestamp: Date,
            promptTokens: Int,
            completionTokens: Int,
            cachedInputTokens: Int?,
            cacheWriteTokens: Int?
        ) {
            self.id = id
            self.sessionID = sessionID
            self.endpointID = endpointID
            self.modelIdentifier = modelIdentifier
            self.timestamp = timestamp
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.cachedInputTokens = cachedInputTokens
            self.cacheWriteTokens = cacheWriteTokens
        }

        /// Converts this SwiftData model into the port's value type.
        func toRecord() -> TurnUsageRecord {
            TurnUsageRecord(
                id: id,
                sessionID: sessionID,
                endpointID: endpointID,
                modelIdentifier: modelIdentifier,
                timestamp: timestamp,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                cachedInputTokens: cachedInputTokens,
                cacheWriteTokens: cacheWriteTokens
            )
        }
    }
}

/// Public typealias so callers can refer to `TurnUsageRecordModel` without
/// qualifying the schema version namespace.
public typealias TurnUsageRecordModel = ManifoldSchemaV6.TurnUsageRecordModel
