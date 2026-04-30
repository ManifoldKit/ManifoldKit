import Foundation
import BaseChatInference

// Source-compatibility shim: lets callers convert the SwiftData `@Model`
// `ChatSession` into the storage-agnostic `ChatSessionRecord` used by
// BaseChatInference APIs.
extension ChatSession {

    /// Returns a storage-agnostic snapshot of this session suitable for
    /// passing to inference services that don't depend on SwiftData.
    public var record: ChatSessionRecord {
        ChatSessionRecord(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            systemPrompt: systemPrompt,
            selectedModelID: selectedModelID,
            selectedEndpointID: selectedEndpointID,
            temperature: temperature,
            topP: topP,
            repeatPenalty: repeatPenalty,
            promptTemplate: promptTemplate,
            contextSizeOverride: contextSizeOverride,
            pinnedMessageIDs: pinnedMessageIDs
        )
    }
}
