import Foundation
import ManifoldInference

/// Errors produced by ``JSONLImportFormat`` when the input is structurally
/// invalid or missing required fields.
///
/// Typed rather than a generic `Error` so callers can distinguish "wrong file
/// format" (and show a targeted message) from "disk I/O failed" or
/// "network unavailable".
public enum JSONLImportError: Error, LocalizedError, Sendable, Equatable {

    /// The input `Data` was empty; there is nothing to decode.
    case emptyData

    /// A line could not be parsed as valid JSON.
    ///
    /// `lineNumber` is 1-based to match editor gutter conventions; useful when
    /// the user opens the file in a text editor to diagnose corruption.
    case malformedJSON(lineNumber: Int, description: String)

    /// A required field is absent from the JSON object on the given line.
    case missingField(lineNumber: Int, field: String)

    /// The input contained no message lines (header only, or header absent).
    ///
    /// A conversation with zero messages is technically valid state in the
    /// persistence layer, but an exported JSONL file with no message lines is
    /// almost certainly corrupt or truncated rather than intentionally empty.
    case noMessages

    public var errorDescription: String? {
        switch self {
        case .emptyData:
            return "The import file is empty."
        case let .malformedJSON(line, desc):
            return "Line \(line) is not valid JSON: \(desc)"
        case let .missingField(line, field):
            return "Line \(line) is missing required field '\(field)'."
        case .noMessages:
            return "The import file contains no messages."
        }
    }
}

/// Built-in ``ConversationImportFormat`` that parses the JSONL output produced
/// by ``JSONLExportFormat``.
///
/// Wire format (one JSON object per line):
///
/// ```jsonl
/// {"id":"<uuid>","sessionID":"<uuid>","title":"Session title","timestamp":"2026-04-27T10:00:00Z"}
/// {"role":"user","content":"Hello","timestamp":"2026-04-27T10:00:00Z"}
/// {"role":"assistant","content":"Hi","timestamp":"2026-04-27T10:00:01Z"}
/// ```
///
/// The first line is an optional session envelope. When present its `id` and
/// `sessionID` fields are used to reconstruct the original UUIDs, making
/// re-import of the same file idempotent (identical IDs → caller can detect
/// duplicates). When the envelope line is absent, fresh UUIDs are generated
/// for the session.
///
/// Message lines carry `role`, `content`, and `timestamp`. Any additional
/// fields are tolerated and ignored so future export extensions don't break
/// older importers.
///
/// > Note: ``JSONLExportFormat`` currently emits only `role`, `content`, and
/// > `timestamp` — no session envelope. ``JSONLImportFormat`` treats a line
/// > that contains neither a `"role"` field nor a `"sessionID"` field as a
/// > session envelope attempt, and falls back gracefully if the JSON has no
/// > known envelope keys. See the roundtrip test for the exact current shape.
public struct JSONLImportFormat: ConversationImportFormat {

    public init() {}

    /// Wire shape of an optional session envelope line.
    ///
    /// All fields are optional so the decoder never silently drops a line that
    /// partially matches — we validate the required fields explicitly below.
    private struct SessionEnvelope: Decodable {
        let id: String?
        let sessionID: String?
        let title: String?
        let timestamp: String?
        let createdAt: String?
    }

    /// Wire shape of a message line.
    ///
    /// `timestamp` is optional here so JSONDecoder does not throw a generic
    /// `keyNotFound` when it is absent — we validate it post-decode and throw
    /// a typed ``JSONLImportError/missingField(_:_:)`` that names the field.
    private struct MessageLine: Decodable {
        let role: String
        let content: String
        let timestamp: String?
        let id: String?
    }

    public func decode(_ data: Data) throws -> ImportedConversation {
        guard !data.isEmpty else {
            Log.persistence.warning("JSONLImportFormat: received empty data")
            throw JSONLImportError.emptyData
        }

        // Use a per-call formatter: ISO8601DateFormatter is not Sendable and
        // storing it as a static would either require locking or @MainActor
        // isolation — re-allocating once per import is cheaper for large files
        // than either alternative, and imports are not hot paths.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        // Fallback for files written by tools that include fractional seconds
        // (e.g. ".123Z"). ISO8601DateFormatter treats the two option sets as
        // mutually exclusive — a second formatter is cheaper than a regex strip.
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        guard let text = String(data: data, encoding: .utf8) else {
            // UTF-8 decode failures are rare but possible for files produced by
            // non-UTF-8 editors; treat as malformed rather than trapping.
            Log.persistence.warning("JSONLImportFormat: data is not valid UTF-8")
            throw JSONLImportError.malformedJSON(lineNumber: 1, description: "Data is not valid UTF-8")
        }

        let rawLines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        // Inspect the first line to decide whether it is a session envelope
        // or a message line. A session envelope must contain at least one of
        // the known envelope keys; message lines always have a "role" field.
        var lineIndex = 0
        var sessionID = UUID()
        var sessionTitle = "Imported Chat"
        var sessionCreatedAt = Date()
        var sessionUpdatedAt = Date()

        if let firstLine = rawLines.first {
            if let lineData = firstLine.data(using: .utf8),
               let firstObject = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               // Discriminate envelope from message: message lines always have
               // both "role" and "content". If both are absent and a title-like
               // key is present it's a session envelope, not a message.
               (firstObject["sessionID"] != nil ||
                (firstObject["role"] == nil && firstObject["content"] == nil && firstObject["title"] != nil)) {
                // This looks like a session envelope — parse it and advance past it.
                lineIndex = 1

                if let rawID = firstObject["id"] as? String, let parsed = UUID(uuidString: rawID) {
                    sessionID = parsed
                }
                if let title = firstObject["title"] as? String {
                    sessionTitle = title
                }
                // Accept either "createdAt" or "timestamp" as the session creation date.
                let dateString = firstObject["createdAt"] as? String ?? firstObject["timestamp"] as? String
                if let dateString,
                   let date = iso.date(from: dateString) ?? isoFractional.date(from: dateString) {
                    sessionCreatedAt = date
                    sessionUpdatedAt = date
                }
            }
            // If the first line is a message line (has "role"), we leave lineIndex at 0
            // and use freshly-generated session UUIDs — the export predates the envelope.
        }

        let messageLines = Array(rawLines.dropFirst(lineIndex))

        guard !messageLines.isEmpty else {
            Log.persistence.warning("JSONLImportFormat: import file contains no message lines")
            throw JSONLImportError.noMessages
        }

        var messages: [ChatMessage] = []
        messages.reserveCapacity(messageLines.count)

        let decoder = JSONDecoder()

        for (offset, rawLine) in messageLines.enumerated() {
            let lineNumber = offset + lineIndex + 1 // 1-based, relative to full file

            guard let lineData = rawLine.data(using: .utf8) else {
                Log.persistence.warning("JSONLImportFormat: line \(lineNumber) could not be re-encoded to UTF-8")
                throw JSONLImportError.malformedJSON(lineNumber: lineNumber, description: "Line could not be re-encoded to UTF-8")
            }

            let messageLine: MessageLine
            do {
                messageLine = try decoder.decode(MessageLine.self, from: lineData)
            } catch {
                Log.persistence.warning("JSONLImportFormat: line \(lineNumber) is not a valid message JSON — \(error.localizedDescription)")
                throw JSONLImportError.malformedJSON(lineNumber: lineNumber, description: error.localizedDescription)
            }

            // role and content are guaranteed non-nil by the Decodable shape;
            // validate role is a known value so we never persist garbage.
            guard let role = MessageRole(rawValue: messageLine.role) else {
                Log.persistence.warning("JSONLImportFormat: line \(lineNumber) has unknown role '\(messageLine.role, privacy: .public)'")
                throw JSONLImportError.missingField(lineNumber: lineNumber, field: "role (unknown value: \(messageLine.role))")
            }

            // Timestamp is required — a message without a timestamp cannot be
            // correctly ordered in the conversation timeline. Check for absence
            // before parsing so we emit a typed missingField rather than a
            // generic parse failure.
            guard let rawTimestamp = messageLine.timestamp else {
                Log.persistence.warning("JSONLImportFormat: line \(lineNumber) is missing required 'timestamp' field")
                throw JSONLImportError.missingField(lineNumber: lineNumber, field: "timestamp")
            }
            guard let timestamp = iso.date(from: rawTimestamp) ?? isoFractional.date(from: rawTimestamp) else {
                Log.persistence.warning("JSONLImportFormat: line \(lineNumber) has unparseable timestamp '\(rawTimestamp, privacy: .public)'")
                throw JSONLImportError.missingField(lineNumber: lineNumber, field: "timestamp")
            }

            // Preserve the exported message UUID when present so the same
            // export can be re-imported and deduplicated by the session store.
            let messageID: UUID
            if let rawID = messageLine.id, let parsed = UUID(uuidString: rawID) {
                messageID = parsed
            } else {
                messageID = UUID()
            }

            let record = ChatMessage(
                id: messageID,
                role: role,
                content: messageLine.content,
                timestamp: timestamp,
                sessionID: sessionID
            )
            messages.append(record)
        }

        let session = ChatSession(
            id: sessionID,
            title: sessionTitle,
            createdAt: sessionCreatedAt,
            updatedAt: sessionUpdatedAt
        )

        return ImportedConversation(session: session, messages: messages)
    }
}
