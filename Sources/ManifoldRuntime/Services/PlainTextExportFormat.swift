import Foundation
import UniformTypeIdentifiers
import ManifoldInference

/// Built-in ``ConversationExportFormat`` that renders a session as an
/// unformatted plain-text transcript with a metadata header and one block
/// per visible message.
///
/// Output shape:
/// ```text
/// My Chat
///
/// Exported: 2026-04-27T10:00:00Z
/// Session created: 2026-04-26T09:30:00Z
///
/// ---
///
/// User:
///
/// Hello
///
/// Assistant:
///
/// Hi there
/// ```
///
/// System messages are omitted to match the share-sheet expectation (users
/// rarely want to leak system prompts when forwarding a conversation). Apps
/// that need them should ship a custom ``ConversationExportFormat``.
public struct PlainTextExportFormat: ConversationExportFormat {

    public init() {}

    public var fileExtension: String { "txt" }

    public var contentType: UTType { .plainText }

    public func export(session: ChatSession, messages: [ChatMessage]) throws -> Data {
        // Build a fresh formatter per call — ISO8601DateFormatter isn't Sendable,
        // and the cost is negligible compared to the I/O the result drives.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var lines: [String] = []
        lines.append(session.title)
        lines.append("")
        lines.append("Exported: \(iso.string(from: Date()))")
        lines.append("Session created: \(iso.string(from: session.createdAt))")
        lines.append("")
        lines.append("---")
        lines.append("")

        // Skip non-user-visible kinds (memory, annotation, toolResult, custom) and
        // messages whose only parts are `.thinking` / `.toolCall` / non-text.
        // The role guard preserves pre-V7 behaviour for .chat-kind system records;
        // new code should tag system-prompt-like records with kind: .memory.
        for message in messages where message.kind.isUserVisible && message.role != .system && message.hasVisibleContent {
            let role = message.role == .user ? "User" : "Assistant"
            lines.append("\(role):")
            lines.append("")
            lines.append(message.content)
            lines.append("")
        }

        let joined = lines.joined(separator: "\n")
        // Data(String.utf8) never fails — UTF-8 is a total encoding for Swift
        // String — so this sidesteps `.data(using:)!`'s force-unwrap entirely.
        return Data(joined.utf8)
    }
}
