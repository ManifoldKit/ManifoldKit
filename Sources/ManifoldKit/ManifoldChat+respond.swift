// ManifoldChat+respond.swift
//
// One-shot collect helper over the existing streamed turn path (#1942,
// partial). Adopters who just want "prompt in, string out" — scripts,
// evals, quick experiments — should not have to set `inputText`, await
// `sendMessage()`, and then read back an observation surface. This
// convenience drains a single turn to its terminal assistant text.
//
// This is deliberately the SMALL slice of #1942. The larger `LLM(from:
// template:)` constructor stays deferred under #1942: it needs an async
// factory, a mandatory backend-registrar list (the companion-package split
// means a backend can't be inferred), and the typed-template concept from
// #1944. Ship the collect-helper now; the constructor lands later.

import Foundation
import ManifoldInference

extension QuickStartResult {

    /// Sends `text` as a single user turn and returns the assistant's complete
    /// response text.
    ///
    /// A one-shot convenience over ``ChatViewModel/sendMessage(_:)``: it drives
    /// one turn through the same `ConversationRuntime` path the UI uses,
    /// streaming under the hood, and collects the terminal assistant
    /// ``ChatMessage`` into a plain `String`. Use it for scripted drivers,
    /// evals, and getting-started snippets that want "prompt in, string out"
    /// without touching `inputText` or polling observation surfaces.
    ///
    /// ```swift
    /// let kit = try await ManifoldKit.quickStart()
    /// let answer = try await kit.respond("What is the capital of France?")
    /// print(answer)
    /// ```
    ///
    /// - Parameter text: The user message to send.
    /// - Returns: The accumulated assistant text (all content parts joined).
    /// - Throws: ``SendMessageError`` — `.noActiveSession` / `.noModelLoaded`
    ///   for precondition failures, `.empty` when the turn produces no
    ///   assistant record, or `.runtime(error)` when the underlying runtime
    ///   surfaces an error.
    public func respond(_ text: String) async throws -> String {
        let message = try await viewModel.sendMessage(text)
        return message.content
    }
}
