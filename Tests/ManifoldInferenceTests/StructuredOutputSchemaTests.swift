import XCTest
@testable import ManifoldInference

/// Unit tests for the public ``StructuredOutputSchema`` facade (#1992): schema →
/// GBNF grammar, and validate / parse against the same schema.
final class StructuredOutputSchemaTests: XCTestCase {

    // A weather-extraction-style object schema reused across tests.
    private func weatherSchema() -> JSONSchemaValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "city": .object(["type": .string("string")]),
                "units": .object([
                    "type": .string("string"),
                    "enum": .array([.string("metric"), .string("imperial")]),
                ]),
            ]),
            "required": .array([.string("city")]),
        ])
    }

    // MARK: - Grammar lowering

    func testObjectSchemaLowersToGrammar() {
        let schema = StructuredOutputSchema(weatherSchema())
        let grammar = schema.gbnfGrammar()
        XCTAssertNotNil(grammar, "An object schema must lower to a non-nil grammar.")
        let g = grammar ?? ""
        // The grammar must constrain the declared keys and the enum values.
        XCTAssertTrue(g.contains("root ::="), "Grammar must declare a root rule.")
        XCTAssertTrue(g.contains("city"), "Grammar must constrain the 'city' key.")
        XCTAssertTrue(g.contains("metric") && g.contains("imperial"),
                      "Grammar must encode the units enum literals.")
    }

    func testTypeOmittedObjectSchemaStillLowers() {
        // Extraction payloads commonly omit `type` when `properties` is declared.
        let schema = StructuredOutputSchema(.object([
            "properties": .object([
                "name": .object(["type": .string("string")]),
            ]),
        ]))
        XCTAssertNotNil(schema.gbnfGrammar(),
                        "A properties-only object schema must still lower to a grammar.")
    }

    func testBareScalarSchemaLowersToNil() {
        // A schema that constrains nothing must return nil so the caller can fall
        // back to unconstrained sampling rather than ship a vacuous grammar.
        let schema = StructuredOutputSchema(.object([:]))
        XCTAssertNil(schema.gbnfGrammar(),
                     "An empty object schema carries no constraint and must lower to nil.")
    }

    // MARK: - Validation

    func testValidValueValidatesClean() {
        let schema = StructuredOutputSchema(weatherSchema())
        let value: JSONSchemaValue = .object([
            "city": .string("Paris"),
            "units": .string("metric"),
        ])
        XCTAssertNil(schema.validate(value),
                     "A conforming value must produce no violation.")
    }

    func testMissingRequiredFieldFailsWithModelReadableMessage() {
        let schema = StructuredOutputSchema(weatherSchema())
        let value: JSONSchemaValue = .object(["units": .string("metric")])
        let violation = schema.validate(value)
        XCTAssertNotNil(violation, "A missing required field must produce a violation.")
        XCTAssertTrue(violation?.modelReadableMessage.contains("city") ?? false,
                      "The message must name the missing field.")
    }

    func testEnumViolationReported() {
        let schema = StructuredOutputSchema(weatherSchema())
        let value: JSONSchemaValue = .object([
            "city": .string("Paris"),
            "units": .string("kelvin"),
        ])
        let violation = schema.validate(value)
        XCTAssertNotNil(violation, "An out-of-enum value must fail validation.")
    }

    // MARK: - validate(json:)

    func testValidateJSONString() {
        let schema = StructuredOutputSchema(weatherSchema())
        XCTAssertNil(schema.validate(json: #"{"city":"Paris"}"#),
                     "Valid JSON satisfying the schema must validate clean.")
        XCTAssertNotNil(schema.validate(json: #"{"units":"metric"}"#),
                        "Valid JSON missing a required field must fail.")
    }

    func testMalformedJSONStringFails() {
        let schema = StructuredOutputSchema(weatherSchema())
        let violation = schema.validate(json: "{not json")
        XCTAssertNotNil(violation, "Malformed JSON must produce a violation, not a pass.")
    }

    // MARK: - parse

    func testParseReturnsTypedValueOnSuccess() {
        let schema = StructuredOutputSchema(weatherSchema())
        switch schema.parse(#"{"city":"Berlin","units":"imperial"}"#) {
        case .success(let value):
            guard case let .object(dict) = value else {
                return XCTFail("Parsed value must be an object.")
            }
            XCTAssertEqual(dict["city"], .string("Berlin"))
        case .failure(let violation):
            XCTFail("Expected success, got: \(violation.modelReadableMessage)")
        }
    }

    func testParseFailsOnSchemaViolation() {
        let schema = StructuredOutputSchema(weatherSchema())
        switch schema.parse(#"{"units":"metric"}"#) {
        case .success:
            XCTFail("Parse must fail when a required field is missing.")
        case .failure(let violation):
            XCTAssertTrue(violation.modelReadableMessage.contains("city"),
                          "Failure must name the missing field for model self-repair.")
        }
    }

    func testParseFailsOnMalformedJSON() {
        let schema = StructuredOutputSchema(weatherSchema())
        switch schema.parse("not json at all") {
        case .success:
            XCTFail("Parse must fail on non-JSON input.")
        case .failure:
            break // expected
        }
    }

    func testGrammarConstrainsOutputAcceptedByValidator() {
        // End-to-end intent: a value the grammar would permit should also pass
        // validation (the two surfaces agree on the happy path).
        let schema = StructuredOutputSchema(weatherSchema())
        XCTAssertNotNil(schema.gbnfGrammar())
        XCTAssertNil(schema.validate(json: #"{"city":"Tokyo","units":"metric"}"#))
    }
}
