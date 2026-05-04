import Foundation

/// Plain-data snapshot of a saved sampler preset, decoupled from any specific
/// storage backend.
///
/// `BaseChatCore` provides the SwiftData `@Model SamplerPreset` that maps to
/// this record; UI flows traffic in records so they don't need a SwiftData
/// dependency on the read or write path.
public struct SamplerPresetRecord: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var temperature: Float
    public var topP: Float
    public var repeatPenalty: Float
    public var presencePenalty: Float?
    public var frequencyPenalty: Float?
    public var repetitionContextSize: Int?
    public var presenceContextSize: Int?
    public var frequencyContextSize: Int?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        presencePenalty: Float? = nil,
        frequencyPenalty: Float? = nil,
        repetitionContextSize: Int? = nil,
        presenceContextSize: Int? = nil,
        frequencyContextSize: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.temperature = temperature
        self.topP = topP
        self.repeatPenalty = repeatPenalty
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
        self.repetitionContextSize = repetitionContextSize
        self.presenceContextSize = presenceContextSize
        self.frequencyContextSize = frequencyContextSize
        self.createdAt = createdAt
    }
}
