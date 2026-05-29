import Foundation
import ManifoldInference

// Source-compatibility shim: lets callers convert the SwiftData `@Model`
// `ChatSession` into the storage-agnostic `ChatSessionRecord` used by
// ManifoldInference APIs.
extension ChatSession {

    /// Returns a storage-agnostic snapshot of this session suitable for
    /// passing to inference services that don't depend on SwiftData.
    public var record: ChatSessionRecord {
        // Map SwiftData @Model Agent rows to the storage-agnostic
        // ManifoldInference.Agent value type so consumers downstream of
        // ChatSessionRecord (HandoffToolSource, ConversationTurnExecutor)
        // don't need to import the persistence module.
        //
        // The inverse — persisting `agents` back into Agent rows — lives in
        // SwiftDataPersistenceProvider.reconcileAgents(on:with:), invoked from
        // insertSession/updateSession so this read mapping has a lossless write
        // counterpart (#1495).
        let agentRecords: [ManifoldInference.Agent] = agents.map { row in
            ManifoldInference.Agent(
                id: row.id,
                name: row.name,
                systemPrompt: row.systemPrompt,
                description: row.descriptionText,
                allowedToolNames: row.allowedToolNames
            )
        }
        return ChatSessionRecord(
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
            pinnedMessageIDs: pinnedMessageIDs,
            isPinned: isPinned,
            pinnedAt: pinnedAt,
            agents: agentRecords,
            activeAgentID: activeAgentID,
            activeSkillName: activeSkillName
        )
    }
}
