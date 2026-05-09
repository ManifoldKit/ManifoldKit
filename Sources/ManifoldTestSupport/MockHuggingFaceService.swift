import Foundation
import ManifoldInference
import os

/// Configurable mock HuggingFace service for testing.
///
/// Shared across all test targets via the `ManifoldTestSupport` module.
public final class MockHuggingFaceService: HuggingFaceServiceProtocol {
    private struct State {
        var searchResults: [DownloadableModel] = []
        var searchError: Error?
        var modelFiles: [DownloadableModel] = []
        var modelFilesError: Error?
        var downloadPlans: [String: ModelDownloadPlan] = [:]
        var downloadPlanError: Error?
        var searchCallCount = 0
        var getModelFilesCallCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public var searchResults: [DownloadableModel] {
        get { state.withLock { $0.searchResults } }
        set { state.withLock { $0.searchResults = newValue } }
    }

    public var searchError: Error? {
        get { state.withLock { $0.searchError } }
        set { state.withLock { $0.searchError = newValue } }
    }

    public var modelFiles: [DownloadableModel] {
        get { state.withLock { $0.modelFiles } }
        set { state.withLock { $0.modelFiles = newValue } }
    }

    public var modelFilesError: Error? {
        get { state.withLock { $0.modelFilesError } }
        set { state.withLock { $0.modelFilesError = newValue } }
    }

    public var searchCallCount: Int {
        state.withLock { $0.searchCallCount }
    }

    public var getModelFilesCallCount: Int {
        state.withLock { $0.getModelFilesCallCount }
    }

    public var downloadPlans: [String: ModelDownloadPlan] {
        get { state.withLock { $0.downloadPlans } }
        set { state.withLock { $0.downloadPlans = newValue } }
    }

    public var downloadPlanError: Error? {
        get { state.withLock { $0.downloadPlanError } }
        set { state.withLock { $0.downloadPlanError = newValue } }
    }

    public init() {}

    public func searchModels(query: String, limit: Int = 40) async throws -> [DownloadableModel] {
        let (error, results) = state.withLock { state in
            state.searchCallCount += 1
            return (state.searchError, state.searchResults)
        }
        if let error { throw error }
        return results
    }

    public func curatedModels(for recommendation: ModelSizeRecommendation) -> [DownloadableModel] {
        CuratedModel.all
            .filter { $0.recommendedFor.contains(recommendation) }
            .map { DownloadableModel(from: $0) }
    }

    public func getModelFiles(repoID: String) async throws -> [DownloadableModel] {
        let (error, files) = state.withLock { state in
            state.getModelFilesCallCount += 1
            return (state.modelFilesError, state.modelFiles)
        }
        if let error { throw error }
        return files
    }

    public func downloadPlan(for model: DownloadableModel) async throws -> ModelDownloadPlan {
        let (error, configuredPlan) = state.withLock { state in
            (state.downloadPlanError, state.downloadPlans[model.id])
        }
        if let error { throw error }
        if let configuredPlan { return configuredPlan }
        return .singleFile(url: downloadURL(for: model))
    }

    public func downloadURL(for model: DownloadableModel) -> URL {
        // Safe to force-unwrap: we control the URL components in tests.
        // swiftlint:disable:next force_unwrapping
        URL(string: "https://huggingface.co/\(model.repoID)/resolve/main/\(model.fileName)")!
    }
}
