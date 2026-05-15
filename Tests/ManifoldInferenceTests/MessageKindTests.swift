import XCTest
@testable import ManifoldInference

/// Unit tests for ``MessageKind`` encode/decode, wire visibility, and
/// user-visibility semantics.
final class MessageKindTests: XCTestCase {

    // MARK: - Raw storage round-trips

    func test_rawStorage_chat() {
        let kind = MessageKind.chat
        XCTAssertEqual(kind.rawStorage, "chat")
        XCTAssertEqual(MessageKind(rawStorage: "chat"), .chat)
    }

    func test_rawStorage_memory() {
        let kind = MessageKind.memory("summary")
        XCTAssertEqual(kind.rawStorage, "memory:summary")
        XCTAssertEqual(MessageKind(rawStorage: "memory:summary"), .memory("summary"))
    }

    func test_rawStorage_annotation() {
        let kind = MessageKind.annotation("note")
        XCTAssertEqual(kind.rawStorage, "annotation:note")
        XCTAssertEqual(MessageKind(rawStorage: "annotation:note"), .annotation("note"))
    }

    func test_rawStorage_toolResult() {
        let kind = MessageKind.toolResult(callID: "call-123")
        XCTAssertEqual(kind.rawStorage, "toolResult:call-123")
        XCTAssertEqual(MessageKind(rawStorage: "toolResult:call-123"), .toolResult(callID: "call-123"))
    }

    func test_rawStorage_custom() {
        let kind = MessageKind.custom("myKind")
        XCTAssertEqual(kind.rawStorage, "custom:myKind")
        XCTAssertEqual(MessageKind(rawStorage: "custom:myKind"), .custom("myKind"))
    }

    func test_rawStorage_unknownPrefix_decodesAsNil() {
        // Unknown prefixes return nil from the failable init, decoding as .chat
        // to avoid corrupting old installs that roll back.
        XCTAssertNil(MessageKind(rawStorage: "unknown:value"))
        XCTAssertNil(MessageKind(rawStorage: "nocolon"))
    }

    // MARK: - Codable round-trips

    func test_codable_roundTrip_chat() throws {
        let encoded = try JSONEncoder().encode(MessageKind.chat)
        let decoded = try JSONDecoder().decode(MessageKind.self, from: encoded)
        XCTAssertEqual(decoded, .chat)
    }

    func test_codable_roundTrip_memory() throws {
        let kind = MessageKind.memory("compression")
        let encoded = try JSONEncoder().encode(kind)
        let decoded = try JSONDecoder().decode(MessageKind.self, from: encoded)
        XCTAssertEqual(decoded, .memory("compression"))
    }

    func test_codable_roundTrip_annotation() throws {
        let kind = MessageKind.annotation("edited")
        let encoded = try JSONEncoder().encode(kind)
        let decoded = try JSONDecoder().decode(MessageKind.self, from: encoded)
        XCTAssertEqual(decoded, .annotation("edited"))
    }

    func test_codable_roundTrip_toolResult() throws {
        let kind = MessageKind.toolResult(callID: "abc-999")
        let encoded = try JSONEncoder().encode(kind)
        let decoded = try JSONDecoder().decode(MessageKind.self, from: encoded)
        XCTAssertEqual(decoded, .toolResult(callID: "abc-999"))
    }

    func test_codable_roundTrip_custom() throws {
        let kind = MessageKind.custom("host-debug")
        let encoded = try JSONEncoder().encode(kind)
        let decoded = try JSONDecoder().decode(MessageKind.self, from: encoded)
        XCTAssertEqual(decoded, .custom("host-debug"))
    }

    func test_codable_unknownPrefix_decodesAsChat() throws {
        // Old app versions writing an unknown prefix must not crash new installs;
        // unknown kinds fall back to .chat.
        let raw = "\"futureKind:payload\""
        let data = raw.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MessageKind.self, from: data)
        XCTAssertEqual(decoded, .chat)
    }

    // MARK: - isWireVisible

    func test_isWireVisible_chat() {
        XCTAssertTrue(MessageKind.chat.isWireVisible)
    }

    func test_isWireVisible_memory() {
        XCTAssertTrue(MessageKind.memory("summary").isWireVisible)
    }

    func test_isWireVisible_annotation() {
        XCTAssertFalse(MessageKind.annotation("note").isWireVisible)
    }

    func test_isWireVisible_toolResult() {
        XCTAssertFalse(MessageKind.toolResult(callID: "x").isWireVisible)
    }

    func test_isWireVisible_custom() {
        XCTAssertTrue(MessageKind.custom("host").isWireVisible)
    }

    // MARK: - isUserVisible

    func test_isUserVisible_chat() {
        XCTAssertTrue(MessageKind.chat.isUserVisible)
    }

    func test_isUserVisible_memory() {
        XCTAssertFalse(MessageKind.memory("summary").isUserVisible)
    }

    func test_isUserVisible_annotation() {
        XCTAssertFalse(MessageKind.annotation("note").isUserVisible)
    }

    func test_isUserVisible_toolResult() {
        XCTAssertFalse(MessageKind.toolResult(callID: "x").isUserVisible)
    }

    func test_isUserVisible_custom() {
        XCTAssertFalse(MessageKind.custom("host").isUserVisible)
    }

    // MARK: - backendRole

    func test_backendRole_chat() {
        // .chat uses record.role directly; backendRole returns nil as the signal.
        XCTAssertNil(MessageKind.chat.backendRole)
    }

    func test_backendRole_memory() {
        XCTAssertEqual(MessageKind.memory("summary").backendRole, .system)
    }

    func test_backendRole_annotation() {
        XCTAssertNil(MessageKind.annotation("note").backendRole)
    }

    func test_backendRole_toolResult() {
        XCTAssertNil(MessageKind.toolResult(callID: "x").backendRole)
    }

    func test_backendRole_custom() {
        XCTAssertEqual(MessageKind.custom("host").backendRole, .system)
    }

    // MARK: - rawStorage format contract

    func test_rawStorage_memoryPreservesColonInLabel() {
        // Labels with colons must survive: maxSplits:1 ensures only the first
        // colon is the separator.
        let kind = MessageKind.memory("prefix:suffix")
        let storage = kind.rawStorage  // "memory:prefix:suffix"
        let roundTripped = MessageKind(rawStorage: storage)
        XCTAssertEqual(roundTripped, .memory("prefix:suffix"))
    }
}
