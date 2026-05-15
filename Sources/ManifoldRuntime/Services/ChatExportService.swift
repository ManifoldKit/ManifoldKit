import Foundation
import ManifoldInference

/// Format options for chat export.
public enum ExportFormat: String, CaseIterable, Identifiable {
    case plainText = "Plain Text"
    case markdown = "Markdown"

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .plainText: "txt"
        case .markdown: "md"
        }
    }
}

/// Exports chat messages to plain text or markdown format.
public enum ChatExportService {

    /// Exports messages in the specified format.
    public static func export(
        messages: [ChatMessageRecord],
        sessionTitle: String,
        format: ExportFormat
    ) -> String {
        switch format {
        case .plainText:
            return exportPlainText(messages: messages, title: sessionTitle)
        case .markdown:
            return exportMarkdown(messages: messages, title: sessionTitle)
        }
    }

    // MARK: - Plain Text

    private static func exportPlainText(messages: [ChatMessageRecord], title: String) -> String {
        var lines: [String] = []
        lines.append("Chat: \(title)")
        lines.append("Exported from \(ManifoldConfiguration.shared.appName): \(formattedDate())")
        lines.append("")

        // isUserVisible covers the kind axis; the role guard preserves the pre-V7
        // behaviour for .chat-kind system-role records that haven't been migrated
        // to kind: .memory(...) yet. New callers should use kind: .memory for
        // all system-prompt-like records.
        for message in messages where message.kind.isUserVisible && message.role != .system {
            let role = message.role == .user ? "User" : "Assistant"
            lines.append("\(role): \(message.content)")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Markdown

    private static func exportMarkdown(messages: [ChatMessageRecord], title: String) -> String {
        var lines: [String] = []
        lines.append("# \(title)")
        lines.append("")
        lines.append("*Exported from \(ManifoldConfiguration.shared.appName): \(formattedDate())*")
        lines.append("")
        lines.append("---")
        lines.append("")

        for message in messages where message.kind.isUserVisible && message.role != .system {
            let role = message.role == .user ? "User" : "Assistant"
            lines.append("**\(role):**")
            lines.append("")
            lines.append(message.content)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: Date())
    }
}
