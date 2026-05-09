import XCTest
@testable import ManifoldInference

/// Unit tests for ``encodeJSONSchemaToFoundation(_:)``.
///
/// Covers:
/// - String, Int, Double, Bool primitives
/// - null / optional
/// - Nested object
/// - Array of mixed types
/// - Deeply nested (3 levels)
final class ToolSchemaEncoderTests: XCTestCase {

    // MARK: - Primitive: String

    func test_string_encodesAsNSString() throws {
        let result = encodeJSONSchemaToFoundation(.string("hello"))
        let str = try XCTUnwrap(result as? String)
        XCTAssertEqual(str, "hello")
    }

    // MARK: - Primitive: Integer number

    func test_integerNumber_encodesAsNSNumber() throws {
        // JSONSchemaValue uses .number(Double) for all numeric values.
        let result = encodeJSONSchemaToFoundation(.number(42))
        let num = try XCTUnwrap(result as? Double)
        XCTAssertEqual(num, 42.0, accuracy: 0.0001)
    }

    // MARK: - Primitive: Fractional number

    func test_fractionalNumber_encodesAsNSNumber() throws {
        let result = encodeJSONSchemaToFoundation(.number(3.14))
        let num = try XCTUnwrap(result as? Double)
        XCTAssertEqual(num, 3.14, accuracy: 0.0001)
    }

    // MARK: - Primitive: Bool

    func test_bool_true_encodesAsBool() throws {
        let result = encodeJSONSchemaToFoundation(.bool(true))
        let b = try XCTUnwrap(result as? Bool)
        XCTAssertTrue(b)
    }

    func test_bool_false_encodesAsBool() throws {
        let result = encodeJSONSchemaToFoundation(.bool(false))
        let b = try XCTUnwrap(result as? Bool)
        XCTAssertFalse(b)
    }

    // MARK: - Null / optional

    func test_null_encodesAsNSNull() throws {
        let result = encodeJSONSchemaToFoundation(.null)
        // JSONSerialization represents JSON null as NSNull.
        XCTAssertTrue(result is NSNull, "null must encode as NSNull, got \(type(of: result as Any))")
    }

    // MARK: - Nested object

    func test_nestedObject_encodesAsDictionary() throws {
        let value: JSONSchemaValue = .object([
            "type": .string("object"),
            "properties": .object([
                "city": .object(["type": .string("string")])
            ])
        ])

        let result = encodeJSONSchemaToFoundation(value)
        let dict = try XCTUnwrap(result as? [String: Any])

        XCTAssertEqual(dict["type"] as? String, "object",
            "Sabotage: if key 'type' is missing or wrong, this assertion catches the regression")

        let props = try XCTUnwrap(dict["properties"] as? [String: Any])
        let citySchema = try XCTUnwrap(props["city"] as? [String: Any])
        XCTAssertEqual(citySchema["type"] as? String, "string")
    }

    // MARK: - Array of mixed types

    func test_arrayOfMixedTypes_encodesAsArray() throws {
        let value: JSONSchemaValue = .array([
            .string("hello"),
            .number(1),
            .bool(true),
            .null,
        ])

        let result = encodeJSONSchemaToFoundation(value)
        let arr = try XCTUnwrap(result as? [Any])

        XCTAssertEqual(arr.count, 4)
        XCTAssertEqual(arr[0] as? String, "hello")
        let num = try XCTUnwrap(arr[1] as? Double)
        XCTAssertEqual(num, 1.0, accuracy: 0.0001)
        XCTAssertEqual(arr[2] as? Bool, true)
        XCTAssertTrue(arr[3] is NSNull)
    }

    // MARK: - Deeply nested (3 levels)

    func test_deeplyNested_3Levels_encodesCorrectly() throws {
        let value: JSONSchemaValue = .object([
            "level1": .object([
                "level2": .object([
                    "level3": .string("deep")
                ])
            ])
        ])

        let result = encodeJSONSchemaToFoundation(value)
        let l1 = try XCTUnwrap(result as? [String: Any])
        let l2 = try XCTUnwrap(l1["level1"] as? [String: Any])
        let l3 = try XCTUnwrap(l2["level2"] as? [String: Any])

        XCTAssertEqual(l3["level3"] as? String, "deep",
            "Sabotage: if nesting is flattened or truncated, the deeply-nested value won't be found")

        // Sabotage check: confirm the key is exactly "level3" and not something else.
        XCTAssertNil(l3["level4"], "There must be no 'level4' key — only 3 levels exist")
    }

    // MARK: - Full JSON Schema object (realistic fixture)

    func test_fullSchemaObject_roundTrips() throws {
        let schema: JSONSchemaValue = .object([
            "type": .string("object"),
            "properties": .object([
                "location": .object([
                    "type": .string("string"),
                    "description": .string("City name"),
                ]),
                "unit": .object([
                    "type": .string("string"),
                    "enum": .array([.string("celsius"), .string("fahrenheit")]),
                ]),
            ]),
            "required": .array([.string("location")]),
        ])

        let result = encodeJSONSchemaToFoundation(schema)
        let dict = try XCTUnwrap(result as? [String: Any])

        XCTAssertEqual(dict["type"] as? String, "object")

        let props = try XCTUnwrap(dict["properties"] as? [String: Any])
        XCTAssertNotNil(props["location"])
        XCTAssertNotNil(props["unit"])

        let required = try XCTUnwrap(dict["required"] as? [String])
        XCTAssertEqual(required, ["location"])
    }
}
