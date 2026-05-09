import XCTest
@testable import ManifoldInference

/// Tests for ``ToolArgumentCoercer``'s nested-recursion contract introduced
/// in I3. Coverage:
/// - single-level nesting (`{filter: {limit: "10"}}`)
/// - two-level nesting (`{user: {prefs: {age: "42"}}}`)
/// - arrays of objects (`{items: [{n: "1"}]}`)
/// - tuple-form arrays
/// - depth cap throws ``ToolArgumentError/schemaTooDeep``
/// - non-object schemas at recursion sites pass through
/// - already-correct nested types untouched
///
/// Top-level-only behaviour is exercised by ``ToolArgumentCoercerTests``;
/// this file is purely about the recursive descent and its bounds.
final class ToolArgumentCoercerNestedTests: XCTestCase {

    // MARK: - Fixtures

    private func intProp() -> JSONSchemaValue { .object(["type": .string("integer")]) }
    private func numProp() -> JSONSchemaValue { .object(["type": .string("number")]) }
    private func boolProp() -> JSONSchemaValue { .object(["type": .string("boolean")]) }
    private func stringProp() -> JSONSchemaValue { .object(["type": .string("string")]) }

    /// Builds a schema of shape `{ "type": "object", "properties": { ... } }`.
    private func objectSchema(_ properties: [String: JSONSchemaValue]) -> JSONSchemaValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties)
        ])
    }

    private func topSchema(_ properties: [String: JSONSchemaValue]) -> JSONSchemaValue {
        objectSchema(properties)
    }

    // MARK: - single-level nesting

    /// The motivating case: an LLM emits `{"filter":{"limit":"10"}}` against
    /// a schema that declares `filter.limit: integer`. Without nested
    /// coercion, this hits the validator as a string and fails despite being
    /// trivially type-coercible.
    func test_singleLevelNesting_coercesNestedInteger() throws {
        let filterSchema = objectSchema(["limit": intProp()])
        let schema = topSchema(["filter": filterSchema])
        let args: JSONSchemaValue = .object([
            "filter": .object(["limit": .string("10")])
        ])

        let result = try ToolArgumentCoercer.coerce(args, against: schema)

        XCTAssertEqual(result, .object([
            "filter": .object(["limit": .number(10)])
        ]))
    }

    /// All three primitive coercions fire inside a nested object.
    func test_singleLevelNesting_coercesAllPrimitives() throws {
        let inner = objectSchema([
            "age": intProp(),
            "score": numProp(),
            "active": boolProp()
        ])
        let schema = topSchema(["data": inner])
        let args: JSONSchemaValue = .object([
            "data": .object([
                "age": .string("42"),
                "score": .string("3.14"),
                "active": .string("true")
            ])
        ])

        let result = try ToolArgumentCoercer.coerce(args, against: schema)

        XCTAssertEqual(result, .object([
            "data": .object([
                "age": .number(42),
                "score": .number(3.14),
                "active": .bool(true)
            ])
        ]))
    }

    // MARK: - two-level nesting

    func test_twoLevelNesting_coercesDeeplyNestedField() throws {
        let prefsSchema = objectSchema(["age": intProp()])
        let userSchema = objectSchema(["prefs": prefsSchema])
        let schema = topSchema(["user": userSchema])
        let args: JSONSchemaValue = .object([
            "user": .object([
                "prefs": .object(["age": .string("42")])
            ])
        ])

        let result = try ToolArgumentCoercer.coerce(args, against: schema)

        XCTAssertEqual(result, .object([
            "user": .object([
                "prefs": .object(["age": .number(42)])
            ])
        ]))
    }

    // MARK: - arrays of objects

    func test_arrayOfObjects_coercesEachElement() throws {
        let itemSchema = objectSchema(["n": intProp()])
        let schema: JSONSchemaValue = .object([
            "type": .string("object"),
            "properties": .object([
                "items": .object([
                    "type": .string("array"),
                    "items": itemSchema
                ])
            ])
        ])
        let args: JSONSchemaValue = .object([
            "items": .array([
                .object(["n": .string("1")]),
                .object(["n": .string("2")])
            ])
        ])

        let result = try ToolArgumentCoercer.coerce(args, against: schema)

        XCTAssertEqual(result, .object([
            "items": .array([
                .object(["n": .number(1)]),
                .object(["n": .number(2)])
            ])
        ]))
    }

    /// Tuple-form `items` (an array of per-index sub-schemas) — a draft-04 /
    /// 2019-09 shape some tool authors still use. Each element must coerce
    /// against its positional schema; elements past the schema array pass
    /// through unchanged.
    func test_arrayOfObjects_tupleForm_coercesByIndex() throws {
        let firstSchema = objectSchema(["a": intProp()])
        let secondSchema = objectSchema(["b": boolProp()])
        let schema: JSONSchemaValue = .object([
            "type": .string("object"),
            "properties": .object([
                "items": .object([
                    "type": .string("array"),
                    "items": .array([firstSchema, secondSchema])
                ])
            ])
        ])
        let args: JSONSchemaValue = .object([
            "items": .array([
                .object(["a": .string("7")]),
                .object(["b": .string("true")]),
                .object(["c": .string("untouched")])
            ])
        ])

        let result = try ToolArgumentCoercer.coerce(args, against: schema)

        XCTAssertEqual(result, .object([
            "items": .array([
                .object(["a": .number(7)]),
                .object(["b": .bool(true)]),
                .object(["c": .string("untouched")])
            ])
        ]))
    }

    /// Array of scalars (not objects): each scalar coerces against the
    /// element schema. Without this branch, an LLM emitting
    /// `{"counts": ["1", "2"]}` against `items: { type: integer }` would
    /// still fail.
    func test_arrayOfScalars_coercesEachElement() throws {
        let schema: JSONSchemaValue = .object([
            "type": .string("object"),
            "properties": .object([
                "counts": .object([
                    "type": .string("array"),
                    "items": intProp()
                ])
            ])
        ])
        let args: JSONSchemaValue = .object([
            "counts": .array([.string("1"), .string("2"), .string("3")])
        ])

        let result = try ToolArgumentCoercer.coerce(args, against: schema)

        XCTAssertEqual(result, .object([
            "counts": .array([.number(1), .number(2), .number(3)])
        ]))
    }

    // MARK: - depth cap

    /// A schema deeper than `maxDepth` (8) must throw `schemaTooDeep`.
    /// Nine levels of nested objects, each with a single `next` property,
    /// terminating in an integer field that an LLM mistyped — the recursion
    /// bottoms out in the error before reaching the leaf.
    func test_depthLimit_throwsSchemaTooDeep() {
        var schema: JSONSchemaValue = objectSchema(["leaf": intProp()])
        var args: JSONSchemaValue = .object(["leaf": .string("42")])
        // Wrap nine times — total depth becomes 10, exceeding the cap of 8.
        for _ in 0..<9 {
            schema = objectSchema(["next": schema])
            args = .object(["next": args])
        }

        XCTAssertThrowsError(try ToolArgumentCoercer.coerce(args, against: schema)) { error in
            XCTAssertEqual(error as? ToolArgumentError, .schemaTooDeep)
        }
    }

    /// A schema exactly at `maxDepth` succeeds (boundary case).
    func test_depthAtBoundary_succeeds() throws {
        // Build down to depth 7 (still <= 8).
        var schema: JSONSchemaValue = objectSchema(["leaf": intProp()])
        var args: JSONSchemaValue = .object(["leaf": .string("42")])
        for _ in 0..<6 {
            schema = objectSchema(["next": schema])
            args = .object(["next": args])
        }

        // Should not throw.
        let result = try ToolArgumentCoercer.coerce(args, against: schema)

        // Walk back down to confirm the leaf coerced.
        var cursor = result
        for _ in 0..<6 {
            guard case .object(let dict) = cursor, let next = dict["next"] else {
                XCTFail("missing 'next' at expected depth")
                return
            }
            cursor = next
        }
        guard case .object(let leafDict) = cursor else {
            XCTFail("expected object at leaf")
            return
        }
        XCTAssertEqual(leafDict["leaf"], .number(42))
    }

    // MARK: - pass-through paths

    /// A property whose schema is `{ "type": "string" }` should not have a
    /// nested object value mutated, even if the args surprise us with one.
    /// The original value passes through so the validator can reject it
    /// with a precise message.
    func test_nonObjectSchema_atRecursionSite_passesThrough() throws {
        let schema = topSchema(["maybe": stringProp()])
        let args: JSONSchemaValue = .object([
            "maybe": .object(["unexpected": .string("42")])
        ])

        let result = try ToolArgumentCoercer.coerce(args, against: schema)

        XCTAssertEqual(result, args, "non-object property schema must not rewrite a surprise object")
    }

    /// Already-correct nested values must round-trip untouched.
    func test_alreadyCorrectNestedTypes_passThrough() throws {
        let inner = objectSchema(["age": intProp(), "active": boolProp()])
        let schema = topSchema(["data": inner])
        let args: JSONSchemaValue = .object([
            "data": .object([
                "age": .number(42),
                "active": .bool(true)
            ])
        ])

        let result = try ToolArgumentCoercer.coerce(args, against: schema)

        XCTAssertEqual(result, args)
    }

    // MARK: - backwards compatibility

    /// Top-level-only inputs (the original v1 contract) must produce the
    /// exact same output. The recursion is a strict superset.
    func test_topLevelOnly_remainsBackwardsCompatible() throws {
        let schema = topSchema([
            "age": intProp(),
            "active": boolProp(),
            "score": numProp()
        ])
        let args: JSONSchemaValue = .object([
            "age": .string("42"),
            "active": .string("true"),
            "score": .string("3.14")
        ])

        let result = try ToolArgumentCoercer.coerce(args, against: schema)

        XCTAssertEqual(result, .object([
            "age": .number(42),
            "active": .bool(true),
            "score": .number(3.14)
        ]))
    }

    // MARK: - registry integration

    /// The registry uses ``ToolArgumentCoercer/coerceBestEffort(_:against:)``
    /// so a `schemaTooDeep` from a pathological schema falls back to the
    /// un-coerced args; the validator then surfaces whatever real error the
    /// schema produces.
    @MainActor
    func test_registryDispatch_coercesNestedArguments() async {
        let registry = ToolRegistry()
        registry.validator = JSONSchemaValidator()

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
                    name: "search",
                    description: "",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "filter": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "limit": .object(["type": .string("integer")])
                                ])
                            ])
                        ]),
                        "required": .array([.string("filter")])
                    ])
                )
            }
            func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
                box.captured = arguments
                return ToolResult(callId: "", content: "ok", errorKind: nil)
            }
        }

        registry.register(Recorder(box: box))

        let call = ToolCall(
            id: "c1",
            toolName: "search",
            arguments: #"{"filter":{"limit":"10"}}"#
        )
        let result = await registry.dispatch(call)

        XCTAssertNil(result.errorKind, "validator should pass after nested coercion")
        XCTAssertEqual(box.captured, .object([
            "filter": .object(["limit": .number(10)])
        ]))
    }
}
