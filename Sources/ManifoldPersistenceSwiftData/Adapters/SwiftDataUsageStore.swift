import Foundation
import ManifoldInference
import ManifoldRuntime
import SwiftData

/// Default ``UsageStore`` backed by SwiftData.
///
/// Operates on the ``ModelContext`` injected at init time, converting between
/// ``TurnUsageRecordModel`` `@Model` rows and ``TurnUsageRecord`` value types
/// at the boundary.
///
/// `@MainActor` isolation mirrors ``SwiftDataEndpointStore`` and other adapters
/// — SwiftData's `ModelContext` is not `Sendable` and must be touched on the
/// actor that created it (the main actor in bootstrap).
@MainActor
public final class SwiftDataUsageStore: UsageStore {

    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - UsageStore

    public func record(_ record: TurnUsageRecord) async throws {
        let model = TurnUsageRecordModel(
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

    public func summary(sinceDays: Int) async throws -> UsageSummary {
        let cutoff = cutoffDate(sinceDays: sinceDays)
        let descriptor = FetchDescriptor<TurnUsageRecordModel>(
            predicate: #Predicate { $0.timestamp >= cutoff }
        )
        let records = try modelContext.fetch(descriptor)
        return aggregate(records)
    }

    public func summary(forEndpoint endpointID: UUID, sinceDays: Int) async throws -> UsageSummary {
        let cutoff = cutoffDate(sinceDays: sinceDays)
        let descriptor = FetchDescriptor<TurnUsageRecordModel>(
            predicate: #Predicate { $0.endpointID == endpointID && $0.timestamp >= cutoff }
        )
        let records = try modelContext.fetch(descriptor)
        return aggregate(records)
    }

    public func recentRecords(limit: Int) async throws -> [TurnUsageRecord] {
        var descriptor = FetchDescriptor<TurnUsageRecordModel>(
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
    private func aggregate(_ rows: [TurnUsageRecordModel]) -> UsageSummary {
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
