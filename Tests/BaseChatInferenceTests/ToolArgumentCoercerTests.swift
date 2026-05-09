import XCTest
@testable import BaseChatInference

/// Tests for ``ToolArgumentCoercer`` — the top-level string→primitive
/// coercion pass that runs between JSON decode and schema validation in
/// ``ToolRegistry/dispatch(_:)``.
///
/// Coverage:
/// - integer / number / boolean coercion
/// - non-coercible strings fall through unchanged
/// - already-correct types pass through untouched
/// - missing schema or missing `properties` is a no-op
/// - unknown keys (not in `properties`) are preserved
/// - top-level only — nested values are not touched
final class ToolArgumentCoercerTests: XCTestCase {

    // MARK: - Fixtures

    private func schema(_ properties: [String: JSONSchemaValue]) -> JSONSchemaValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties)
        ])
    }

    private func intProp() -> JSONSchemaValue { .object(["type": .string("integer")]) }
    private func numProp() -> JSONSchemaValue { .object(["type": .string("number")]) }
    private func boolProp() -> JSONSchemaValue { .object(["type": .string("boolean")]) }
    private func stringProp() -> JSONSchemaValue { .object(["type": .string("string")]) }

    // MARK: - integer / number

    func test_coercesStringToInteger_whenSchemaSaysInteger() {
        let s = schema(["age": intProp()])
        let args: JSONSchemaValue = .object(["age": .string("42")])

        let result = try! ToolArgumentCoercer.coerce(args, against: s)

        XCTAssertEqual(result, .object(["age": .number(42)]))
    }

    func test_coercesStringToNumber_whenSchemaSaysNumber() {
        let s = schema(["pi": numProp()])
        let args: JSONSchemaValue = .object(["pi": .string("3.14")])

        let result = try! ToolArgumentCoercer.coerce(args, against: s)

        XCTAssertEqual(result, .object(["pi": .number(3.14)]))
    }

    func test_coercesNegativeAndScientificNotation() {
        let s = schema(["x": numProp(), "y": intProp()])
        let args: JSONSchemaValue = .object([
            "x": .string("-2.5e3"),
            "y": .string("-7")
        ])

        let result = try! ToolArgumentCoercer.coerce(args, against: s)

        XCTAssertEqual(result, .object([
            "x": .number(-2500),
            "y": .number(-7)
        ]))
    }

    func test_unparseableNumber_fallsThroughAsString() {
        let s = schema(["age": intProp()])
        let args: JSONSchemaValue = .object(["age": .string("not-a-number")])

        let result = try! ToolArgumentCoercer.coerce(args, against: s)

        XCTAssertEqual(result, .object(["age": .string("not-a-number")]))
    }

    /// A fractional string against an `integer` schema must fall through
    /// unchanged so the validator surfaces "expected integer got string"
    /// rather than the misleading "expected integer got number" — and so
    /// executors that bypass validation never see a non-integer value
    /// in an `integer` field.
    func test_fractionalString_fallsThroughForIntegerSchema() {
        let s = schema(["age": intProp()])
        let args: JSONSchemaValue = .object(["age": .string("3.14")])

        let result = try! ToolArgumentCoercer.coerce(args, against: s)

        XCTAssertEqual(result, .object(["age": .string("3.14")]))
    }

    /// A fractional string against a `number` schema is still coerced —
    /// only the `integer` path is integral-only.
    func test_fractionalString_coercesForNumberSchema() {
        let s = schema(["pi": numProp()])
        let args: JSONSchemaValue = .object(["pi": .string("3.14")])

        let result = try! ToolArgumentCoercer.coerce(args, against: s)

        XCTAssertEqual(result, .object(["pi": .number(3.14)]))
    }

    // MARK: - boolean

    func test_coercesLowercaseTrueAndFalse() {
        let s = schema(["a": boolProp(), "b": boolProp()])
        let args: JSONSchemaValue = .object([
            "a": .string("true"),
            "b": .string("false")
        ])

        let result = try! ToolArgumentCoercer.coerce(args, against: s)

        XCTAssertEqual(result, .object([
            "a": .bool(true),
            "b": .bool(false)
        ]))
    }

    func test_coercesMixedCaseBooleans() {
        let s = schema(["a": boolProp(), "b": boolProp(), "c": boolProp()])
        let args: JSONSchemaValue = .object([
            "a": .string("True"),
            "b": .string("TRUE"),
            "c": .string("False")
        ])

        let result = try! ToolArgumentCoercer.coerce(args, against: s)

        XCTAssertEqual(result, .object([
            "a": .bool(true),
            "b": .bool(true),
            "c": .bool(false)
        ]))
    }

    func test_nonBooleanString_fallsThroughAsString() {
        let s = schema(["flag": boolProp(), "other": boolProp()])
        let args: JSONSchemaValue = .object([
            "flag": .string("yes"),
            "other": .string("abc")
        ])

        let result = try! ToolArgumentCoercer.coerce(args, against: s)

        XCTAssertEqual(result, .object([
            "flag": .string("yes"),
            "other": .string("abc")
        ]))
    }

    // MARK: - pass-through

    func test_alreadyCorrectTypes_passThroughUntouched() {
        let s = schema(["age": intProp(), "flag": boolProp(), "pi": numProp()])
        let args: JSONSchemaValue = .object([
            "age": .number(42),
            "flag": .bool(true),
            "pi": .number(3.14)
        ])

        let result = try! ToolArgumentCoercer.coerce(args, against: s)

        XCTAssertEqual(result, args)
    }

    func test_stringSchema_leavesStringsAlone() {
        let s = schema(["name": stringProp()])
        let args: JSONSchemaValue = .object(["name": .string("42")])

        let result = try! ToolArgumentCoercer.coerce(args, against: s)

        XCTAssertEqual(result, .object(["name": .string("42")]))
    }

    func test_missingPropertiesInSchema_returnsArgsUnchanged() {
        let s: JSONSchemaValue = .object(["type": .string("object")])
        let args: JSONSchemaValue = .object(["age": .string("42")])

        let result = try! ToolArgumentCoercer.coerce(args, against: s)

        XCTAssertEqual(result, args)
    }

    func test_emptySchema_returnsArgsUnchanged() {
        let s: JSONSchemaValue = .object([:])
        let args: JSONSchemaValue = .object(["age": .string("42")])

        let result = try! ToolArgumentCoercer.coerce(args, against: s)

        XCTAssertEqual(result, args)
    }

    func test_unknownKeyInArgs_isPreservedUnchanged() {
        let s = schema(["age": intProp()])
        let args: JSONSchemaValue = .object([
            "age": .string("42"),
            "extra": .string("hello")
        ])

        let result = try! ToolArgumentCoercer.coerce(args, against: s)

        XCTAssertEqual(result, .object([
            "age": .number(42),
            "extra": .string("hello")
        ]))
    }

    func test_nonObjectArgs_returnUnchanged() {
        let s = schema(["age": intProp()])
        let args: JSONSchemaValue = .array([.string("42")])

        let result = try! ToolArgumentCoercer.coerce(args, against: s)

        XCTAssertEqual(result, args)
    }

    // MARK: - nested recursion (I3)

    /// As of I3, the coercer recurses into nested object properties so
    /// small open-weight models that mistype nested fields (more common
    /// than mistyping top-level fields) don't fail the validator.
    func test_recursesIntoNestedObjects() throws {
        let nestedSchema: JSONSchemaValue = .object([
            "type": .string("object"),
            "properties": .object(["age": intProp()])
        ])
        let s = schema(["nested": nestedSchema])
        let args: JSONSchemaValue = .object([
            "nested": .object(["age": .string("42")])
        ])

        let result = try ToolArgumentCoercer.coerce(args, against: s)

        XCTAssertEqual(result, .object([
            "nested": .object(["age": .number(42)])
        ]))
    }

    // MARK: - registry integration

    @MainActor
    func test_registryDispatch_coercesByDefault() async {
        let registry = ToolRegistry()
        registry.validator = JSONSchemaValidator()

        struct Captured: Sendable { var value: JSONSchemaValue? }
        final class Box: @unchecked Sendable {
            var captured: JSONSchemaValue?
        }
        let box = Box()

        final class Recorder: ToolExecutor, @unchecked Sendable {
            let definition: ToolDefinition
            let box: Box
            init(box: Box) {
                self.box = box
                self.definition = ToolDefinition(
                    name: "set_age",
                    description: "",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "age": .object(["type": .string("integer")])
                        ]),
                        "required": .array([.string("age")])
                    ])
                )
            }
            func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
                box.captured = arguments
                return ToolResult(callId: "", content: "ok", errorKind: nil)
            }
        }

        registry.register(Recorder(box: box))

        let call = ToolCall(id: "c1", toolName: "set_age", arguments: #"{"age":"42"}"#)
        let result = await registry.dispatch(call)

        XCTAssertNil(result.errorKind, "schema validation should pass after coercion")
        XCTAssertEqual(box.captured, .object(["age": .number(42)]))
    }

    @MainActor
    func test_registryDispatch_skipsCoercionWhenDisabled() async {
        let registry = ToolRegistry()
        registry.validator = JSONSchemaValidator()
        registry.coercesArguments = false

        final class Recorder: ToolExecutor, @unchecked Sendable {
            let definition: ToolDefinition
            init() {
                self.definition = ToolDefinition(
                    name: "set_age",
                    description: "",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "age": .object(["type": .string("integer")])
                        ]),
                        "required": .array([.string("age")])
                    ])
                )
            }
            func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
                return ToolResult(callId: "", content: "ok", errorKind: nil)
            }
        }

        registry.register(Recorder())

        let call = ToolCall(id: "c1", toolName: "set_age", arguments: #"{"age":"42"}"#)
        let result = await registry.dispatch(call)

        XCTAssertEqual(result.errorKind, .invalidArguments,
                      "validator should reject the string when coercion is disabled")
    }
}
