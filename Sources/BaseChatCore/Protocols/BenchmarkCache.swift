import Foundation
import BaseChatInference

/// Storage-neutral port for persisting per-model benchmark results.
///
/// Replaces the public `ModelManagementViewModel.modelContext: ModelContext?`
/// property — host code now injects a ``BenchmarkCache`` (typically
/// ``SwiftDataBenchmarkCache`` over the app's main context) and the view model
/// reads/upserts via the port instead of executing SwiftData fetches itself.
///
/// Entries are keyed by the model's file name (e.g. `"model.Q4_K_M.gguf"`),
/// matching the existing ``ModelBenchmarkCache`` SwiftData schema. The port
/// trafficks in ``ModelBenchmarkResult`` value types — the SwiftData `@Model`
/// never escapes the impl.
@MainActor
public protocol BenchmarkCache: AnyObject, Sendable {

    /// Fetches every cached benchmark result keyed by model file name.
    func fetchAll() async throws -> [String: ModelBenchmarkResult]

    /// Stores a benchmark result for the given model file name, replacing any
    /// previous entry for the same file.
    func upsert(modelFileName: String, result: ModelBenchmarkResult) async throws
}
