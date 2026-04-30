import Foundation
import BaseChatInference

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
        lines.append("Exported from \(BaseChatConfiguration.shared.appName): \(formattedDate())")
        lines.append("")

        for message in messages where message.role != .system {
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
        lines.append("*Exported from \(BaseChatConfiguration.shared.appName): \(formattedDate())*")
        lines.append("")
        lines.append("---")
        lines.append("")

        for message in messages where message.role != .system {
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
