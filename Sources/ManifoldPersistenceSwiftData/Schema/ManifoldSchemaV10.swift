import Foundation
import ManifoldInference
import ManifoldRuntime
@preconcurrency import SwiftData

/// ManifoldKit SwiftData schema version 10.
///
/// Adds durable storage for resumable runs (P3b, #1784): two new `@Model`
/// types mapping the ``ManifoldRuntime/ConversationRun`` / ``ManifoldRuntime/RunStep``
/// value types persisted by ``SwiftDataRunStore``.
///
/// - ``ConversationRunModel`` — one row per run; stores `status` as its
///   `RunStatus.rawValue` string and carries the run's goal, step count, step
///   cap, and lifecycle timestamps.
/// - ``RunStepModel`` — one row per step; carries `stepIndex`, completion /
///   failure flags, an optional produced-message id, and a best-effort
///   JSON-encoded `TurnInput` blob (see the field doc for the lossiness
///   contract).
///
/// Both new types are purely additive — no existing column changes, no data
/// motion. Every other model type (ChatSession, ChatMessage, Agent, sampler
/// preset, API endpoint, benchmark cache, RAG document, usage record) is
/// carried forward from V9 unchanged.
public enum ManifoldSchemaV10: VersionedSchema {
    public static let versionIdentifier = Schema.Version(10, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            // Carried forward verbatim from V9 — V10 does not redefine these.
            ManifoldSchemaV9.ChatMessage.self,
            ManifoldSchemaV9.ChatSession.self,
            ManifoldSchemaV9.Agent.self,
            ManifoldSchemaV4.SamplerPreset.self,
            ManifoldSchemaV4.APIEndpoint.self,
            ManifoldSchemaV4.ModelBenchmarkCache.self,
            ManifoldSchemaV5.RagDocument.self,
            ManifoldSchemaV6.TurnUsageModel.self,
            // New in V10.
            ConversationRunModel.self,
            RunStepModel.self,
        ]
    }

    // MARK: - ConversationRunModel (V10 — new model)

    /// SwiftData row backing ``ManifoldRuntime/ConversationRun``.
    ///
    /// `status` is stored as its ``RunStatus`` raw string so the persisted
    /// shape is stable across enum-case reordering. `maxSteps` is optional and
    /// mirrors the value type's "nil means unlimited" contract.
    @Model
    public final class ConversationRunModel {
        @Attribute(.unique) public var id: UUID
        public var sessionID: UUID
        public var goal: String

        /// ``RunStatus`` raw value. Rows decode through `RunStatus(rawValue:)`,
        /// defaulting to `.pending` if an unknown string ever lands here.
        public var statusRaw: String

        public var stepCount: Int
        public var maxSteps: Int?
        public var createdAt: Date
        public var updatedAt: Date

        public init(
            id: UUID,
            sessionID: UUID,
            goal: String,
            statusRaw: String,
            stepCount: Int,
            maxSteps: Int?,
            createdAt: Date,
            updatedAt: Date
        ) {
            self.id = id
            self.sessionID = sessionID
            self.goal = goal
            self.statusRaw = statusRaw
            self.stepCount = stepCount
            self.maxSteps = maxSteps
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        /// Builds a model row from a ``ConversationRun`` value.
        public convenience init(_ run: ConversationRun) {
            self.init(
                id: run.id,
                sessionID: run.sessionID,
                goal: run.goal,
                statusRaw: run.status.rawValue,
                stepCount: run.stepCount,
                maxSteps: run.maxSteps,
                createdAt: run.createdAt,
                updatedAt: run.updatedAt
            )
        }

        /// Mutating in-place update from a ``ConversationRun`` value. Identity
        /// columns (`id`, `sessionID`, `createdAt`) are left untouched.
        public func update(from run: ConversationRun) {
            goal = run.goal
            statusRaw = run.status.rawValue
            stepCount = run.stepCount
            maxSteps = run.maxSteps
            updatedAt = run.updatedAt
        }

        /// Converts back to the value type.
        public func toRecord() -> ConversationRun {
            ConversationRun(
                id: id,
                sessionID: sessionID,
                goal: goal,
                status: RunStatus(rawValue: statusRaw) ?? .pending,
                stepCount: stepCount,
                maxSteps: maxSteps,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    // MARK: - RunStepModel (V10 — new model)

    /// SwiftData row backing ``ManifoldRuntime/RunStep``.
    ///
    /// `turnInput` is persisted best-effort as a JSON string column
    /// (``turnInputJSON``). The resume design (M1) replays via the provider,
    /// so `turnInput` is **inspection metadata, not required for resume
    /// correctness** — a decode failure surfaces as `nil` on read and is
    /// logged, never thrown. This matches the value type, where `turnInput`
    /// is already nil-able for goal-derived steps.
    @Model
    public final class RunStepModel {
        @Attribute(.unique) public var id: UUID
        public var runID: UUID
        public var stepIndex: Int

        /// JSON-encoded ``TurnInput``. `nil` when the step had no input
        /// (goal-derived) or when encoding failed. Decoded best-effort; a
        /// decode failure yields `nil` and is logged.
        public var turnInputJSON: String?

        public var messageID: UUID?
        public var isCompleted: Bool
        public var isFailed: Bool
        public var failureReason: String?
        public var createdAt: Date
        public var updatedAt: Date

        public init(
            id: UUID,
            runID: UUID,
            stepIndex: Int,
            turnInputJSON: String?,
            messageID: UUID?,
            isCompleted: Bool,
            isFailed: Bool,
            failureReason: String?,
            createdAt: Date,
            updatedAt: Date
        ) {
            self.id = id
            self.runID = runID
            self.stepIndex = stepIndex
            self.turnInputJSON = turnInputJSON
            self.messageID = messageID
            self.isCompleted = isCompleted
            self.isFailed = isFailed
            self.failureReason = failureReason
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        /// Builds a model row from a ``RunStep`` value, JSON-encoding the
        /// optional `turnInput` best-effort.
        public convenience init(_ step: RunStep) {
            self.init(
                id: step.id,
                runID: step.runID,
                stepIndex: step.stepIndex,
                turnInputJSON: Self.encode(step.turnInput),
                messageID: step.messageID,
                isCompleted: step.isCompleted,
                isFailed: step.isFailed,
                failureReason: step.failureReason,
                createdAt: step.createdAt,
                updatedAt: step.updatedAt
            )
        }

        /// Mutating in-place update from a ``RunStep`` value. Identity columns
        /// (`id`, `runID`, `stepIndex`, `createdAt`) are left untouched.
        public func update(from step: RunStep) {
            turnInputJSON = Self.encode(step.turnInput)
            messageID = step.messageID
            isCompleted = step.isCompleted
            isFailed = step.isFailed
            failureReason = step.failureReason
            updatedAt = step.updatedAt
        }

        /// Converts back to the value type, decoding `turnInput` best-effort.
        public func toRecord() -> RunStep {
            RunStep(
                id: id,
                runID: runID,
                stepIndex: stepIndex,
                turnInput: Self.decode(turnInputJSON),
                messageID: messageID,
                isCompleted: isCompleted,
                isFailed: isFailed,
                failureReason: failureReason,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }

        // MARK: - TurnInput JSON Helpers

        static func encode(_ turnInput: TurnInput?) -> String? {
            guard let turnInput else { return nil }
            do {
                let data = try JSONEncoder().encode(turnInput)
                return String(data: data, encoding: .utf8)
            } catch {
                // Lossy by design (M1): turnInput is inspection metadata, not
                // resume-critical. Drop on encode failure rather than fail the
                // step write.
                Log.persistence.warning("Failed to encode RunStep.turnInput; persisting nil: \(error)")
                return nil
            }
        }

        static func decode(_ json: String?) -> TurnInput? {
            guard let data = json?.data(using: .utf8) else { return nil }
            do {
                return try JSONDecoder().decode(TurnInput.self, from: data)
            } catch {
                Log.persistence.warning("Failed to decode RunStep.turnInputJSON; returning nil: \(error)")
                return nil
            }
        }
    }
}
