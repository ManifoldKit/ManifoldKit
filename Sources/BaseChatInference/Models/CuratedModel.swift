import Foundation
import os

/// A recommended model from the curated list, with known-good metadata.
///
/// These are verified HuggingFace repos that work well with a given app's
/// inference backends. Each entry includes the correct prompt template,
/// approximate size, and which device classes can run it.
///
/// Apps should provide their own curated list by populating `CuratedModel.all`
/// (or by building their own list and passing it to the relevant services).
/// The default `all` is intentionally empty so BaseChatKit has no opinion
/// about which models to surface.
public struct CuratedModel: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let fileName: String
    public let repoID: String
    public let modelType: ModelType
    public let approximateSizeBytes: UInt64
    public let recommendedFor: Set<ModelSizeRecommendation>
    public let contextSize: Int32
    public let promptTemplate: PromptTemplate
    public let description: String

    public init(
        id: String,
        displayName: String,
        fileName: String,
        repoID: String,
        modelType: ModelType,
        approximateSizeBytes: UInt64,
        recommendedFor: Set<ModelSizeRecommendation>,
        contextSize: Int32,
        promptTemplate: PromptTemplate,
        description: String
    ) {
        self.id = id
        self.displayName = displayName
        self.fileName = fileName
        self.repoID = repoID
        self.modelType = modelType
        self.approximateSizeBytes = approximateSizeBytes
        self.recommendedFor = recommendedFor
        self.contextSize = contextSize
        self.promptTemplate = promptTemplate
        self.description = description
    }

    /// The curated model list to display in model discovery UI.
    ///
    /// This is empty by default — apps should populate it with their own list
    /// at startup or by subclassing/extending CuratedModel as needed.
    private static let storage = OSAllocatedUnfairLock<[CuratedModel]>(
        initialState: []
    )

    public static var all: [CuratedModel] {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}
