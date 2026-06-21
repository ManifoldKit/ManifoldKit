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
    /// - Note: The return is `ChatMessage.content` — the concatenated *visible
    ///   text* parts. A turn that produces only tool calls or only `.thinking`
    ///   parts (no visible text) therefore returns the empty string even though
    ///   the turn ran and an assistant record was persisted. Callers that need
    ///   to distinguish "ran but no visible text" from "produced text" should
    ///   use ``sendMessage(_:)`` and inspect the full ``ChatMessage`` instead.
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
