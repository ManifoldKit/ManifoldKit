import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
import ManifoldInference
@testable import ManifoldTestSupport

final class MessagePartTests: XCTestCase {

    // MARK: - Codable Round-Trip

    func test_textPart_codableRoundTrip() throws {
        let part = MessagePart.text("Hello, world!")
        let data = try JSONEncoder().encode([part])
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)
        XCTAssertEqual(decoded, [part])
    }

    func test_imagePart_codableRoundTrip() throws {
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let part = MessagePart.image(data: imageData, mimeType: "image/jpeg")
        let data = try JSONEncoder().encode([part])
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)
        XCTAssertEqual(decoded, [part])
    }

    func test_imagePartWithPlaceholder_codableRoundTrip() throws {
        let imageData = ImageFixtures.oneByOnePNGData
        let placeholder = try XCTUnwrap(ImagePlaceholderHash.generate(from: imageData))
        let part = MessagePart.image(data: imageData, mimeType: "image/png", placeholderHash: placeholder)

        let data = try JSONEncoder().encode([part])
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)

        XCTAssertEqual(decoded, [part])
        XCTAssertNotNil(decoded.first?.imagePlaceholderHash?.colorGrid)
    }

    func test_imagePart_withoutPlaceholder_decodesLegacyJSON() throws {
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let legacyJSON = #"[{"image":{"data":"\#(imageData.base64EncodedString())","mimeType":"image/jpeg"}}]"#

        let decoded = try JSONDecoder().decode([MessagePart].self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(decoded, [.image(data: imageData, mimeType: "image/jpeg")])
        XCTAssertNil(decoded.first?.imagePlaceholderHash)
    }

    func test_generatingImagePlaceholderIfNeeded_preservesExistingPlaceholder() throws {
        let imageData = ImageFixtures.oneByOnePNGData
        let placeholder = try XCTUnwrap(ImagePlaceholderHash.generate(from: imageData))
        let part = MessagePart.image(data: imageData, mimeType: "image/png", placeholderHash: placeholder)

        XCTAssertEqual(part.generatingImagePlaceholderIfNeeded(), part)
    }

    func test_audioPart_codableRoundTrip() throws {
        let part = MessagePart.audio(
            url: URL(fileURLWithPath: "/Users/example/Library/Containers/app/audio.m4a"),
            duration: 12.5,
            waveform: [0, 0.25, 1]
        )
        let data = try JSONEncoder().encode([part])
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)
        XCTAssertEqual(decoded, [part])
    }

    func test_mixedParts_codableRoundTrip() throws {
        let parts: [MessagePart] = [
            .text("Here is the weather:"),
            .image(data: Data([0xFF, 0xD8, 0xFF, 0xE0]), mimeType: "image/jpeg"),
            .audio(url: URL(fileURLWithPath: "/Users/example/audio.m4a"), duration: 3, waveform: nil),
            .text("It's rainy today."),
            .image(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png"),
        ]
        let data = try JSONEncoder().encode(parts)
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)
        XCTAssertEqual(decoded, parts)
    }

    // MARK: - textContent

    func test_textContent_returnsTextForTextPart() {
        let part = MessagePart.text("hello")
        XCTAssertEqual(part.textContent, "hello")
    }

    func test_textContent_returnsNilForImagePart() {
        let part = MessagePart.image(data: Data(), mimeType: "image/png")
        XCTAssertNil(part.textContent)
    }

    func test_audioContent_returnsAudioPayload() {
        let url = URL(fileURLWithPath: "/Users/example/audio.m4a")
        let part = MessagePart.audio(url: url, duration: 9, waveform: [0.1, 0.8])
        XCTAssertNil(part.textContent)
        XCTAssertEqual(part.audioContent?.url, url)
        XCTAssertEqual(part.audioContent?.duration, 9)
        XCTAssertEqual(part.audioContent?.waveform, [0.1, 0.8])
    }

    // MARK: - ChatMessageRecord backward compatibility

    func test_chatMessageRecord_contentStringInit_createsTextPart() {
        let record = ChatMessageRecord(role: .user, content: "Hello", sessionID: UUID())
        XCTAssertEqual(record.contentParts, [.text("Hello")])
        XCTAssertEqual(record.content, "Hello")
    }

    func test_chatMessageRecord_contentParts_concatenatesTextParts() {
        let record = ChatMessageRecord(
            role: .assistant,
            contentParts: [
                .text("Part 1"),
                .image(data: Data(), mimeType: "image/png"),
                .audio(url: URL(fileURLWithPath: "/Users/example/audio.m4a"), duration: 3, waveform: nil),
                .text("Part 2"),
            ],
            sessionID: UUID()
        )
        XCTAssertEqual(record.content, "Part 1Part 2")
    }

    func test_chatMessageRecord_settingContent_replacesAllParts() {
        var record = ChatMessageRecord(
            role: .user,
            contentParts: [.text("old"), .image(data: Data(), mimeType: "image/png")],
            sessionID: UUID()
        )
        record.content = "new text only"
        XCTAssertEqual(record.contentParts, [.text("new text only")])
    }

    // MARK: - ChatMessage JSON edge cases

    func test_chatMessage_decode_malformedJSON_fallsBackToTextPart() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let sessionID = UUID()
        let message = ChatMessage(role: .user, content: "original", sessionID: sessionID)
        context.insert(message)
        try context.save()

        // Corrupt the JSON directly
        message.contentPartsJSON = "not valid json"
        let parts = message.contentParts
        // Should fall back to treating the raw string as a text part
        XCTAssertEqual(parts, [.text("not valid json")])
    }

    func test_chatMessage_decode_emptyString_returnsEmptyArray() {
        let parts = ManifoldSchemaV4.ChatMessage.decode("")
        XCTAssertEqual(parts, [])
    }

    // Regression lock for the fallback behavior that made the tool-case removal safe — see PR #270 audit.
    // Simulates a hypothetical pre-0.6.x persisted row containing a removed `.toolCall` discriminator
    // alongside a still-valid `.text` part. The decode path must not crash; it must degrade to a single
    // `.text` bubble containing the raw JSON so the user sees something rather than losing the message.
    func test_chatMessage_decode_legacyToolCaseJSON_fallsBackToRawTextPart() {
        let legacyJSON = #"""
        [{"text":{"_0":"Hello"}},{"toolCall":{"_0":{"id":"tc1","name":"get_weather","arguments":"{\"city\":\"London\"}"}}}]
        """#

        let parts = ManifoldSchemaV4.ChatMessage.decode(legacyJSON)

        XCTAssertEqual(parts, [.text(legacyJSON)])
    }

    func test_chatMessage_contentParts_syncContentString() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let sessionID = UUID()
        let message = ChatMessage(
            role: .assistant,
            contentParts: [
                .text("hello "),
                .image(data: Data(), mimeType: "image/png"),
                .audio(url: URL(fileURLWithPath: "/Users/example/audio.m4a"), duration: 3, waveform: nil),
                .text("world"),
            ],
            sessionID: sessionID
        )
        context.insert(message)
        try context.save()

        // The stored content column should be the concatenation of text parts
        XCTAssertEqual(message.content, "hello world")
    }

    // MARK: - V1 -> V2 migration safety

    func test_chatMessage_v2Model_preservesContentColumn() throws {
        // Simulates the migration path: a V2 message created with the string init
        // must have both `content` (stored) and `contentPartsJSON` populated.
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let sessionID = UUID()
        let message = ChatMessage(role: .user, content: "migrated text", sessionID: sessionID)
        context.insert(message)
        try context.save()

        // Both paths should return the same data
        XCTAssertEqual(message.content, "migrated text")
        XCTAssertEqual(message.contentParts, [.text("migrated text")])
        XCTAssertFalse(message.contentPartsJSON.isEmpty)
    }
}
