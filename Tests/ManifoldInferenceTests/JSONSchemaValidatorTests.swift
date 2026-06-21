import XCTest
@testable import ManifoldInference

final class JSONSchemaValidatorTests: XCTestCase {

    private let validator = JSONSchemaValidator()

    // MARK: - Helpers

    /// Parse a JSON string into a `JSONSchemaValue` for brevity in tests.
    private func json(_ raw: String, file: StaticString = #filePath, line: UInt = #line) -> JSONSchemaValue {
        let data = Data(raw.utf8)
        do {
            let decoded = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return JSONSchemaValidator.lift(decoded)
        } catch {
            XCTFail("test JSON did not parse: \(error)", file: file, line: line)
            return .null
        }
    }

    // MARK: - Happy paths

    func test_simpleObject_requiredPresent_valid() {
        let schema = json(#"{"type":"object","required":["city"],"properties":{"city":{"type":"string"}}}"#)
        let value = json(#"{"city":"San Francisco"}"#)
        XCTAssertNil(validator.validate(value, against: schema))
    }

    func test_enumMatch_valid() {
        let schema = json(#"{"type":"string","enum":["metric","imperial"]}"#)
        XCTAssertNil(validator.validate(json(#""metric""#), against: schema))
        XCTAssertNil(validator.validate(json(#""imperial""#), against: schema))
    }

    func test_nestedObject_valid() {
        let schema = json(#"""
        {
          "type": "object",
          "required": ["location"],
          "properties": {
            "location": {
              "type": "object",
              "required": ["city"],
              "properties": {
                "city": {"type":"string"},
                "country": {"type":"string"}
              }
            }
          }
        }
        """#)
        let value = json(#"{"location":{"city":"Paris","country":"FR"}}"#)
        XCTAssertNil(validator.validate(value, against: schema))
    }

    func test_arrayOfStrings_valid() {
        let schema = json(#"{"type":"array","items":{"type":"string"}}"#)
        let value = json(#"["a","b","c"]"#)
        XCTAssertNil(validator.validate(value, against: schema))
    }

    func test_integer_acceptsWholeDouble() {
        let schema = json(#"{"type":"integer"}"#)
        XCTAssertNil(validator.validate(json("5"), against: schema))
        XCTAssertNil(validator.validate(json("5.0"), against: schema))
    }

    // MARK: - Required-field failures

    // SABOTAGE TARGET: the `for field in required` loop in validateObject.
    func test_missingRequired_returnsFailureWithFieldName() {
        let schema = json(#"{"type":"object","required":["city"],"properties":{"city":{"type":"string"}}}"#)
        let value = json(#"{}"#)
        let failure = validator.validate(value, against: schema)
        XCTAssertNotNil(failure, "empty object must fail against required:[city]")
        XCTAssertTrue(
            failure?.modelReadableMessage.contains("'city'") ?? false,
            "message should mention the missing field name; got: \(failure?.modelReadableMessage ?? "nil")"
        )
        XCTAssertTrue(
            failure?.modelReadableMessage.contains("required") ?? false,
            "message should include the word 'required'; got: \(failure?.modelReadableMessage ?? "nil")"
        )
    }

    func test_missingRequired_multiple_firstIsReported() {
        let schema = json(#"{"type":"object","required":["city","country"],"properties":{"city":{"type":"string"},"country":{"type":"string"}}}"#)
        let value = json(#"{}"#)
        let failure = validator.validate(value, against: schema)
        XCTAssertEqual(failure?.path, ["city"], "first missing required field in schema order is reported first")
    }

    func test_missingRequired_nested() {
        let schema = json(#"""
        {
          "type":"object",
          "required":["location"],
          "properties":{
            "location":{
              "type":"object",
              "required":["city"],
              "properties":{"city":{"type":"string"}}
            }
          }
        }
        """#)
        let value = json(#"{"location":{}}"#)
        let failure = validator.validate(value, against: schema)
        XCTAssertEqual(failure?.path, ["location", "city"])
    }

    // MARK: - Type failures

    func test_wrongType_primitive() {
        let schema = json(#"{"type":"number"}"#)
        let failure = validator.validate(json(#""five""#), against: schema)
        XCTAssertNotNil(failure)
        XCTAssertTrue(failure?.modelReadableMessage.contains("number") ?? false)
        XCTAssertTrue(failure?.modelReadableMessage.contains("string") ?? false)
    }

    func test_wrongType_nested() {
        let schema = json(#"{"type":"object","properties":{"count":{"type":"number"}}}"#)
        let failure = validator.validate(json(#"{"count":"five"}"#), against: schema)
        XCTAssertEqual(failure?.path, ["count"])
    }

    func test_wrongType_arrayElement() {
        let schema = json(#"{"type":"array","items":{"type":"number"}}"#)
        let failure = validator.validate(json(#"[1,2,"three"]"#), against: schema)
        XCTAssertEqual(failure?.path, ["[2]"])
    }

    func test_integer_rejectsFractional() {
        let schema = json(#"{"type":"integer"}"#)
        XCTAssertNotNil(validator.validate(json("3.14"), against: schema))
    }

    // MARK: - Enum failures

    func test_enum_valueNotInList() {
        let schema = json(#"{"type":"string","enum":["metric","imperial"]}"#)
        let failure = validator.validate(json(#""celsius""#), against: schema)
        XCTAssertNotNil(failure)
        XCTAssertTrue(failure?.modelReadableMessage.contains("metric") ?? false)
        XCTAssertTrue(failure?.modelReadableMessage.contains("imperial") ?? false)
        XCTAssertTrue(failure?.modelReadableMessage.contains("celsius") ?? false)
    }

    func test_enum_caseSensitive() {
        let schema = json(#"{"type":"string","enum":["Metric"]}"#)
        XCTAssertNotNil(validator.validate(json(#""metric""#), against: schema))
    }

    // MARK: - Range failures

    func test_minimum_failure() {
        let schema = json(#"{"type":"number","minimum":10}"#)
        let failure = validator.validate(json("5"), against: schema)
        XCTAssertNotNil(failure)
        XCTAssertTrue(failure?.modelReadableMessage.contains(">=") ?? false)
    }

    func test_maximum_failure() {
        let schema = json(#"{"type":"number","maximum":10}"#)
        XCTAssertNotNil(validator.validate(json("15"), against: schema))
    }

    func test_minLength_failure() {
        let schema = json(#"{"type":"string","minLength":3}"#)
        XCTAssertNotNil(validator.validate(json(#""hi""#), against: schema))
    }

    func test_maxLength_failure() {
        let schema = json(#"{"type":"string","maxLength":3}"#)
        XCTAssertNotNil(validator.validate(json(#""howdy""#), against: schema))
    }

    func test_minItems_failure() {
        let schema = json(#"{"type":"array","minItems":2}"#)
        XCTAssertNotNil(validator.validate(json("[1]"), against: schema))
    }

    func test_maxItems_failure() {
        let schema = json(#"{"type":"array","maxItems":2}"#)
        XCTAssertNotNil(validator.validate(json("[1,2,3]"), against: schema))
    }

    // MARK: - Union types

    func test_union_acceptsBoth() {
        let schema = json(#"{"type":["string","null"]}"#)
        XCTAssertNil(validator.validate(json(#""hi""#), against: schema))
        XCTAssertNil(validator.validate(json("null"), against: schema))
    }

    func test_union_rejectsOthers() {
        let schema = json(#"{"type":["string","null"]}"#)
        XCTAssertNotNil(validator.validate(json("42"), against: schema))
    }

    // MARK: - additionalProperties

    func test_additionalProperties_falseRejectsUnknown() {
        let schema = json(#"{"type":"object","properties":{"city":{"type":"string"}},"additionalProperties":false}"#)
        let failure = validator.validate(json(#"{"city":"X","unknown":"Y"}"#), against: schema)
        XCTAssertNotNil(failure)
        XCTAssertTrue(failure?.modelReadableMessage.contains("'unknown'") ?? false)
    }

    func test_additionalProperties_trueAllowsUnknown() {
        let schema = json(#"{"type":"object","properties":{"city":{"type":"string"}},"additionalProperties":true}"#)
        XCTAssertNil(validator.validate(json(#"{"city":"X","extra":true}"#), against: schema))
    }

    func test_additionalProperties_omittedAllowsUnknown() {
        let schema = json(#"{"type":"object","properties":{"city":{"type":"string"}}}"#)
        XCTAssertNil(validator.validate(json(#"{"city":"X","extra":true}"#), against: schema))
    }

    // MARK: - Malformed JSON

    func test_malformedJSON_returnsClearMessage() {
        let schema = json(#"{"type":"object"}"#)
        let failure = validator.validate(arguments: "{not json", against: schema)
        XCTAssertNotNil(failure)
        XCTAssertTrue(
            failure?.modelReadableMessage.lowercased().contains("json") ?? false,
            "message should reference JSON parsing; got: \(failure?.modelReadableMessage ?? "nil")"
        )
    }

    func test_validArgumentsString_passes() {
        let schema = json(#"{"type":"object","required":["city"],"properties":{"city":{"type":"string"}}}"#)
        XCTAssertNil(validator.validate(arguments: #"{"city":"SF"}"#, against: schema))
    }

    // MARK: - Unsupported features (fail closed)

    // SABOTAGE TARGET: the `rejectUnsupportedKeywords` call in validate(value:schema:path:).
    func test_unsupportedAnyOf_failsClosed() {
        let schema = json(#"{"anyOf":[{"type":"string"},{"type":"number"}]}"#)
        let failure = validator.validate(json(#""ok""#), against: schema)
        XCTAssertNotNil(failure, "anyOf must fail closed, not silently pass")
        XCTAssertTrue(
            failure?.modelReadableMessage.contains("anyOf") ?? false,
            "message should name the unsupported keyword; got: \(failure?.modelReadableMessage ?? "nil")"
        )
        XCTAssertTrue(
            failure?.modelReadableMessage.contains("unsupported") ?? false,
            "message should say 'unsupported'; got: \(failure?.modelReadableMessage ?? "nil")"
        )
    }

    func test_unsupportedOneOf_failsClosed() {
        let schema = json(#"{"oneOf":[{"type":"string"}]}"#)
        XCTAssertNotNil(validator.validate(json(#""ok""#), against: schema))
    }

    func test_unsupportedAllOf_failsClosed() {
        let schema = json(#"{"allOf":[{"type":"string"}]}"#)
        XCTAssertNotNil(validator.validate(json(#""ok""#), against: schema))
    }

    func test_unsupportedRef_failsClosed() {
        // Use ##..## so `#/...` inside the literal is not taken as a closing delimiter.
        let schema = json(##"{"$ref":"#/$defs/Thing"}"##)
        XCTAssertNotNil(validator.validate(json(#""ok""#), against: schema))
    }

    func test_unsupportedPattern_failsClosed() {
        let schema = json(#"{"type":"string","pattern":"^[a-z]+$"}"#)
        XCTAssertNotNil(validator.validate(json(#""ok""#), against: schema))
    }

    func test_unsupportedFormat_failsClosed() {
        let schema = json(#"{"type":"string","format":"email"}"#)
        XCTAssertNotNil(validator.validate(json(#""a@b.com""#), against: schema))
    }

    func test_unsupportedPatternProperties_failsClosed() {
        let schema = json(#"{"type":"object","patternProperties":{"^x":{"type":"string"}}}"#)
        XCTAssertNotNil(validator.validate(json(#"{"x1":"hi"}"#), against: schema))
    }

    // MARK: - Real-world argument corpus

    /// Walks `Tests/Fixtures/validator/real-world/` and asserts each triple
    /// `<name>.json` + `<name>.schema.json` + `<name>.expected.json` behaves
    /// as the expected verdict declares.
    ///
    /// Fixtures are sibling files on disk rather than SwiftPM resources because
    /// `ManifoldInferenceTests` is an XCTest target that would otherwise need
    /// `resources:` wiring in Package.swift. We locate them relative to this
    /// source file via `#filePath`.
    func test_realWorldCorpus_matchesExpectedVerdicts() throws {
        let fileURL = URL(fileURLWithPath: #filePath)
        // Tests/ManifoldInferenceTests/JSONSchemaValidatorTests.swift ->
        // Tests/Fixtures/validator/real-world/
        let corpusDir = fileURL
            .deletingLastPathComponent()       // Tests/ManifoldInferenceTests
            .deletingLastPathComponent()       // Tests
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("validator")
            .appendingPathComponent("real-world")

        let fm = FileManager.default
        guard fm.fileExists(atPath: corpusDir.path) else {
            XCTFail("corpus directory missing: \(corpusDir.path)")
            return
        }

        let entries = try fm.contentsOfDirectory(at: corpusDir, includingPropertiesForKeys: nil)
        let argumentFiles = entries.filter {
            $0.pathExtension == "json"
                && !$0.lastPathComponent.hasSuffix(".schema.json")
                && !$0.lastPathComponent.hasSuffix(".expected.json")
        }

        XCTAssertGreaterThanOrEqual(argumentFiles.count, 15, "corpus must contain 15+ fixtures; found \(argumentFiles.count)")

        struct Expected: Decodable {
            var valid: Bool
            var messageContains: String?
        }

        for argURL in argumentFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let base = argURL.deletingPathExtension().lastPathComponent
            let schemaURL = corpusDir.appendingPathComponent("\(base).schema.json")
            let expectedURL = corpusDir.appendingPathComponent("\(base).expected.json")

            let argString = try String(contentsOf: argURL, encoding: .utf8)
            let schemaData = try Data(contentsOf: schemaURL)
            let schemaAny = try JSONSerialization.jsonObject(with: schemaData, options: [])
            let schema = JSONSchemaValidator.lift(schemaAny)

            let expectedData = try Data(contentsOf: expectedURL)
            let expected = try JSONDecoder().decode(Expected.self, from: expectedData)

            let failure = validator.validate(arguments: argString, against: schema)

            if expected.valid {
                XCTAssertNil(
                    failure,
                    "\(base): expected valid, got failure: \(failure?.modelReadableMessage ?? "nil")"
                )
            } else {
                XCTAssertNotNil(failure, "\(base): expected failure, got nil")
                if let needle = expected.messageContains, let got = failure?.modelReadableMessage {
                    XCTAssertTrue(
                        got.contains(needle),
                        "\(base): message should contain '\(needle)'; got: '\(got)'"
                    )
                }
            }
        }
    }

    // MARK: - JSONSchemaValidating protocol conformance

    /// The concrete `JSONSchemaValidator` conforms to `JSONSchemaValidating`
    /// so `ToolRegistry` can hold the validator via the protocol without
    /// depending on the concrete type. This test exercises the adapter method
    /// on both a valid and an invalid payload to pin the contract (returns
    /// `nil` on pass, returns a non-empty diagnostic string on fail).
    ///
    /// Sabotage check: forcing the adapter to unconditionally return `nil`
    /// leaves `invalidMessage` at `nil` and the second assertion fails.
    func test_jsonSchemaValidating_conformance_returnsNilOnValid_andMessageOnInvalid() {
        let schema = json(#"{"type":"object","required":["city"],"properties":{"city":{"type":"string"}}}"#)

        let protocolValidator: any JSONSchemaValidating = validator

        let validMessage = protocolValidator.validateAgainst(schema, value: json(#"{"city":"Rome"}"#))
        XCTAssertNil(validMessage, "Valid payload must produce nil under the protocol signature")

        let invalidMessage = protocolValidator.validateAgainst(schema, value: json(#"{}"#))
        XCTAssertNotNil(invalidMessage, "Missing required field must surface as a non-nil protocol message")
        XCTAssertTrue(
            invalidMessage?.contains("city") ?? false,
            "Protocol message should mention the missing field; got: \(invalidMessage ?? "nil")"
        )
    }

    // MARK: - Integer-literal numeric constraints (JSONDecoder path)

    /// `JSONSchemaValue.init(from:)` decodes whole-number JSON literals as
    /// `.integer(Int64)` (it tries Int64 before Double). Before the fix, the
    /// six numeric-constraint sites all matched only `.number`, so a schema
    /// decoded via `JSONDecoder` from JSON like `{"minimum":5}` silently
    /// ignored the bound and returned nil even for values that violated it.
    ///
    /// This test decodes the schema via `JSONDecoder` (not via `lift()`) to
    /// exercise the `.integer` decode path. It asserts that each bound is
    /// actually enforced.
    ///
    // SABOTAGE NOTE (removed before commit): reverting `numericConstraint` to
    // only match `.case .number(let n)` makes every assertion below fail because
    // `JSONDecoder` produces `.integer` for these whole-number literals and the
    // old pattern never matched.
    func test_numericConstraints_enforcedWhenDecodedViaJSONDecoder() throws {
        // Decode the schema through JSONDecoder so that whole-number literals
        // produce .integer(Int64), not .number(Double).
        let schemaJSON = #"""
        {
          "type": "object",
          "properties": {
            "n": { "type": "integer", "minimum": 5 },
            "s": { "type": "string", "minLength": 3 },
            "a": { "type": "array", "minItems": 2 }
          }
        }
        """#
        let schema = try JSONDecoder().decode(JSONSchemaValue.self, from: Data(schemaJSON.utf8))

        // n:1 violates minimum:5
        let nFailure = validator.validate(json(#"{"n":1}"#), against: schema)
        XCTAssertNotNil(nFailure, "minimum:5 decoded as .integer must be enforced; n=1 should fail")
        XCTAssertTrue(
            nFailure?.modelReadableMessage.contains(">=") ?? false,
            "minimum failure message should contain '>='; got: \(nFailure?.modelReadableMessage ?? "nil")"
        )

        // s:"a" violates minLength:3
        let sFailure = validator.validate(json(#"{"s":"a"}"#), against: schema)
        XCTAssertNotNil(sFailure, "minLength:3 decoded as .integer must be enforced; s=\"a\" should fail")
        XCTAssertTrue(
            sFailure?.modelReadableMessage.contains("characters") ?? false,
            "minLength failure message should contain 'characters'; got: \(sFailure?.modelReadableMessage ?? "nil")"
        )

        // a:[] violates minItems:2
        let aFailure = validator.validate(json("{}"), against: schema)
        _ = aFailure  // object with no 'a' key is valid (not required); test the array directly
        let aDirectSchema = try JSONDecoder().decode(
            JSONSchemaValue.self,
            from: Data(#"{"type":"array","minItems":2}"#.utf8)
        )
        let aDirectFailure = validator.validate(json("[]"), against: aDirectSchema)
        XCTAssertNotNil(aDirectFailure, "minItems:2 decoded as .integer must be enforced; [] should fail")
        XCTAssertTrue(
            aDirectFailure?.modelReadableMessage.contains("items") ?? false,
            "minItems failure message should contain 'items'; got: \(aDirectFailure?.modelReadableMessage ?? "nil")"
        )
    }

    /// Companion to the minimum-side test above: verifies that the upper-bound
    /// constraints (maximum, maxLength, maxItems) also work when decoded via
    /// `JSONDecoder` and the literal is stored as `.integer(Int64)`.
    func test_maxNumericConstraints_enforcedWhenDecodedViaJSONDecoder() throws {
        // maximum: value 10 violates maximum:5
        let numSchema = try JSONDecoder().decode(
            JSONSchemaValue.self,
            from: Data(#"{"type":"number","maximum":5}"#.utf8)
        )
        let maxFailure = validator.validate(json("10"), against: numSchema)
        XCTAssertNotNil(maxFailure, "maximum:5 decoded as .integer must be enforced; 10 should fail")
        XCTAssertTrue(
            maxFailure?.modelReadableMessage.contains("<=") ?? false,
            "maximum failure message should contain '<='; got: \(maxFailure?.modelReadableMessage ?? "nil")"
        )

        // maxLength: "toolong" (7 chars) violates maxLength:4
        let strSchema = try JSONDecoder().decode(
            JSONSchemaValue.self,
            from: Data(#"{"type":"string","maxLength":4}"#.utf8)
        )
        let maxLenFailure = validator.validate(json(#""toolong""#), against: strSchema)
        XCTAssertNotNil(maxLenFailure, "maxLength:4 decoded as .integer must be enforced; 'toolong' should fail")
        XCTAssertTrue(
            maxLenFailure?.modelReadableMessage.contains("characters") ?? false,
            "maxLength failure message should contain 'characters'; got: \(maxLenFailure?.modelReadableMessage ?? "nil")"
        )

        // maxItems: [1,2,3] (3 items) violates maxItems:2
        let arrSchema = try JSONDecoder().decode(
            JSONSchemaValue.self,
            from: Data(#"{"type":"array","maxItems":2}"#.utf8)
        )
        let maxItemsFailure = validator.validate(json("[1,2,3]"), against: arrSchema)
        XCTAssertNotNil(maxItemsFailure, "maxItems:2 decoded as .integer must be enforced; [1,2,3] should fail")
        XCTAssertTrue(
            maxItemsFailure?.modelReadableMessage.contains("items") ?? false,
            "maxItems failure message should contain 'items'; got: \(maxItemsFailure?.modelReadableMessage ?? "nil")"
        )
    }
}
