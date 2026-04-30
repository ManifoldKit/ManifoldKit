import Foundation
import UniformTypeIdentifiers
import BaseChatInference

/// Built-in ``ConversationExportFormat`` that renders a session as a Markdown
/// document with a metadata header and one block per visible message.
///
/// Output shape:
/// ```markdown
/// # <session title>
///
/// *Exported: 2026-04-27T10:00:00Z*
/// *Session created: 2026-04-26T09:30:00Z*
///
/// ---
///
/// **User:**
///
/// Hello
///
/// **Assistant:**
///
/// Hi there
/// ```
///
/// System messages are omitted to match the share-sheet expectation (users
/// rarely want to leak system prompts when forwarding a conversation). Apps
/// that need them should ship a custom ``ConversationExportFormat``.
public struct MarkdownExportFormat: ConversationExportFormat {

    public init() {}

    public var fileExtension: String { "md" }

    // .plainText is the closest stable UTType — UTType.markdown only exists
    // from macOS 26 / iOS 18, but we still target macOS 15 / iOS 18 (n-1).
    // When macOS 27 lands and the floor moves, swap to `.markdown`.
    public var contentType: UTType { .plainText }

    public func export(session: ChatSessionRecord, messages: [ChatMessageRecord]) throws -> Data {
        // Build a fresh formatter per call — ISO8601DateFormatter isn't Sendable,
        // and the cost is negligible compared to the I/O the result drives.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var lines: [String] = []
        lines.append("# \(session.title)")
        lines.append("")
        lines.append("*Exported: \(iso.string(from: Date()))*")
        lines.append("*Session created: \(iso.string(from: session.createdAt))*")
        lines.append("")
        lines.append("---")
        lines.append("")

        // Skip system prompts (privacy) and messages whose only parts are
        // `.thinking` / `.toolCall` / non-text — `ChatMessageRecord.content`
        // joins text parts only, so without the `hasVisibleContent` filter
        // a thinking-only assistant turn would render as an empty
        // `**Assistant:**` block.
        for message in messages where message.role != .system && message.hasVisibleContent {
            let role = message.role == .user ? "User" : "Assistant"
            lines.append("**\(role):**")
            lines.append("")
            lines.append(message.content)
            lines.append("")
        }

        let joined = lines.joined(separator: "\n")
        // String.data(using:) only returns nil for lossy conversions to a
        // non-Unicode encoding — UTF-8 is total. Force-unwrap is safe.
        return joined.data(using: .utf8)!
    }
}
