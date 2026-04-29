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
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        temperature: Float = 0.7,
        topP: Float = 0.9,
        repeatPenalty: Float = 1.1,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.temperature = temperature
        self.topP = topP
        self.repeatPenalty = repeatPenalty
        self.createdAt = createdAt
    }
}
