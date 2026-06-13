import Foundation
import ManifoldInference
import ManifoldRuntime
import SwiftData

/// Default ``RunStore`` backed by SwiftData.
///
/// Operates on the ``ModelContext`` injected at init time, converting between
/// the ``ManifoldSchemaV10/ConversationRunModel`` / ``ManifoldSchemaV10/RunStepModel``
/// `@Model` rows and the ``ConversationRun`` / ``RunStep`` value types at the
/// boundary. No `@Model` escapes the port. Mirrors the isolation and `save()`
/// discipline of ``SwiftDataBenchmarkCache`` / ``SwiftDataSamplerPresetStore``.
@MainActor
public final class SwiftDataRunStore: RunStore {

    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Runs

    public func insertRun(_ run: ConversationRun) async throws {
        modelContext.insert(ConversationRunModel(run))
        try modelContext.save()
    }

    public func updateRun(_ run: ConversationRun) async throws {
        guard let existing = try fetchRunModel(run.id) else {
            throw RunStoreError.runNotFound(run.id)
        }
        existing.update(from: run)
        try modelContext.save()
    }

    public func deleteRun(_ id: UUID) async throws {
        guard let existing = try fetchRunModel(id) else {
            throw RunStoreError.runNotFound(id)
        }
        // Steps are not a cascade relationship — delete them explicitly so a
        // deleted run does not strand orphaned step rows.
        for step in try fetchStepModels(for: id) {
            modelContext.delete(step)
        }
        modelContext.delete(existing)
        try modelContext.save()
    }

    public func fetchRuns(for sessionID: UUID) async throws -> [ConversationRun] {
        let descriptor = FetchDescriptor<ConversationRunModel>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map { $0.toRecord() }
    }

    public func fetchRun(_ id: UUID) async throws -> ConversationRun? {
        try fetchRunModel(id)?.toRecord()
    }

    // MARK: - Steps

    public func insertStep(_ step: RunStep) async throws {
        modelContext.insert(RunStepModel(step))
        try modelContext.save()
    }

    public func updateStep(_ step: RunStep) async throws {
        guard let existing = try fetchStepModel(step.id) else {
            throw RunStoreError.stepNotFound(step.id)
        }
        existing.update(from: step)
        try modelContext.save()
    }

    public func fetchSteps(for runID: UUID) async throws -> [RunStep] {
        try fetchStepModels(for: runID).map { $0.toRecord() }
    }

    // MARK: - Private fetch helpers

    private typealias ConversationRunModel = ManifoldSchemaV10.ConversationRunModel
    private typealias RunStepModel = ManifoldSchemaV10.RunStepModel

    private func fetchRunModel(_ id: UUID) throws -> ConversationRunModel? {
        try modelContext.fetch(FetchDescriptor<ConversationRunModel>(
            predicate: #Predicate { $0.id == id }
        )).first
    }

    private func fetchStepModel(_ id: UUID) throws -> RunStepModel? {
        try modelContext.fetch(FetchDescriptor<RunStepModel>(
            predicate: #Predicate { $0.id == id }
        )).first
    }

    private func fetchStepModels(for runID: UUID) throws -> [RunStepModel] {
        try modelContext.fetch(FetchDescriptor<RunStepModel>(
            predicate: #Predicate { $0.runID == runID },
            sortBy: [SortDescriptor(\.stepIndex, order: .forward)]
        ))
    }
}
