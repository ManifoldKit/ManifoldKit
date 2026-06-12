import Foundation
import ManifoldInference

// MARK: - RunStore
//
// P3b: the persistence port for ConversationRun records. Mirrors the shape
// of the other store ports (MessageStore, SessionStore, SamplerPresetStore):
//   - `@MainActor` isolation for parity with SwiftData's ModelContext.
//   - Traffic in value types (ConversationRun, RunStep) — no @Model escapes.
//   - `async throws` surface, sync-to-async at the impl.
//
// The SwiftData adapter lives in ManifoldPersistenceSwiftData (Ring 2), not
// here. ManifoldRuntime owns only the port. Implementation: deferred to P3b
// persistence sub-phase (schema migration + @Model types). Hosts that do not
// need resumable runs simply omit the store from the bootstrap — the
// ResumableRunDriver returns an error without it, and all existing paths
// continue through SingleTurnDriver unchanged.

/// Errors produced by ``RunStore`` implementations.
public enum RunStoreError: Error, LocalizedError, Sendable, Equatable {
    case runNotFound(UUID)
    case stepNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case let .runNotFound(id):
            return "ConversationRun not found: \(id.uuidString)"
        case let .stepNotFound(id):
            return "RunStep not found: \(id.uuidString)"
        }
    }
}

/// Storage port for ``ConversationRun`` checkpoint records.
///
/// Mirrors the shape of ``MessageStore`` / ``SessionStore``:
/// `@MainActor`-isolated, `async throws` surface, value-type traffic.
///
/// The SwiftData adapter lives in `ManifoldPersistenceSwiftData` — this port
/// is the only RunStore symbol that `ManifoldRuntime` owns. Hosts that do not
/// need resumable runs omit it from their bootstrap; all existing turn paths
/// route through ``SingleTurnDriver`` and never touch the store.
@MainActor
public protocol RunStore: AnyObject, Sendable {

    // MARK: Runs

    /// Inserts a new run record.
    ///
    /// - Throws: Storage errors from the underlying store.
    func insertRun(_ run: ConversationRun) async throws

    /// Updates an existing run record.
    ///
    /// - Throws:
    ///   - ``RunStoreError/runNotFound(_:)`` when the run does not exist.
    ///   - Storage errors from the underlying store.
    func updateRun(_ run: ConversationRun) async throws

    /// Deletes a run by id.
    ///
    /// - Throws:
    ///   - ``RunStoreError/runNotFound(_:)`` when the run does not exist.
    ///   - Storage errors from the underlying store.
    func deleteRun(_ id: UUID) async throws

    /// Fetches all runs for a session, ordered most-recently-created first.
    ///
    /// - Throws: Storage errors from the underlying store.
    func fetchRuns(for sessionID: UUID) async throws -> [ConversationRun]

    /// Fetches a single run by id, or `nil` when not found.
    ///
    /// - Throws: Storage errors from the underlying store.
    func fetchRun(_ id: UUID) async throws -> ConversationRun?

    // MARK: Steps

    /// Inserts a new step record.
    ///
    /// - Throws: Storage errors from the underlying store.
    func insertStep(_ step: RunStep) async throws

    /// Updates an existing step record.
    ///
    /// - Throws:
    ///   - ``RunStoreError/stepNotFound(_:)`` when the step does not exist.
    ///   - Storage errors from the underlying store.
    func updateStep(_ step: RunStep) async throws

    /// Fetches all steps for a run, ordered by `stepIndex` ascending.
    ///
    /// - Throws: Storage errors from the underlying store.
    func fetchSteps(for runID: UUID) async throws -> [RunStep]
}
