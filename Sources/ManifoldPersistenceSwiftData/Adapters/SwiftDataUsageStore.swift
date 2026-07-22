import Foundation
import ManifoldInference
import ManifoldRuntime
import SwiftData

/// Default ``UsageStore`` backed by SwiftData.
///
/// Operates on the ``ModelContext`` injected at init time, converting between
/// ``TurnUsageModel`` `@Model` rows and ``TurnUsage`` value types
/// at the boundary.
///
/// `@MainActor` isolation mirrors ``SwiftDataEndpointStore`` and other adapters
/// — SwiftData's `ModelContext` is not `Sendable` and must be touched on the
/// actor that created it (the main actor in bootstrap).
@MainActor
public final class SwiftDataUsageStore: UsageStore {

    private let modelContext: ModelContext
    // Retain the container so ModelContext remains valid even if the caller
    // that owns the container (e.g. ManifoldBootstrap) is freed while an
    // async recording task is still in flight.
    private let container: ModelContainer

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.container = modelContext.container
    }

    // MARK: - UsageStore

    public func record(_ record: TurnUsage) async throws {
        let model = TurnUsageModel(
            id: record.id,
            sessionID: record.sessionID,
            endpointID: record.endpointID,
            modelIdentifier: record.modelIdentifier,
            timestamp: record.timestamp,
            promptTokens: record.promptTokens,
            completionTokens: record.completionTokens,
            cachedInputTokens: record.cachedInputTokens,
            cacheWriteTokens: record.cacheWriteTokens
        )
        modelContext.insert(model)
        try modelContext.save()
    }

    /// The host-facing query surface for the live usage-recording write path.
    ///
    /// `TurnStreamFinalizer` (composed into the turn loop by
    /// `ConversationTurnExecutor`) calls ``record(_:)`` on every completed
    /// turn — the write side is genuinely live — but as of the 2026-07
    /// inert-surface sweep (#2128) this package ships no in-repo reader of
    /// the aggregated summary — no view, view model, or bootstrap wiring
    /// calls `summary(sinceDays:)` anywhere in this repo. That is a
    /// documentation and adoption gap, not dead code: a host that wants a
    /// token-usage dashboard or cost estimate reads it back through this
    /// method (or ``recentRecords(limit:)`` below) via the ``UsageStore``
    /// port it's already wired up to receive.
    public func summary(sinceDays: Int) async throws -> UsageSummary {
        let cutoff = cutoffDate(sinceDays: sinceDays)
        let descriptor = FetchDescriptor<TurnUsageModel>(
            predicate: #Predicate { $0.timestamp >= cutoff }
        )
        let records = try modelContext.fetch(descriptor)
        return aggregate(records)
    }

    public func summary(forEndpoint endpointID: UUID, sinceDays: Int) async throws -> UsageSummary {
        let cutoff = cutoffDate(sinceDays: sinceDays)
        let descriptor = FetchDescriptor<TurnUsageModel>(
            predicate: #Predicate { $0.endpointID == endpointID && $0.timestamp >= cutoff }
        )
        let records = try modelContext.fetch(descriptor)
        return aggregate(records)
    }

    /// The host-facing query surface for the most recent raw ``TurnUsage``
    /// rows, unaggregated — same "live write, no in-repo reader" situation as
    /// ``summary(sinceDays:)`` above. Use this over `summary` when a host
    /// wants a per-turn usage list (a cost ledger, an audit trail) rather
    /// than a rolled-up total.
    public func recentRecords(limit: Int) async throws -> [TurnUsage] {
        var descriptor = FetchDescriptor<TurnUsageModel>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map { $0.toRecord() }
    }

    // MARK: - Private helpers

    /// Returns a `Date` representing midnight `sinceDays` calendar days ago.
    private func cutoffDate(sinceDays: Int) -> Date {
        let now = Date()
        let seconds = TimeInterval(sinceDays) * 86_400
        return now.addingTimeInterval(-seconds)
    }

    /// Reduces a sequence of fetched model rows into a ``UsageSummary``.
    private func aggregate(_ rows: [TurnUsageModel]) -> UsageSummary {
        var promptTotal = 0
        var completionTotal = 0
        var cachedInputTotal = 0
        var cacheWriteTotal = 0
        for row in rows {
            promptTotal += row.promptTokens
            completionTotal += row.completionTokens
            cachedInputTotal += row.cachedInputTokens ?? 0
            cacheWriteTotal += row.cacheWriteTokens ?? 0
        }
        return UsageSummary(
            totalPromptTokens: promptTotal,
            totalCompletionTokens: completionTotal,
            totalCachedInputTokens: cachedInputTotal,
            totalCacheWriteTokens: cacheWriteTotal,
            turnCount: rows.count
        )
    }
}
