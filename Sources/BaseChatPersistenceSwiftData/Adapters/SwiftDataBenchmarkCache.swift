import Foundation
import BaseChatInference
import BaseChatRuntime
import SwiftData

/// Default ``BenchmarkCache`` backed by SwiftData.
///
/// Operates on the ``ModelContext`` injected at init time, hiding the
/// SwiftData ``ModelBenchmarkCache`` `@Model` behind a value-typed port.
@MainActor
public final class SwiftDataBenchmarkCache: BenchmarkCache {

    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    public func fetchAll() async throws -> [String: ModelBenchmarkResult] {
        let entries = try modelContext.fetch(FetchDescriptor<ModelBenchmarkCache>())
        var result: [String: ModelBenchmarkResult] = [:]
        result.reserveCapacity(entries.count)
        for entry in entries {
            result[entry.modelFileName] = entry.toResult()
        }
        return result
    }

    public func upsert(modelFileName: String, result: ModelBenchmarkResult) async throws {
        // Remove any stale entry for this file name before inserting the fresh
        // result. Mirrors the upsert semantics that previously lived inline in
        // `ModelManagementViewModel.runBenchmark(for:)`.
        let needle = modelFileName
        let existing = try modelContext.fetch(FetchDescriptor<ModelBenchmarkCache>(
            predicate: #Predicate { $0.modelFileName == needle }
        ))
        existing.forEach { modelContext.delete($0) }
        modelContext.insert(ModelBenchmarkCache(modelFileName: modelFileName, result: result))
        try modelContext.save()
    }
}
