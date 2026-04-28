import Foundation
import UniformTypeIdentifiers
import BaseChatInference

/// A reference to a file written to disk that is suitable for sharing via
/// SwiftUI's `ShareLink`.
///
/// `ShareLink` accepts `URL`, but a bare URL hides the suggested filename and
/// content type from the share sheet's preview. Bundling them keeps the
/// preview helpful and lets callers clean up the temp file when sharing
/// completes.
public struct ShareableFile: Sendable, Equatable {

    /// On-disk location of the file. Typically inside `FileManager.default.temporaryDirectory`.
    public let url: URL

    /// Display name shown in the share sheet preview, including extension.
    public let suggestedFilename: String

    /// UTI used by the share sheet to pick handlers and icons.
    public let contentType: UTType

    public init(url: URL, suggestedFilename: String, contentType: UTType) {
        self.url = url
        self.suggestedFilename = suggestedFilename
        self.contentType = contentType
    }
}

/// Errors surfaced by ``ConversationExporter`` when the export pipeline
/// trips at a system boundary (filesystem, persistence).
public enum ConversationExportError: Error, Equatable {
    case writeFailed(URL, String)
}

/// Exports a chat session through any ``ConversationExportFormat`` and
/// returns a ``ShareableFile`` suitable for `ShareLink`.
///
/// Two ways to drive it:
/// - ``export(session:messages:format:directory:)`` — caller already has the
///   message list. Pure: no persistence dependency.
/// - ``export(session:format:provider:directory:)`` — the exporter fetches
///   the linear active path from a ``SwiftDataPersistenceProvider``. Use this
///   when you have a SwiftData ``ChatSession`` in hand.
///
/// Files are written to a unique subdirectory of the system temporary
/// directory by default; pass `directory:` to override (e.g. for tests or
/// when targeting a sandboxed app group). The caller owns cleanup.
public enum ConversationExporter {

    // MARK: - Pure path (no persistence dependency)

    /// Serialises `messages` via `format` and writes the result to disk.
    public static func export(
        session: ChatSessionRecord,
        messages: [ChatMessageRecord],
        format: ConversationExportFormat,
        directory: URL? = nil
    ) throws -> ShareableFile {
        let data = try format.export(session: session, messages: messages)
        let filename = sanitisedFilename(for: session, fileExtension: format.fileExtension)

        let dir = try resolveDirectory(directory)
        let fileURL = dir.appendingPathComponent(filename, isDirectory: false)

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw ConversationExportError.writeFailed(fileURL, error.localizedDescription)
        }

        return ShareableFile(
            url: fileURL,
            suggestedFilename: filename,
            contentType: format.contentType
        )
    }

    // MARK: - SwiftData convenience

    /// Loads the session's messages via `provider`, then writes the export.
    ///
    /// Uses the SwiftData ``ChatSession`` directly — `provider.fetchMessages`
    /// returns the linear chronological history. Apps modelling branches
    /// should call ``export(session:messages:format:directory:)`` with the
    /// active path they have already materialised.
    ///
    /// `@MainActor` because ``ChatPersistenceProvider`` is `@MainActor`-isolated.
    @MainActor
    public static func export(
        session: ChatSession,
        format: ConversationExportFormat,
        provider: ChatPersistenceProvider,
        directory: URL? = nil
    ) async throws -> ShareableFile {
        let messages = try await provider.fetchMessages(for: session.id)
        return try export(
            session: session.record,
            messages: messages,
            format: format,
            directory: directory
        )
    }

    // MARK: - Helpers

    /// Strips characters that don't survive `FileManager` round-trips on any
    /// supported platform. Falls back to "chat" when the title is entirely
    /// whitespace or filtered out. The `fileExtension` is sanitised
    /// independently — custom ``ConversationExportFormat`` adopters can return
    /// arbitrary strings, so we never trust the value verbatim in a path
    /// component.
    static func sanitisedFilename(for session: ChatSessionRecord, fileExtension: String) -> String {
        let stem = sanitiseStem(session.title)
        let ext = sanitiseFileExtension(fileExtension)
        return "\(stem).\(ext)"
    }

    /// Maximum stem length, measured in UTF-8 bytes. APFS allows 255 bytes per
    /// path component; we leave headroom for the dot + extension and to keep
    /// share-sheet previews readable. A scalar-by-scalar prefix below ensures
    /// emoji and CJK characters never split mid-sequence.
    private static let stemUTF8ByteLimit = 200

    static func sanitiseStem(_ raw: String) -> String {
        // Trim first so whitespace-only input (including \n/\t which would
        // otherwise be replaced with _) falls back to "chat" cleanly.
        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRaw.isEmpty {
            return "chat"
        }

        // Slashes break path components; control characters break some
        // share-sheet previews; colons break HFS+. Replace everything in
        // one pass rather than chaining `replacingOccurrences`.
        let banned: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\n", "\r", "\t"]
        let cleaned = trimmedRaw.unicodeScalars
            .map { scalar -> Character in
                let ch = Character(scalar)
                if banned.contains(ch) { return "_" }
                if scalar.value < 0x20 { return "_" }
                return ch
            }
        var stem = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)

        if stem.isEmpty {
            stem = "chat"
        }

        // Cap by UTF-8 byte length, not grapheme count — an 80-emoji title is
        // 320+ bytes and would blow past APFS's 255-byte path-component limit.
        // Truncate Character-wise so we never split a multi-byte scalar.
        stem = truncateToUTF8Bytes(stem, limit: stemUTF8ByteLimit)
        return stem
    }

    /// Restricts the extension to a conservative ASCII alphanumeric set so a
    /// custom ``ConversationExportFormat`` can't slip `..`, a leading `.`, or
    /// a path separator into the filename. Falls back to `"txt"` when the
    /// caller's extension is empty or entirely outside the allowed set.
    static func sanitiseFileExtension(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = trimmed.unicodeScalars.filter { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39) || // 0-9
                (scalar.value >= 0x41 && scalar.value <= 0x5A) || // A-Z
                (scalar.value >= 0x61 && scalar.value <= 0x7A) // a-z
        }
        if allowed.isEmpty { return "txt" }
        // Cap at 10 chars — `jsonl` is the longest built-in; leaving generous
        // headroom for hypothetical custom formats without inviting abuse.
        let capped = String(String.UnicodeScalarView(allowed.prefix(10)))
        return capped
    }

    private static func truncateToUTF8Bytes(_ input: String, limit: Int) -> String {
        if input.utf8.count <= limit { return input }
        var out = ""
        out.reserveCapacity(limit)
        var bytes = 0
        for character in input {
            let charBytes = character.utf8.count
            if bytes + charBytes > limit { break }
            out.append(character)
            bytes += charBytes
        }
        // Trim trailing whitespace introduced by truncation.
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolveDirectory(_ override: URL?) throws -> URL {
        if let override {
            try FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
            return override
        }
        // Each export gets its own temp subdir so two exports of the same
        // session don't clobber each other before the share sheet finishes.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BaseChatKit-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
