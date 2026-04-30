import Foundation
import BaseChatCore
import BaseChatInference

// MARK: - ChatViewModel + RuntimeAdapter
//
// Maps ConversationEvent values from the optional ConversationRuntime drain
// task back to @Observable state mutations. This file owns the event-to-state
// bridge; ChatViewModel+Messages.swift owns the send/regenerate/edit/stop
// delegation through the runtime.

extension ChatViewModel {

    /// Maps an incoming ``ConversationEvent`` to `@Observable` state mutations.
    ///
    /// Called exclusively from the long-lived drain task started in
    /// ``configure(conversationRuntime:)``. All mutations land on `@MainActor`
    /// so SwiftUI observation picks them up synchronously.
    @MainActor
    func handle(runtimeEvent event: ConversationEvent) async {
        switch event {

        // MARK: Message lifecycle

        case .messageInserted(let record):
            // Guard against duplicates — the runtime may insert the user
            // message before `sendMessage` appends it locally, or vice versa.
            if !messages.contains(where: { $0.id == record.id }) {
                messages.append(record)
            } else {
                // Update in place in case the runtime persisted a richer version
                // (e.g. timestamped) of a message we pre-inserted as a placeholder.
                mutateMessage(id: record.id) { $0 = record }
            }

        case .messageRemoved(let id):
            messages.removeAll(where: { $0.id == id })

        case .messageUpdated(let record):
            if let idx = messages.firstIndex(where: { $0.id == record.id }) {
                messages[idx] = record
            }

        // MARK: Stream lifecycle

        case .streamStarted:
            // The runtime pre-inserts the assistant record; here we just
            // transition phase. The actual message slot arrives via
            // .messageInserted when the runtime finalises the assistant record.
            transitionPhase(to: .waitingForFirstToken)

        case .tokenEmitted(let messageID, let delta):
            transitionPhase(to: .streaming)
            mutateMessage(id: messageID) { $0.content += delta }

        case .streamFinished:
            transitionPhase(to: .idle)
            updateContextEstimate()

        // MARK: Errors

        case .errorRaised(let error):
            switch error {
            case .persistence(let underlying):
                surfaceError(underlying, kind: .persistence)
            case .inference(let underlying):
                surfaceError(underlying, kind: .generation)
            case .cancelled:
                // User-initiated cancel — suppress error UI.
                break
            case .contextAssembly(let underlying):
                surfaceError(underlying, kind: .generation)
            case .messageNotFound, .noAssistantMessageToRegenerate, .providerNotConfigured:
                errorMessage = error.localizedDescription
            }
            transitionPhase(to: .idle)

        // MARK: Observational / future cases

        case .beforeContextAssembly, .contextAssembled, .afterGeneration,
             .compressionTriggered, .toolCallRequested, .toolCallApproved,
             .toolCallCompleted, .sessionBranched:
            // These are observational or reserved for future sub-flows.
            // No ChatViewModel state mutation is needed here yet.
            break
        }
    }
}
