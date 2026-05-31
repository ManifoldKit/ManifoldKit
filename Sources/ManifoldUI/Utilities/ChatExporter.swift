import Foundation
import ManifoldInference
import ManifoldRuntime

/// Converts chat session data to exportable formats.
///
/// `ChatExporter` is a lightweight, provider-agnostic utility that serialises a
/// list of ``ChatMessageRecord`` values into a string or a temporary file URL
/// ready for use with SwiftUI's `ShareLink`.
///
/// ```swift
/// let url = try ChatExporter.exportFile(
///     title: session.title,
///     messages: viewModel.messages
/// )
/// // present ShareLink(item: url)
/// ```
///
/// For richer export needs — custom formats, `SharePreview` metadata, or
/// automatic share-sheet presentation — prefer ``ExportButton`` or call
/// ``ConversationExporter`` directly.
public enum ChatExporter {

    // MARK: - Public API

    /// Returns the chat as a formatted string.
    ///
    /// - Parameters:
    ///   - title: The session title used as the document heading.
    ///   - messages: Messages in chronological order.
    ///   - format: Serialisation format. Defaults to ``ExportFormat/markdown``.
    /// - Returns: The formatted string.
    public static func string(
        title: String,
        messages: [ChatMessageRecord],
        format: ExportFormat = .markdown
    ) -> String {
        ChatExportService.export(
            messages: messages,
            sessionTitle: title,
            format: format
        )
    }

    /// Serialises the chat to a temporary file and returns its URL.
    ///
    /// The file is written into a unique subdirectory of the system temporary
    /// directory so repeated calls for the same session title don't overwrite
    /// each other before the share sheet finishes. The caller owns cleanup.
    ///
    /// - Parameters:
    ///   - title: The session title. Used as the filename stem (sanitised).
    ///   - messages: Messages in chronological order.
    ///   - format: Serialisation format. Defaults to ``ExportFormat/markdown``.
    /// - Returns: A file URL inside the temporary directory.
    /// - Throws: ``ChatExporterError/writeFailed(_:_:)`` when the filesystem
    ///   write fails.
    public static func exportFile(
        title: String,
        messages: [ChatMessageRecord],
        format: ExportFormat = .markdown
    ) throws -> URL {
        let content = string(title: title, messages: messages, format: format)
        let safeName = sanitisedStem(title)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManifoldKit-chat-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(safeName).\(format.fileExtension)")
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ChatExporterError.writeFailed(url, error.localizedDescription)
        }
        return url
    }

    // MARK: - Private helpers

    /// Produces a filesystem-safe stem from an arbitrary session title.
    ///
    /// Characters that break path components on APFS or HFS+ are replaced with
    /// hyphens; the result is lower-cased and capped at 200 UTF-8 bytes for
    /// share-sheet readability. Falls back to `"chat"` when the title is empty
    /// or reduces to nothing after filtering.
    private static func sanitisedStem(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "chat" }

        let banned: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\n", "\r", "\t"]
        let cleaned = trimmed.lowercased().unicodeScalars.map { scalar -> Character in
            let ch = Character(scalar)
            if banned.contains(ch) { return "-" }
            if scalar.value < 0x20 { return "-" }
            if ch == " " { return "-" }
            return ch
        }

        var stem = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if stem.isEmpty { stem = "chat" }

        // Cap at 200 UTF-8 bytes to stay well within APFS's 255-byte limit.
        if stem.utf8.count > 200 {
            var bytes = 0
            var out = ""
            for ch in stem {
                let n = ch.utf8.count
                if bytes + n > 200 { break }
                out.append(ch)
                bytes += n
            }
            stem = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if stem.isEmpty { stem = "chat" }
        }

        return stem
    }
}

// MARK: - Errors

/// Errors thrown by ``ChatExporter``.
public enum ChatExporterError: Error, Equatable {
    /// The serialised content could not be written to `url`.
    case writeFailed(URL, String)
}
