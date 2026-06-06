import Foundation

// MARK: - DialogueSummariser

/// Summarises a window of user-visible dialogue turns into a single string.
///
/// Distinct from ``TurnHistoryCompressor``, which summarises *internal*
/// agent-loop scratch (tool calls and results). `DialogueSummariser`
/// summarises the *user-visible* conversation — user and assistant messages —
/// so that long sessions remain usable on small-context local backends.
///
/// The default in-tree implementation is ``DefaultDialogueSummariser``. A
/// ``NoOpDialogueSummariser`` is provided as a sentinel for cases where the
/// host wants to satisfy a parameter type without performing any summarisation.
///
/// Implementations must be `Sendable` so that the runtime can hold one across
/// async boundaries inside detached tasks.
public protocol DialogueSummariser: Sendable {

    /// Summarises `turns` into a single string using the supplied backend.
    ///
    /// - Parameters:
    ///   - turns: The non-pinned dialogue turns to summarise, in chronological
    ///     order. Callers guarantee that this array is non-empty and that no
    ///     entry has `kind != .chat` (the runtime strips non-chat records before
    ///     passing them in, so only user/assistant `.chat` turns reach the
    ///     summariser).
    ///   - backend: The inference backend to use. The summariser calls
    ///     `backend.generate(prompt:systemPrompt:config:)` directly; it does
    ///     not go through the host's `InferenceService` so that the host's
    ///     in-flight generation state is not disturbed.
    /// - Returns: A summary string suitable for storing as a `.memory("summary")`
    ///   record in the session history.
    /// - Throws: Any error from the underlying backend.
    func summarise(turns: [ChatMessage], using backend: any InferenceBackend) async throws -> String
}

// MARK: - DefaultDialogueSummariser

/// Default ``DialogueSummariser`` implementation.
///
/// Builds a prompt from the supplied turns, asks the backend for a concise
/// summary, and returns the model's full accumulated text output.
///
/// The prompt format is plain text:
/// ```
/// Summarise the following conversation as a concise paragraph (100–200 words).
/// Do not add commentary or refer to yourself. Preserve any key facts, decisions,
/// or action items. Output the summary only.
///
/// User: …
/// Assistant: …
/// User: …
/// ```
///
/// The system prompt is omitted — the backend's loaded model picks up the
/// instruction from the user turn alone, which is sufficient for every backend
/// family (Llama, MLX, Foundation, Cloud).
public struct DefaultDialogueSummariser: DialogueSummariser {

    /// Maximum number of tokens the backend may generate for the summary.
    /// Defaults to 512 — enough for a few paragraphs while staying well inside
    /// even a 2k-token context window. Hosts that want a shorter or longer
    /// summary can supply a different value.
    public let maxSummaryTokens: Int

    public init(maxSummaryTokens: Int = 512) {
        self.maxSummaryTokens = max(64, maxSummaryTokens)
    }

    public func summarise(turns: [ChatMessage], using backend: any InferenceBackend) async throws -> String {
        let conversationBlock = turns
            .filter { $0.kind.isUserVisible }
            .map { record -> String in
                let roleLabel: String
                switch record.role {
                case .user:      roleLabel = "User"
                case .assistant: roleLabel = "Assistant"
                case .system:    roleLabel = "System"
                }
                return "\(roleLabel): \(record.content)"
            }
            .joined(separator: "\n")

        let prompt = """
        Summarise the following conversation as a concise paragraph (100–200 words). \
        Do not add commentary or refer to yourself. Preserve any key facts, decisions, \
        or action items. Output the summary only.

        \(conversationBlock)
        """

        let config = GenerationConfig(
            temperature: 0.3,
            maxOutputTokens: maxSummaryTokens
        )

        let stream = try backend.generate(prompt: prompt, systemPrompt: nil, config: config)

        var result = ""
        var consumer = GenerationStreamConsumer(loopDetectionEnabled: false)

        for try await event in stream.events {
            if case .appendText(let chunk) = consumer.handle(event) {
                result += chunk
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - NoOpDialogueSummariser

/// A sentinel summariser that always returns an empty string.
///
/// Useful as a compile-time stand-in or for disabling summarisation in a
/// context where the type system requires a concrete `DialogueSummariser`.
public struct NoOpDialogueSummariser: DialogueSummariser {
    public init() {}

    public func summarise(turns: [ChatMessage], using backend: any InferenceBackend) async throws -> String {
        ""
    }
}
