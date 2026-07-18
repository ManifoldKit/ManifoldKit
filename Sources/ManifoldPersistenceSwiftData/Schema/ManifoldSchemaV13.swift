import Foundation
import ManifoldRuntime
@preconcurrency import SwiftData

/// ManifoldKit SwiftData schema version 13.
///
/// Adds durable storage for session branch-origin provenance (#2307
/// branch-origin chip): one new `@Model` type, keyed by plain `UUID` rather
/// than a `@Relationship` onto `ChatSession`.
///
/// - ``BranchOrigin`` — one row per branched session, storing the branched
///   session's own id (`sessionID`), the source session's id
///   (`originSessionID`), and a snapshot of the source session's title at
///   branch time (`originTitleSnapshot`).
///
/// **Why a side table, not a redefined `ChatSession`:** an earlier version of
/// this change redefined `ChatSession` in its own V13 namespace (the same
/// in-namespace-redefinition pattern V9 used for `activeAgentID` /
/// `activeSkillName` / `agents`). That approach hit a genuine SwiftData
/// migration-graph bug: opening a store seeded at an old pinned schema
/// (`ModelContainer(for: Schema(versionedSchema: ManifoldSchemaV3/V7/V8.self))`,
/// the exact pattern `SchemaMigrationTests` uses to test every prior stage)
/// through `ModelContainerFactory.makeContainer`'s full migration plan threw
/// `NSInvalidArgumentException "Duplicate version checksums detected."` —
/// reproducible even for the unrelated V3→V4 and V7→V8 stages, and absent on
/// `main` (confirmed by running the identical test against an unmodified
/// checkout). Redefining `ChatSession` a *second* time (V9 was the first)
/// appears to be what SwiftData's schema-checksum disambiguation can't
/// handle once a chain both re-declares the same-named entity more than once
/// *and* is opened starting from several versions further back. A side
/// table sidesteps the whole class of failure and matches the precedent V10
/// (`ConversationRunModel`/`RunStepModel`), V11 (`ToolCallConformanceRecord`),
/// and V12 (`Persona`) already set: every version after V9 only ever *adds*
/// a model, never redefines `ChatSession` again.
///
/// The new type is purely additive — no existing column changes, no data
/// motion. Every other model type (ChatSession, ChatMessage, Agent, sampler
/// preset, API endpoint, benchmark cache, RAG document, usage record,
/// conversation run, run step, tool-call conformance, persona) is carried
/// forward from V12 unchanged.
public enum ManifoldSchemaV13: VersionedSchema {
    public static let versionIdentifier = Schema.Version(13, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            // Carried forward verbatim from V12 — V13 does not redefine these.
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
            ManifoldSchemaV12.Persona.self,
            // New in V13.
            BranchOrigin.self,
        ]
    }

    // MARK: - BranchOrigin (V13 — new model)

    /// SwiftData row recording a session's branch-origin provenance.
    ///
    /// Not a `@Relationship` onto `ChatSession` — the source session can be
    /// deleted independently of any session branched from it, and a
    /// `@Relationship` here would either cascade-delete branches on source
    /// deletion (destroying history) or require `.nullify` bookkeeping this
    /// plain-UUID side table already handles by simply going stale (the read
    /// path falls back to ``originTitleSnapshot`` once ``originSessionID``
    /// no longer resolves to a live session).
    @Model
    public final class BranchOrigin {
        /// The branched (child) session's id. One row per branched session,
        /// so this is the natural lookup key from the read path.
        @Attribute(.unique) public var sessionID: UUID

        /// The source session's id at branch time.
        public var originSessionID: UUID

        /// Snapshot of the source session's title, captured at branch time.
        /// Read-path fallback: prefer resolving the source's *current* title
        /// live via `originSessionID`; fall back to this snapshot once the
        /// source session has been deleted.
        public var originTitleSnapshot: String?

        public init(sessionID: UUID, originSessionID: UUID, originTitleSnapshot: String?) {
            self.sessionID = sessionID
            self.originSessionID = originSessionID
            self.originTitleSnapshot = originTitleSnapshot
        }
    }
}
