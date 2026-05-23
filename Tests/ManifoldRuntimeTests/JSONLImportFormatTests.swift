import XCTest
@testable import ManifoldRuntime
import ManifoldInference

/// Unit tests for ``JSONLImportFormat``.
///
/// These tests are pure in-memory — no SwiftData, no disk I/O — which keeps
/// them fast and easy to run in any environment. Persistence-layer behaviour
/// is covered by ``ConversationImporterIntegrationTests``.
final class JSONLImportFormatTests: XCTestCase {

    private let sessionID = UUID()
    private let format = JSONLImportFormat()
    private let exporter = JSONLExportFormat()

    // MARK: - Helpers

    /// Builds a ChatSessionRecord with deterministic IDs and timestamps for
    /// comparison across encode/decode.
    private func makeSession(id: UUID? = nil) -> ChatSessionRecord {
        ChatSessionRecord(
            id: id ?? sessionID,
            title: "Test Session",
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            updatedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

    private func makeMessage(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        offset: TimeInterval = 0
    ) -> ChatMessageRecord {
        ChatMessageRecord(
            id: id,
            role: role,
            content: content,
            timestamp: Date(timeIntervalSinceReferenceDate: 0).addingTimeInterval(offset),
            sessionID: sessionID
        )
    }

    /// Builds a minimal JSONL blob directly — useful for testing error paths
    /// without going through the real exporter.
    private func jsonlData(_ lines: String...) -> Data {
        (lines.joined(separator: "\n") + "\n").data(using: .utf8)!
    }

    // MARK: - Roundtrip

    func test_roundtrip_preservesRoleAndContent() throws {
        let messages = [
            makeMessage(role: .user, content: "Hello"),
            makeMessage(role: .assistant, content: "World", offset: 1),
        ]
        let exported = try exporter.export(session: makeSession(), messages: messages)
        let imported = try format.decode(exported)

        XCTAssertEqual(imported.messages.count, 2)
        XCTAssertEqual(imported.messages[0].role, .user)
        XCTAssertEqual(imported.messages[0].content, "Hello")
        XCTAssertEqual(imported.messages[1].role, .assistant)
        XCTAssertEqual(imported.messages[1].content, "World")
    }

    func test_roundtrip_preservesTimestamp() throws {
        let knownDate = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let msg = ChatMessageRecord(
            role: .user,
            content: "timed",
            timestamp: knownDate,
            sessionID: sessionID
        )
        let exported = try exporter.export(session: makeSession(), messages: [msg])
        let imported = try format.decode(exported)

        // ISO-8601 round-trips to second precision; strip sub-second component.
        let epsilon = 1.0
        XCTAssertEqual(
            imported.messages[0].timestamp.timeIntervalSince1970,
            knownDate.timeIntervalSince1970,
            accuracy: epsilon,
            "Timestamp must survive the ISO-8601 round-trip within 1 second"
        )
    }

    func test_roundtrip_preservesMessageOrder() throws {
        let messages = (0..<5).map { i in
            makeMessage(role: i.isMultiple(of: 2) ? .user : .assistant,
                        content: "message \(i)",
                        offset: TimeInterval(i))
        }
        let exported = try exporter.export(session: makeSession(), messages: messages)
        let imported = try format.decode(exported)

        XCTAssertEqual(imported.messages.count, 5)
        for (i, msg) in imported.messages.enumerated() {
            XCTAssertEqual(msg.content, "message \(i)",
                           "Message at index \(i) must match original")
        }
    }

    func test_roundtrip_handlesUnicodeContent() throws {
        let payload = "café 漢字 🦊 \"quoted\" \\backslash newline\nin-content"
        let msg = makeMessage(role: .user, content: payload)
        let exported = try exporter.export(session: makeSession(), messages: [msg])
        let imported = try format.decode(exported)

        XCTAssertEqual(imported.messages[0].content, payload,
                       "Unicode content must survive the JSONL round-trip unchanged")
    }

    func test_roundtrip_allRoles() throws {
        let messages = [
            makeMessage(role: .system, content: "sys"),
            makeMessage(role: .user, content: "usr", offset: 1),
            makeMessage(role: .assistant, content: "ast", offset: 2),
        ]
        let exported = try exporter.export(session: makeSession(), messages: messages)
        let imported = try format.decode(exported)

        XCTAssertEqual(imported.messages.count, 3)
        XCTAssertEqual(imported.messages[0].role, .system)
        XCTAssertEqual(imported.messages[1].role, .user)
        XCTAssertEqual(imported.messages[2].role, .assistant)
    }

    // MARK: - UUID preservation

    func test_uuidPreservation_messageIDSurvivesRoundTrip() throws {
        // When the JSONL line carries an "id" field, re-import must restore it
        // so the caller can detect duplicates by comparing UUIDs rather than
        // content hashing.
        let knownID = UUID()
        let line = #"{"id":"\#(knownID.uuidString)","role":"user","content":"hi","timestamp":"2026-01-01T00:00:00Z"}"#
        let imported = try format.decode(line.data(using: .utf8)!)

        XCTAssertEqual(imported.messages[0].id, knownID,
                       "Message UUID in the JSONL line must be preserved on import")
    }

    func test_uuidPreservation_freshUUIDGeneratedWhenIDAbsent() throws {
        // A line without an "id" field (produced by the current exporter)
        // must receive a fresh UUID — not a zero or colliding one.
        let line = #"{"role":"user","content":"no id","timestamp":"2026-01-01T00:00:00Z"}"#
        let import1 = try format.decode(line.data(using: .utf8)!)
        let import2 = try format.decode(line.data(using: .utf8)!)

        // Two independent imports of the same line must produce different UUIDs.
        XCTAssertNotEqual(import1.messages[0].id, import2.messages[0].id,
                          "Each import of an id-less line must produce a fresh UUID")
    }

    func test_uuidPreservation_sessionIDPreservedFromEnvelope() throws {
        let knownSessionID = UUID()
        let envelope = #"{"id":"\#(knownSessionID.uuidString)","title":"Preserved","timestamp":"2026-01-01T00:00:00Z"}"#
        let message = #"{"role":"user","content":"hello","timestamp":"2026-01-01T00:00:01Z"}"#
        let data = "\(envelope)\n\(message)\n".data(using: .utf8)!
        let imported = try format.decode(data)

        XCTAssertEqual(imported.session.id, knownSessionID,
                       "Session UUID in the envelope must be preserved on import")
        XCTAssertEqual(imported.messages[0].sessionID, knownSessionID,
                       "Message sessionID must match the preserved session UUID")
    }

    // MARK: - Error cases

    func test_error_emptyDataThrows() {
        XCTAssertThrowsError(try format.decode(Data())) { error in
            XCTAssertEqual(error as? JSONLImportError, .emptyData,
                           "Empty data must throw JSONLImportError.emptyData")
        }
    }

    func test_error_malformedJSONThrows() {
        let garbage = "not json at all\n".data(using: .utf8)!
        XCTAssertThrowsError(try format.decode(garbage)) { error in
            guard case .malformedJSON(let line, _) = error as? JSONLImportError else {
                XCTFail("Expected JSONLImportError.malformedJSON, got \(error)")
                return
            }
            XCTAssertEqual(line, 1, "The malformed-JSON error must report the correct line number")
        }
    }

    func test_error_missingRoleFieldThrows() {
        // A JSON object without "role" is not a valid message line.
        let missingRole = #"{"content":"hi","timestamp":"2026-01-01T00:00:00Z"}"# + "\n"
        let data = missingRole.data(using: .utf8)!
        XCTAssertThrowsError(try format.decode(data)) { error in
            // Missing role decodes into a Swift error from JSONDecoder (keyNotFound),
            // which surfaces as malformedJSON since MessageLine requires role.
            XCTAssertNotNil(error as? JSONLImportError,
                            "Missing role must produce a JSONLImportError, not a generic error")
        }
    }

    func test_error_missingContentFieldThrows() {
        // "content" is required — a line without it cannot reconstruct the message.
        let missingContent = #"{"role":"user","timestamp":"2026-01-01T00:00:00Z"}"# + "\n"
        let data = missingContent.data(using: .utf8)!
        XCTAssertThrowsError(try format.decode(data)) { error in
            XCTAssertNotNil(error as? JSONLImportError,
                            "Missing content must produce a JSONLImportError")
        }
    }

    func test_error_missingTimestampFieldThrows() {
        // timestamp is required for chronological ordering.
        let missingTimestamp = #"{"role":"user","content":"hello"}"# + "\n"
        let data = missingTimestamp.data(using: .utf8)!
        XCTAssertThrowsError(try format.decode(data)) { error in
            guard case .missingField(_, let field) = error as? JSONLImportError else {
                XCTFail("Expected JSONLImportError.missingField, got \(error)")
                return
            }
            XCTAssertTrue(field.contains("timestamp"),
                          "Missing timestamp error must name the 'timestamp' field")
        }
    }

    func test_error_unknownRoleThrows() {
        // An unrecognized role string must not silently produce a default role.
        let badRole = #"{"role":"robot","content":"beep","timestamp":"2026-01-01T00:00:00Z"}"# + "\n"
        let data = badRole.data(using: .utf8)!
        XCTAssertThrowsError(try format.decode(data)) { error in
            guard case .missingField(_, let field) = error as? JSONLImportError else {
                XCTFail("Expected JSONLImportError.missingField for unknown role, got \(error)")
                return
            }
            XCTAssertTrue(field.contains("role"),
                          "Unknown role error must reference the 'role' field")
        }
    }

    func test_error_noMessages_headerOnlyThrows() {
        // An envelope-only file (session header with zero message lines) must throw.
        let envelopeOnly = #"{"id":"\#(UUID().uuidString)","title":"No Messages","timestamp":"2026-01-01T00:00:00Z"}"# + "\n"
        let data = envelopeOnly.data(using: .utf8)!
        XCTAssertThrowsError(try format.decode(data)) { error in
            XCTAssertEqual(error as? JSONLImportError, .noMessages,
                           "A file with only a session envelope and no messages must throw .noMessages")
        }
    }

    // MARK: - Session defaults

    func test_session_defaultTitleWhenEnvelopeAbsent() throws {
        // When no session envelope is present the importer synthesises a
        // session with a sensible default title rather than crashing or
        // leaving title empty.
        let line = #"{"role":"user","content":"hi","timestamp":"2026-01-01T00:00:00Z"}"# + "\n"
        let imported = try format.decode(line.data(using: .utf8)!)

        XCTAssertFalse(imported.session.title.isEmpty,
                       "Synthesised session must have a non-empty title")
    }

    func test_session_messagesReferenceSynthesisedSessionID() throws {
        // All decoded messages must use the same sessionID as the decoded session.
        let lines = [
            #"{"role":"user","content":"a","timestamp":"2026-01-01T00:00:00Z"}"#,
            #"{"role":"assistant","content":"b","timestamp":"2026-01-01T00:00:01Z"}"#,
        ].joined(separator: "\n") + "\n"

        let imported = try format.decode(lines.data(using: .utf8)!)

        for message in imported.messages {
            XCTAssertEqual(message.sessionID, imported.session.id,
                           "Every decoded message must carry the session ID from the decoded session record")
        }
    }
}
