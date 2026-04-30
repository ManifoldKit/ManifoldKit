import Foundation
import UniformTypeIdentifiers
import BaseChatInference

/// Built-in ``ConversationExportFormat`` that emits one JSON object per line.
///
/// Each line is a self-contained JSON record with `role`, `content`, and
/// `timestamp` (ISO-8601). System messages are included so JSONL output can
/// round-trip into training-data pipelines that expect them.
///
/// ```jsonl
/// {"role":"user","content":"Hello","timestamp":"2026-04-27T10:00:00Z"}
/// {"role":"assistant","content":"Hi","timestamp":"2026-04-27T10:00:01Z"}
/// ```
///
/// The trailing newline after the last record is intentional — most JSONL
/// readers treat a missing final newline as a truncated stream.
public struct JSONLExportFormat: ConversationExportFormat {

    public init() {}

    public var fileExtension: String { "jsonl" }

    // No system UTType for JSONL; .json is the closest semantic fit and
    // keeps the share sheet from offering binary-only handlers.
    public var contentType: UTType { .json }

    /// Wire shape — keep tiny, stable, and Codable so apps can decode their
    /// own exports without depending on internal record types.
    private struct Line: Encodable {
        let role: String
        let content: String
        let timestamp: String
    }

    public func export(session _: ChatSessionRecord, messages: [ChatMessageRecord]) throws -> Data {
        let encoder = JSONEncoder()
        // .sortedKeys for deterministic output — round-trip tests and
        // diff-based snapshotting both rely on this.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        // Per-call formatter: ISO8601DateFormatter isn't Sendable, and the
        // alternative (a global lock or static @MainActor) costs more than
        // re-allocating it once per export.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var data = Data()
        // `ChatMessageRecord.content` only joins `.text` parts — thinking-only
        // and tool-call-only messages would otherwise serialise as
        // `"content":""`, which is misleading for downstream JSONL consumers
        // (training pipelines especially). Skip them; expanding the wire
        // shape to encode non-text parts is a follow-up.
        for message in messages where message.hasVisibleContent {
            let line = Line(
                role: message.role.rawValue,
                content: message.content,
                timestamp: iso.string(from: message.timestamp)
            )
            let encoded = try encoder.encode(line)
            data.append(encoded)
            data.append(0x0A) // newline
        }
        return data
    }
}
