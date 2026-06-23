import Foundation
import ManifoldInference
import ManifoldRuntime
import SwiftData

/// Default ``ToolCallConformanceCache`` backed by SwiftData.
///
/// Operates on the ``ModelContext`` injected at init time, hiding the
/// SwiftData ``ToolCallConformanceRecord`` `@Model` behind the value-typed
/// ``ToolCallConformanceCache`` port. Mirrors ``SwiftDataBenchmarkCache``'s
/// structure: `@MainActor`-isolated, ModelContext-injected, delete-then-insert
/// upsert semantics.
///
/// A missing key returns ``ToolCallConformance/unknownDefault`` — conformance
/// is lazy and `unknown` until measured, never a cold-start tax.
@MainActor
public final class SwiftDataToolCallConformanceCache: ToolCallConformanceCache {

    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - ToolCallConformanceCache

    public func get(_ key: ToolCallConformanceKey) async -> ToolCallConformance {
        let modelName = key.model
        let quant = key.quant
        let backend = key.backend
        let descriptor = FetchDescriptor<ToolCallConformanceRecord>(
            predicate: #Predicate {
                $0.modelName == modelName
                    && $0.quant == quant
                    && $0.backend == backend
            }
        )
        do {
            let rows = try modelContext.fetch(descriptor)
            return rows.first?.toConformance() ?? .unknownDefault
        } catch {
            Log.persistence.warning("ToolCallConformanceCache.get failed: \(error)")
            return .unknownDefault
        }
    }

    public func put(_ key: ToolCallConformanceKey, _ conformance: ToolCallConformance) async {
        let modelName = key.model
        let quant = key.quant
        let backend = key.backend
        let descriptor = FetchDescriptor<ToolCallConformanceRecord>(
            predicate: #Predicate {
                $0.modelName == modelName
                    && $0.quant == quant
                    && $0.backend == backend
            }
        )
        do {
            // Delete any stale row for this key before inserting the fresh
            // verdict. Mirrors SwiftDataBenchmarkCache's upsert: SwiftData V1
            // does not support multi-column unique constraints, so delete-then-
            // insert is the only safe way to guarantee at-most-one row per key.
            let existing = try modelContext.fetch(descriptor)
            existing.forEach { modelContext.delete($0) }
            modelContext.insert(ToolCallConformanceRecord(key: key, conformance: conformance))
            try modelContext.save()
        } catch {
            Log.persistence.warning("ToolCallConformanceCache.put failed for key (\(key.model, privacy: .public), \(key.backend, privacy: .public)): \(error)")
        }
    }

    public func fetchAll() async -> [ToolCallConformanceKey: ToolCallConformance] {
        do {
            let rows = try modelContext.fetch(FetchDescriptor<ToolCallConformanceRecord>())
            var result: [ToolCallConformanceKey: ToolCallConformance] = [:]
            result.reserveCapacity(rows.count)
            for row in rows {
                result[row.toKey()] = row.toConformance()
            }
            return result
        } catch {
            Log.persistence.warning("ToolCallConformanceCache.fetchAll failed: \(error)")
            return [:]
        }
    }
}
