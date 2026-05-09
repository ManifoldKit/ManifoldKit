import XCTest
@testable import ManifoldInference

/// Unit tests for ``GBNFSchemaPreValidator``.
///
/// These tests run without hardware — no llama.cpp symbols are touched.
final class GBNFSchemaPreValidatorTests: XCTestCase {

    private let validator = GBNFSchemaPreValidator()

    // MARK: - Safe schemas pass

    func test_simpleObjectSchema_passes() {
        let schema = JSONSchemaValue.object([
            "type": .string("object"),
            "properties": .object([
                "city": .object(["type": .string("string")]),
                "units": .object(["type": .string("string")])
            ]),
            "required": .array([.string("city")])
        ])
        XCTAssertNil(validator.validate(schema))
    }

    func test_schemaWithStringEnum_passes() {
        let schema = JSONSchemaValue.object([
            "type": .string("object"),
            "properties": .object([
                "direction": .object([
                    "type": .string("string"),
                    "enum": .array([.string("north"), .string("south")])
                ])
            ])
        ])
        XCTAssertNil(validator.validate(schema))
    }

    func test_schemaWithArrayItems_passes() {
        let schema = JSONSchemaValue.object([
            "type": .string("array"),
            "items": .object(["type": .string("string")])
        ])
        XCTAssertNil(validator.validate(schema))
    }

    func test_emptyObjectSchema_passes() {
        XCTAssertNil(validator.validate(.object([:])))
    }

    func test_nonObjectSchema_passes() {
        // Scalar values at the top level are not GBNF-unsafe.
        XCTAssertNil(validator.validate(.string("string")))
        XCTAssertNil(validator.validate(.number(42)))
        XCTAssertNil(validator.validate(.bool(true)))
        XCTAssertNil(validator.validate(.null))
    }

    // MARK: - Combiners rejected

    func test_anyOf_isRejected() {
        let schema = JSONSchemaValue.object([
            "anyOf": .array([
                .object(["type": .string("string")]),
                .object(["type": .string("integer")])
            ])
        ])
        let failure = validator.validate(schema)
        XCTAssertNotNil(failure)
        XCTAssertEqual(failure?.path, ["anyOf"])
        XCTAssertTrue(failure?.reason.contains("anyOf") == true)
    }

    func test_oneOf_isRejected() {
        let schema = JSONSchemaValue.object([
            "oneOf": .array([.object(["type": .string("string")])])
        ])
        XCTAssertNotNil(validator.validate(schema))
    }

    func test_allOf_isRejected() {
        let schema = JSONSchemaValue.object([
            "allOf": .array([.object(["type": .string("string")])])
        ])
        XCTAssertNotNil(validator.validate(schema))
    }

    func test_not_isRejected() {
        let schema = JSONSchemaValue.object([
            "not": .object(["type": .string("string")])
        ])
        XCTAssertNotNil(validator.validate(schema))
    }

    // MARK: - Nullable union rejected

    func test_nullableUnionType_isRejected() {
        let schema = JSONSchemaValue.object([
            "type": .array([.string("string"), .string("null")])
        ])
        let failure = validator.validate(schema)
        XCTAssertNotNil(failure)
        XCTAssertEqual(failure?.path, ["type"])
        XCTAssertTrue(failure?.reason.lowercased().contains("null") == true)
    }

    func test_nonNullableArrayType_passes() {
        // An array `type` that does NOT contain "null" is safe.
        let schema = JSONSchemaValue.object([
            "type": .array([.string("string"), .string("integer")])
        ])
        XCTAssertNil(validator.validate(schema))
    }

    // MARK: - exclusiveMinimum / exclusiveMaximum rejected

    func test_exclusiveMinimum_isRejected() {
        let schema = JSONSchemaValue.object([
            "type": .string("integer"),
            "exclusiveMinimum": .number(0)
        ])
        let failure = validator.validate(schema)
        XCTAssertNotNil(failure)
        XCTAssertEqual(failure?.path, ["exclusiveMinimum"])
    }

    func test_exclusiveMaximum_isRejected() {
        let schema = JSONSchemaValue.object([
            "type": .string("integer"),
            "exclusiveMaximum": .number(100)
        ])
        let failure = validator.validate(schema)
        XCTAssertNotNil(failure)
        XCTAssertEqual(failure?.path, ["exclusiveMaximum"])
    }

    // MARK: - Nested rejection (recursive)

    func test_nestedAnyOf_inProperties_isRejected() {
        let schema = JSONSchemaValue.object([
            "type": .string("object"),
            "properties": .object([
                "address": .object([
                    "anyOf": .array([
                        .object(["type": .string("string")]),
                        .object(["type": .string("null")])
                    ])
                ])
            ])
        ])
        let failure = validator.validate(schema)
        XCTAssertNotNil(failure)
        XCTAssertEqual(failure?.path, ["properties", "address", "anyOf"])
    }

    func test_nullableUnion_inItemsSchema_isRejected() {
        let schema = JSONSchemaValue.object([
            "type": .string("array"),
            "items": .object([
                "type": .array([.string("string"), .string("null")])
            ])
        ])
        let failure = validator.validate(schema)
        XCTAssertNotNil(failure)
        XCTAssertEqual(failure?.path, ["items", "type"])
    }

    func test_anyOf_inTupleItemsArray_isRejected() {
        // `items` may be an array of schemas (tuple validation). Without the
        // array branch, an unsafe combiner inside one of the tuple entries
        // would bypass the pre-validator and reach the GBNF compiler.
        let schema = JSONSchemaValue.object([
            "type": .string("array"),
            "items": .array([
                .object(["type": .string("string")]),
                .object([
                    "anyOf": .array([
                        .object(["type": .string("integer")]),
                        .object(["type": .string("string")])
                    ])
                ])
            ])
        ])
        let failure = validator.validate(schema)
        XCTAssertNotNil(failure)
        XCTAssertEqual(failure?.path, ["items", "1", "anyOf"])
    }

    func test_safeTupleItemsArray_passes() {
        let schema = JSONSchemaValue.object([
            "type": .string("array"),
            "items": .array([
                .object(["type": .string("string")]),
                .object(["type": .string("integer")])
            ])
        ])
        XCTAssertNil(validator.validate(schema))
    }

    // MARK: - CVE audit record sanity

    func test_cveAuditRecord_isUnfixed() {
        let record = GBNFSchemaPreValidator.cveStatus
        XCTAssertEqual(record.cveID, "CVE-2026-2069")
        XCTAssertFalse(record.isFixed,
                       "Flip isFixed to true once the xcframework is bumped past b8773")
        XCTAssertEqual(record.vendoredBuild, "b8772")
        XCTAssertEqual(record.fixedAtBuild,  "b8774")
    }
}
