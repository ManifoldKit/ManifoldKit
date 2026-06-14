import XCTest
import ManifoldInference

/// Unit tests for ``MessagePart/generatedMedia(_:)`` — Codable round-tripping,
/// wire-format pinning, accessor behaviour, `textContent` exclusion, and the
/// P4b BACKWARD-COMPATIBLE DECODE of legacy `generatedImage` / `generatedVideo`
/// rows into the collapsed `.generatedMedia` case.
///
/// Distinct from ``MessagePart/image(data:mimeType:)``: the `.image` case
/// carries raw bytes the *user* uploaded as multimodal input; this case
/// references a file URL whose binary is the model's *output*.
final class MessagePartGeneratedImageTests: XCTestCase {

    // MARK: - Fixtures

    private func makeImageSnapshot() -> ImageGenerationConfigSnapshot {
        ImageGenerationConfigSnapshot(
            steps: 8,
            width: 512,
            height: 768,
            seed: 42,
            guidanceScale: 7.5
        )
    }

    private func makeImagePayload(
        prompt: String = "a watercolor of a fox",
        url: URL = URL(fileURLWithPath: "/tmp/manifoldKitTest/img.png"),
        modelIdentifier: String = "fake-model-v1"
    ) -> GeneratedMediaPayload {
        GeneratedMediaPayload(
            kind: .image,
            prompt: prompt,
            url: url,
            modelIdentifier: modelIdentifier,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            width: 512,
            height: 768,
            imageConfig: makeImageSnapshot()
        )
    }

    private func makeLegacyImagePayload() -> ImageMessagePayload {
        ImageMessagePayload(
            prompt: "a sunset",
            imageURL: URL(string: "file:///tmp/img.png")!,
            modelIdentifier: "flux-schnell",
            generationConfig: makeImageSnapshot(),
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeLegacyVideoPayload() -> VideoMessagePayload {
        VideoMessagePayload(
            prompt: "a drone shot",
            videoURL: URL(string: "file:///tmp/vid.mp4")!,
            modelIdentifier: "veo-x",
            generationConfig: VideoGenerationConfigSnapshot(
                duration: 5,
                aspectRatio: "16:9",
                width: 1280,
                height: 720
            ),
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Codable round-trip

    func test_generatedMedia_codableRoundtrip() throws {
        let part: MessagePart = .generatedMedia(makeImagePayload())

        let data = try JSONEncoder().encode([part])
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)

        XCTAssertEqual(decoded, [part],
            ".generatedMedia must survive Codable round-trip with all payload fields preserved")
    }

    // MARK: - Wire-format discriminator pinning

    /// Renaming the `.generatedMedia` raw key would silently strand every
    /// persisted row that already wrote it. Pin the literal key here so a
    /// rename surfaces as a test failure rather than a quiet migration.
    func test_generatedMedia_wireFormatDiscriminatorIsPinned() throws {
        let part: MessagePart = .generatedMedia(makeImagePayload())
        let data = try JSONEncoder().encode([part])
        let json = String(data: data, encoding: .utf8) ?? ""

        XCTAssertTrue(json.contains(#""generatedMedia""#),
            "Persisted JSON must use the literal discriminator key 'generatedMedia'")
        XCTAssertTrue(json.contains(#""kind""#),
            "GeneratedMediaPayload.kind discriminator must encode under the literal key 'kind'")
    }

    /// Pin representative payload field names. If GeneratedMediaPayload field
    /// names are renamed, persisted rows would silently fail to round-trip.
    func test_generatedMedia_payloadFieldNamesArePinned() throws {
        let part: MessagePart = .generatedMedia(makeImagePayload())
        let data = try JSONEncoder().encode([part])
        let json = String(data: data, encoding: .utf8) ?? ""

        XCTAssertTrue(json.contains(#""prompt""#))
        XCTAssertTrue(json.contains(#""url""#))
        XCTAssertTrue(json.contains(#""modelIdentifier""#))
        XCTAssertTrue(json.contains(#""generatedAt""#))
    }

    // MARK: - Mixed-array round-trip with all cases

    func test_allCases_mixedArray_codableRoundtrip() throws {
        let parts: [MessagePart] = [
            .text("Here is what I generated:"),
            .thinking("Let me think about composition."),
            .toolCall(ToolCall(id: "c1", toolName: "render", arguments: "{}")),
            .toolResult(ToolResult(callId: "c1", content: "ok")),
            .image(data: Data([0xFF]), mimeType: "image/jpeg"),
            .audio(url: URL(fileURLWithPath: "/Users/example/audio.m4a"), duration: 4, waveform: [0.1, 0.9]),
            .generatedMedia(makeImagePayload()),
        ]

        let data = try JSONEncoder().encode(parts)
        let decoded = try JSONDecoder().decode([MessagePart].self, from: data)

        XCTAssertEqual(decoded, parts,
            "Mixed array including .generatedMedia must round-trip intact, preserving order")
    }

    // MARK: - textContent exclusion

    func test_textContent_returnsNil_forGeneratedMedia() {
        let part: MessagePart = .generatedMedia(makeImagePayload())
        XCTAssertNil(part.textContent,
            ".textContent must be nil for .generatedMedia (consistent with .image / .toolCall / .toolResult / .thinking)")
    }

    // MARK: - Accessor

    func test_generatedMediaContent_returnsAssociatedValue() {
        let payload = makeImagePayload(prompt: "a robot reading a book")
        let part: MessagePart = .generatedMedia(payload)

        XCTAssertEqual(part.generatedMediaContent, payload)
        XCTAssertNil(part.toolCallContent)
        XCTAssertNil(part.toolResultContent)
        XCTAssertNil(part.thinkingContent)
        XCTAssertNil(part.textContent)
    }

    func test_generatedMediaContent_returnsNil_forOtherCases() {
        XCTAssertNil(MessagePart.text("x").generatedMediaContent)
        XCTAssertNil(MessagePart.thinking("x").generatedMediaContent)
        XCTAssertNil(MessagePart.image(data: Data(), mimeType: "image/png").generatedMediaContent)
        XCTAssertNil(MessagePart.audio(url: URL(fileURLWithPath: "/Users/example/audio.m4a"), duration: 1, waveform: nil).generatedMediaContent)
        XCTAssertNil(MessagePart.toolCall(ToolCall(id: "c", toolName: "t", arguments: "{}")).generatedMediaContent)
        XCTAssertNil(MessagePart.toolResult(ToolResult(callId: "c", content: "x")).generatedMediaContent)
    }

    // MARK: - P4b BACKWARD-COMPATIBLE DECODE (critical, no data loss)

    /// A legacy `generatedImage` JSON blob (written before the P4b collapse)
    /// MUST decode into `.generatedMedia` with `kind == .image`, preserving
    /// every field. This is the data-safety contract: pre-collapse persisted
    /// rows never fail to decode and never lose information.
    func test_legacyGeneratedImageKey_decodesIntoGeneratedMedia_lossless() throws {
        let snapshot = makeImageSnapshot()
        let snapshotJSON = try XCTUnwrap(String(data: try JSONEncoder().encode(snapshot), encoding: .utf8))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let dateValue = date.timeIntervalSinceReferenceDate

        // Hand-written legacy outer shape with the retired discriminator
        // "generatedImage" and ImageMessagePayload field names.
        let json = """
        {"generatedImage":{"prompt":"a sunset","imageURL":"file:///tmp/img.png","modelIdentifier":"flux-schnell","generationConfig":\(snapshotJSON),"generatedAt":\(dateValue)}}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(MessagePart.self, from: json)

        guard case .generatedMedia(let media) = decoded else {
            XCTFail("Legacy generatedImage fixture must decode as .generatedMedia, got \(decoded)")
            return
        }
        XCTAssertEqual(media.kind, .image)
        XCTAssertEqual(media.prompt, "a sunset")
        XCTAssertEqual(media.url, URL(string: "file:///tmp/img.png"))
        XCTAssertEqual(media.modelIdentifier, "flux-schnell")
        XCTAssertEqual(media.imageConfig, snapshot,
            "Legacy image config snapshot must ride losslessly in .imageConfig")
        XCTAssertEqual(media.generatedAt.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)

        // Lossless round-back to the legacy payload shape.
        let rebuilt = try XCTUnwrap(media.asImagePayload)
        XCTAssertEqual(rebuilt, makeLegacyImagePayload())
    }

    /// A legacy `generatedVideo` JSON blob MUST decode into `.generatedMedia`
    /// with `kind == .video`, preserving every field.
    func test_legacyGeneratedVideoKey_decodesIntoGeneratedMedia_lossless() throws {
        let legacy = makeLegacyVideoPayload()
        let legacyJSON = try XCTUnwrap(String(data: try JSONEncoder().encode(legacy), encoding: .utf8))

        let json = """
        {"generatedVideo":\(legacyJSON)}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(MessagePart.self, from: json)

        guard case .generatedMedia(let media) = decoded else {
            XCTFail("Legacy generatedVideo fixture must decode as .generatedMedia, got \(decoded)")
            return
        }
        XCTAssertEqual(media.kind, .video)
        XCTAssertEqual(media.prompt, legacy.prompt)
        XCTAssertEqual(media.url, legacy.videoURL)
        XCTAssertEqual(media.videoConfig, legacy.generationConfig,
            "Legacy video config snapshot must ride losslessly in .videoConfig")

        let rebuilt = try XCTUnwrap(media.asVideoPayload)
        XCTAssertEqual(rebuilt, legacy)
    }

    // MARK: - Discriminator-error guards

    func test_messagePart_emptyDiscriminatorContainer_throws() {
        let json = "{}".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(MessagePart.self, from: json),
            "Empty discriminator container must throw — see MessagePart.init(from:)")
    }

    func test_messagePart_multipleDiscriminatorKeys_throws() {
        let json = #"{"text":"hi","generatedImage":{"prompt":"a","imageURL":"file:///tmp/x.png","modelIdentifier":"m","generationConfig":{"steps":1,"width":1,"height":1},"generatedAt":0}}"#
            .data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(MessagePart.self, from: json),
            "Two discriminator keys present must throw — pinned guard in MessagePart.init(from:)")
    }

    // MARK: - Backwards-compat: legacy-only fixture (no generated media)

    func test_legacyMessageParts_withoutGeneratedMedia_decodeIntact() throws {
        let toolCall = ToolCall(id: "c1", toolName: "search", arguments: "{\"q\":\"swift\"}")
        let toolResult = ToolResult(callId: "c1", content: "ok")
        let toolCallJSON = try XCTUnwrap(String(data: try JSONEncoder().encode(toolCall), encoding: .utf8))
        let toolResultJSON = try XCTUnwrap(String(data: try JSONEncoder().encode(toolResult), encoding: .utf8))

        let json = """
        [
          {"text":"hello"},
          {"thinking":{"text":"reasoning","signature":"sig-1"}},
          {"image":{"data":"AQI=","mimeType":"image/png"}},
          {"toolCall":\(toolCallJSON)},
          {"toolResult":\(toolResultJSON)}
        ]
        """.data(using: .utf8)!

        let parts = try JSONDecoder().decode([MessagePart].self, from: json)
        XCTAssertEqual(parts.count, 5)

        guard case .text(let t) = parts[0] else { return XCTFail("0: expected .text") }
        XCTAssertEqual(t, "hello")

        guard case .thinking(let think, let sig) = parts[1] else { return XCTFail("1: expected .thinking") }
        XCTAssertEqual(think, "reasoning")
        XCTAssertEqual(sig, "sig-1")

        guard case .image(let data, let mime, _) = parts[2] else { return XCTFail("2: expected .image") }
        XCTAssertEqual(data, Data([0x01, 0x02]))
        XCTAssertEqual(mime, "image/png")

        guard case .toolCall(let call) = parts[3] else { return XCTFail("3: expected .toolCall") }
        XCTAssertEqual(call, toolCall)

        guard case .toolResult(let result) = parts[4] else { return XCTFail("4: expected .toolResult") }
        XCTAssertEqual(result, toolResult)
    }

    func test_legacyThinkingBareString_decodesAsThinkingWithNilSignature() throws {
        let json = #"{"thinking":"raw legacy reasoning"}"#.data(using: .utf8)!
        let part = try JSONDecoder().decode(MessagePart.self, from: json)

        guard case .thinking(let text, let sig) = part else {
            XCTFail("Bare-string thinking must decode as .thinking")
            return
        }
        XCTAssertEqual(text, "raw legacy reasoning")
        XCTAssertNil(sig)
    }
}
