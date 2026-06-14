import XCTest
@testable import ManifoldInference

/// Unit tests for ``GBNFSchemaPreValidator``.
///
/// These tests run without hardware — no llama.cpp symbols are touched.
///
/// ## #1859 behavior change (advisory, not a gate)
///
/// The validator's role shifted from "reject the tool" to "flag sub-schema
/// shapes the lowerer can't express (they degrade to generic JSON)." Two
/// previously-rejected shapes are now *accepted* because the lowerer handles or
/// safely ignores them:
///   - **nullable union** `["T","null"]` → lowered to `( <T> | "null" )`.
///   - **`exclusiveMinimum`/`exclusiveMaximum`** → bound ignored, generic number.
/// Combiners (`anyOf`/`oneOf`/`allOf`/`not`) are still flagged (the lowerer
/// doesn't implement them yet — they fall back to generic JSON, the tool is
/// NOT dropped). `$ref`/`patternProperties` are newly flagged for the same
/// reason. The tests below were updated accordingly.
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

    // MARK: - Combiners flagged (un-lowerable → generic-JSON fallback)

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

    // MARK: - Nullable union now ACCEPTED (#1859)

    // Behavior change: the lowerer expresses `["T","null"]` as `( <T> | "null" )`,
    // so a nullable union is no longer flagged.
    func test_nullableUnionType_nowPasses() {
        let schema = JSONSchemaValue.object([
            "type": .array([.string("string"), .string("null")])
        ])
        XCTAssertNil(validator.validate(schema))
    }

    func test_nonNullableArrayType_passes() {
        // An array `type` that does NOT contain "null" is also fine.
        let schema = JSONSchemaValue.object([
            "type": .array([.string("string"), .string("integer")])
        ])
        XCTAssertNil(validator.validate(schema))
    }

    // MARK: - exclusiveMinimum / exclusiveMaximum now ACCEPTED (#1859)

    // Behavior change: GBNF can't enforce arbitrary numeric ranges anyway, so the
    // lowerer ignores the bound and emits a generic number. Ignoring a bound
    // beats dropping the tool, so these are no longer flagged.
    func test_exclusiveMinimum_nowPasses() {
        let schema = JSONSchemaValue.object([
            "type": .string("integer"),
            "exclusiveMinimum": .number(0)
        ])
        XCTAssertNil(validator.validate(schema))
    }

    func test_exclusiveMaximum_nowPasses() {
        let schema = JSONSchemaValue.object([
            "type": .string("integer"),
            "exclusiveMaximum": .number(100)
        ])
        XCTAssertNil(validator.validate(schema))
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

    // Behavior change (#1859): a nullable union nested in `items` is no longer
    // flagged — the lowerer expresses it.
    func test_nullableUnion_inItemsSchema_nowPasses() {
        let schema = JSONSchemaValue.object([
            "type": .string("array"),
            "items": .object([
                "type": .array([.string("string"), .string("null")])
            ])
        ])
        XCTAssertNil(validator.validate(schema))
    }

    // `$ref` and `patternProperties` are newly flagged (un-lowerable → generic).
    func test_ref_isFlagged() {
        let schema = JSONSchemaValue.object(["$ref": .string("#/defs/X")])
        let failure = validator.validate(schema)
        XCTAssertNotNil(failure)
        XCTAssertEqual(failure?.path, ["$ref"])
    }

    func test_patternProperties_isFlagged() {
        let schema = JSONSchemaValue.object([
            "type": .string("object"),
            "patternProperties": .object(["^x": .object(["type": .string("string")])])
        ])
        let failure = validator.validate(schema)
        XCTAssertNotNil(failure)
        XCTAssertEqual(failure?.path, ["patternProperties"])
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

    func test_cveAuditRecord_matchesVendoredPin() {
        let record = GBNFSchemaPreValidator.cveStatus
        XCTAssertEqual(record.cveID, "CVE-2026-2069")
        XCTAssertTrue(record.isFixed,
                      "Vendored build is past the b8774 fix; if the pin moves back, flip this and re-audit the validator rules.")
        XCTAssertEqual(record.vendoredBuild, "b9101",
                       "Bump vendoredBuild whenever mattt/llama.swift is repinned — derive the build tag from the resolved Package.swift's `url:` line.")
        XCTAssertEqual(record.fixedAtBuild,  "b8774")
    }
}
