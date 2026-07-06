import XCTest
import ManifoldAppEval

// MARK: - GoldenTaskSchemaTests

/// Decode round-trips for the ``GoldenTaskFixture`` JSON schema, plus a
/// malformed-fixture rejection case.
final class GoldenTaskSchemaTests: XCTestCase {

    func test_decode_minimalFixture_roundTrips() throws {
        let json = """
        {
          "id": "minimal",
          "turns": [
            { "kind": "send", "text": "hi", "cannedResponse": "hello" }
          ],
          "checkpoints": [
            { "afterTurnIndex": 0, "requiredContent": ["hello"] }
          ]
        }
        """
        let fixture = try JSONDecoder().decode(GoldenTaskFixture.self, from: Data(json.utf8))

        XCTAssertEqual(fixture.id, "minimal")
        XCTAssertNil(fixture.systemPrompt)
        XCTAssertEqual(fixture.turns.count, 1)
        XCTAssertEqual(fixture.turns[0].kind, .send)
        XCTAssertEqual(fixture.turns[0].text, "hi")
        XCTAssertEqual(fixture.turns[0].cannedResponse, "hello")
        XCTAssertEqual(fixture.checkpoints.count, 1)
        XCTAssertEqual(fixture.checkpoints[0].afterTurnIndex, 0)
        XCTAssertEqual(fixture.checkpoints[0].requiredContent, ["hello"])
        XCTAssertEqual(fixture.checkpoints[0].displayLabel, "turn 0")
    }

    func test_decode_fullFixture_roundTrips() throws {
        let json = """
        {
          "id": "full",
          "systemPrompt": "Be terse.",
          "turns": [
            { "kind": "send", "text": "hi", "cannedResponse": "hello", "cancelAfterTokens": 2 },
            { "kind": "regenerate" }
          ],
          "checkpoints": [
            {
              "afterTurnIndex": 1,
              "label": "final",
              "requiredContent": ["a"],
              "forbiddenContent": ["b"],
              "expectedEvents": ["streamStarted", "streamFinished"],
              "expectedToolCalls": [ { "name": "echo", "argumentsContain": { "text": "hi" } } ],
              "expectedCompression": { "maxRetainedMessages": 4, "minInsertedRecords": 1 },
              "expectedContextSlots": { "minSlots": 1, "maxSlots": 3 },
              "custom": { "myScorer": { "threshold": 0.5, "flag": true, "label": "x" } }
            }
          ]
        }
        """
        let fixture = try JSONDecoder().decode(GoldenTaskFixture.self, from: Data(json.utf8))

        XCTAssertEqual(fixture.systemPrompt, "Be terse.")
        XCTAssertEqual(fixture.turns[0].cancelAfterTokens, 2)
        XCTAssertEqual(fixture.turns[1].kind, .regenerate)

        let checkpoint = fixture.checkpoints[0]
        XCTAssertEqual(checkpoint.displayLabel, "final")
        XCTAssertEqual(checkpoint.expectedToolCalls?.first?.name, "echo")
        XCTAssertEqual(checkpoint.expectedToolCalls?.first?.argumentsContain?["text"], "hi")
        XCTAssertEqual(checkpoint.expectedCompression?.maxRetainedMessages, 4)
        XCTAssertEqual(checkpoint.expectedCompression?.minInsertedRecords, 1)
        XCTAssertEqual(checkpoint.expectedContextSlots?.minSlots, 1)
        XCTAssertEqual(checkpoint.expectedContextSlots?.maxSlots, 3)

        guard case .number(let threshold) = checkpoint.custom?["myScorer"].flatMap({ objectValue($0, "threshold") }) else {
            return XCTFail("expected custom.myScorer.threshold to decode as a JSONValue.number")
        }
        XCTAssertEqual(threshold, 0.5)
    }

    func test_encode_thenDecode_isLossless() throws {
        let original = GoldenTaskFixture(
            id: "roundtrip",
            systemPrompt: "sp",
            turns: [
                GoldenTurn(kind: .send, text: "hi", cannedResponse: "hello", cancelAfterTokens: nil),
            ],
            checkpoints: [
                GoldenCheckpoint(
                    afterTurnIndex: 0,
                    label: "l",
                    requiredContent: ["hello"],
                    custom: ["k": .object(["nested": .array([.number(1), .string("s")])])]
                ),
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GoldenTaskFixture.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// A fixture missing the required `id` key must fail to decode with a
    /// clear error, not silently produce a partially-populated fixture.
    func test_decode_malformedFixture_missingID_throws() {
        let json = """
        {
          "turns": [],
          "checkpoints": []
        }
        """
        XCTAssertThrowsError(try JSONDecoder().decode(GoldenTaskFixture.self, from: Data(json.utf8))) { error in
            guard error is DecodingError else {
                return XCTFail("expected a DecodingError, got \(error)")
            }
        }
    }

    /// A checkpoint whose `afterTurnIndex` is not an integer must fail to
    /// decode rather than coercing.
    func test_decode_malformedFixture_nonIntegerAfterTurnIndex_throws() {
        let json = """
        {
          "id": "bad",
          "turns": [],
          "checkpoints": [ { "afterTurnIndex": "zero" } ]
        }
        """
        XCTAssertThrowsError(try JSONDecoder().decode(GoldenTaskFixture.self, from: Data(json.utf8)))
    }

    // MARK: - GoldenTaskLoader

    func test_loader_loadFromURL_decodesBundledFixture() throws {
        let url = try fixtureURL(named: "send-receive-smoke")
        let fixture = try GoldenTaskLoader.load(from: url)
        XCTAssertEqual(fixture.id, "send-receive-smoke")
    }

    func test_loader_directoryMissing_throwsDescriptiveError() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        XCTAssertThrowsError(try GoldenTaskLoader.loadAll(from: missing)) { error in
            guard let loadError = error as? GoldenTaskLoader.LoadError else {
                return XCTFail("expected GoldenTaskLoader.LoadError, got \(error)")
            }
            if case .directoryMissing = loadError {} else {
                XCTFail("expected .directoryMissing, got \(loadError)")
            }
        }
    }

    // MARK: - Helpers

    private func fixtureURL(named name: String) throws -> URL {
        // `resources: [.copy("Fixtures")]` on the ManifoldAppEvalTests target
        // guarantees this resolves — a miss here is a packaging regression,
        // not a condition to skip past.
        try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "Fixture '\(name).json' not found in test bundle resources"
        )
    }

    private func objectValue(_ value: JSONValue, _ key: String) -> JSONValue? {
        if case .object(let dict) = value { return dict[key] }
        return nil
    }
}
