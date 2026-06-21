import Foundation
import ManifoldInference

// MARK: - ChatViewModel + Respond

extension ChatViewModel {

    /// Sends `text` and returns the assistant's reply as a `String`.
    ///
    /// Convenience over ``sendMessage(_:)`` for callers that only want the
    /// reply text and don't need the full ``ChatMessage`` (citations, parts,
    /// agent identity). The heavy lifting — stream drain, persistence, the
    /// single-turn drive — is inherited unchanged from ``sendMessage(_:)``.
    ///
    /// - Throws: ``SendMessageError`` — `.noActiveSession` / `.noModelLoaded`
    ///   for precondition failures, `.empty` when the turn produces no
    ///   assistant record, or `.runtime(error)` when the underlying runtime
    ///   surfaces an error. Cancellation propagates from ``sendMessage(_:)``.
    @discardableResult
    public func respond(to text: String) async throws -> String {
        try await sendMessage(text).content
    }
}
