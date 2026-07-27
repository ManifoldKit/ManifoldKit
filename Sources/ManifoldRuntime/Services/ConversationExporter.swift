import Foundation
import UniformTypeIdentifiers
import ManifoldInference

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

    /// The directory ``ConversationExporter`` created to hold `url`, or `nil`
    /// when the caller passed their own `directory:` override.
    ///
    /// This is what makes ownership representable instead of living only in
    /// a comment: only a directory the exporter itself minted is safe for
    /// ``cleanup()`` to remove recursively. A caller-supplied directory may
    /// hold other files the caller still needs, so recursively deleting it
    /// would be a caller bug the exporter must not commit on their behalf.
    public let ownedDirectory: URL?

    public init(
        url: URL,
        suggestedFilename: String,
        contentType: UTType,
        ownedDirectory: URL? = nil
    ) {
        self.url = url
        self.suggestedFilename = suggestedFilename
        self.contentType = contentType
        self.ownedDirectory = ownedDirectory
    }

    /// Old-signature overload kept explicitly: a defaulted-parameter
    /// addition to an `init` still reads as "constructor removed" to the
    /// api-digester surface diff (it keys on the full parameter list, not
    /// just source-call compatibility), so the pre-`ownedDirectory` shape
    /// is preserved here rather than relying on the default alone.
    public init(url: URL, suggestedFilename: String, contentType: UTType) {
        self.init(url: url, suggestedFilename: suggestedFilename, contentType: contentType, ownedDirectory: nil)
    }

    /// Removes what the exporter actually created: the whole temp directory
    /// when ``ConversationExporter`` minted one for this export, or just the
    /// file when the caller supplied `directory:` and therefore owns that
    /// directory's lifecycle.
    ///
    /// Best-effort in the sense that a missing target isn't treated as
    /// caller error, but a real failure is logged, never swallowed silently
    /// (AGENTS.md Principle 6 — no `try?` in production paths).
    public func cleanup() {
        let target = ownedDirectory ?? url
        do {
            try FileManager.default.removeItem(at: target)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already gone (e.g. double cleanup, or the share sheet moved
            // it) — not worth logging.
        } catch {
            Log.persistence.error(
                "ShareableFile.cleanup failed for \(target.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
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
/// Files are written to a unique subdirectory of the system temporary
/// directory by default; pass `directory:` to override (e.g. for tests or
/// when targeting a sandboxed app group). The caller owns cleanup.
public enum ConversationExporter {

    /// Serialises `messages` via `format` and writes the result to disk.
    public static func export(
        session: ChatSession,
        messages: [ChatMessage],
        format: ConversationExportFormat,
        directory: URL? = nil
    ) throws -> ShareableFile {
        let data = try format.export(session: session, messages: messages)
        let filename = sanitisedFilename(for: session, fileExtension: format.fileExtension)

        let (dir, ownedDirectory) = try resolveDirectory(directory)
        let fileURL = dir.appendingPathComponent(filename, isDirectory: false)

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw ConversationExportError.writeFailed(fileURL, error.localizedDescription)
        }

        return ShareableFile(
            url: fileURL,
            suggestedFilename: filename,
            contentType: format.contentType,
            ownedDirectory: ownedDirectory
        )
    }

    /// Strips characters that don't survive `FileManager` round-trips on any
    /// supported platform. Falls back to "chat" when the title is entirely
    /// whitespace or filtered out. The `fileExtension` is sanitised
    /// independently — custom ``ConversationExportFormat`` adopters can return
    /// arbitrary strings, so we never trust the value verbatim in a path
    /// component.
    static func sanitisedFilename(for session: ChatSession, fileExtension: String) -> String {
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

    /// Returns the directory to write into, plus that same URL again as the
    /// second element only when *this call* created it — the ownership
    /// signal ``ShareableFile.ownedDirectory`` carries forward. A
    /// caller-supplied `override` is never reported as owned, even though we
    /// `createDirectory` it here too: the caller asked for that specific
    /// location, so its lifecycle is theirs, not ours to delete later.
    private static func resolveDirectory(_ override: URL?) throws -> (directory: URL, ownedDirectory: URL?) {
        if let override {
            try FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
            return (override, nil)
        }
        // Each export gets its own temp subdir so two exports of the same
        // session don't clobber each other before the share sheet finishes.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManifoldKit-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir)
    }
}
