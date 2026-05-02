#if Macros
import XCTest
import SwiftSyntax
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
@testable import BaseChatMacrosPlugin

// MARK: - ToolSchemaMacroTests
//
// Pure syntax-level expansion tests for @ToolSchema. These run inside the
// standard BaseChatInferenceTests suite (CI-eligible, no default-traits
// required) so they can't silently rot.
//
// Runtime integration (decode JSON through TypedToolExecutor, etc.) lives
// in `ToolSchemaMacroIntegrationTests.swift`.
//
// The macro emits the synthesised property on a single logical line so the
// output is stable across attachment sites — Swift's macro framework
// reflows embedded newlines based on parent indentation, which would make
// multi-line `expandedSource` comparisons fragile. The parser does format
// the outer `{ ... }` braces onto multiple lines, so expected source
// matches that shape.

final class ToolSchemaMacroTests: XCTestCase {

    private let testMacros: [String: Macro.Type] = [
        "ToolSchema": ToolSchemaMacro.self,
    ]

    // MARK: Primitives

    func testPrimitiveFieldsExpandWithTypeMap() {
        assertMacroExpansion(
            """
            @ToolSchema
            struct A {
                let name: String
                let age: Int
                let ratio: Double
                let active: Bool
            }
            """,
            expandedSource: """
            struct A {
                let name: String
                let age: Int
                let ratio: Double
                let active: Bool

                public static var jsonSchema: BaseChatInference.JSONSchemaValue {
                    BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("object"), "properties": BaseChatInference.JSONSchemaValue.object(["name": BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("string")]), "age": BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("integer")]), "ratio": BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("number")]), "active": BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("boolean")])]), "required": BaseChatInference.JSONSchemaValue.array([BaseChatInference.JSONSchemaValue.string("name"), BaseChatInference.JSONSchemaValue.string("age"), BaseChatInference.JSONSchemaValue.string("ratio"), BaseChatInference.JSONSchemaValue.string("active")])])
                }
            }
            """,
            macros: testMacros
        )
    }

    // MARK: Optional fields

    func testOptionalFieldOmittedFromRequired() {
        assertMacroExpansion(
            """
            @ToolSchema
            struct B {
                let city: String
                let zip: String?
            }
            """,
            expandedSource: """
            struct B {
                let city: String
                let zip: String?

                public static var jsonSchema: BaseChatInference.JSONSchemaValue {
                    BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("object"), "properties": BaseChatInference.JSONSchemaValue.object(["city": BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("string")]), "zip": BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("string")])]), "required": BaseChatInference.JSONSchemaValue.array([BaseChatInference.JSONSchemaValue.string("city")])])
                }
            }
            """,
            macros: testMacros
        )
    }

    // MARK: Enum (String raw type)

    func testStringEnumExpansion() {
        assertMacroExpansion(
            """
            @ToolSchema
            enum Units: String, CaseIterable, Decodable {
                case metric, imperial
            }
            """,
            expandedSource: """
            enum Units: String, CaseIterable, Decodable {
                case metric, imperial

                public static var jsonSchema: BaseChatInference.JSONSchemaValue {
                    BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("string"), "enum": BaseChatInference.JSONSchemaValue.array([BaseChatInference.JSONSchemaValue.string("metric"), BaseChatInference.JSONSchemaValue.string("imperial")])])
                }
            }
            """,
            macros: testMacros
        )
    }

    func testEnumWithExplicitRawValuesUsesRawValues() {
        assertMacroExpansion(
            """
            @ToolSchema
            enum Op: String {
                case add = "+"
                case sub = "-"
            }
            """,
            expandedSource: """
            enum Op: String {
                case add = "+"
                case sub = "-"

                public static var jsonSchema: BaseChatInference.JSONSchemaValue {
                    BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("string"), "enum": BaseChatInference.JSONSchemaValue.array([BaseChatInference.JSONSchemaValue.string("+"), BaseChatInference.JSONSchemaValue.string("-")])])
                }
            }
            """,
            macros: testMacros
        )
    }

    // MARK: Arrays

    func testArrayOfPrimitives() {
        assertMacroExpansion(
            """
            @ToolSchema
            struct C {
                let tags: [String]
            }
            """,
            expandedSource: """
            struct C {
                let tags: [String]

                public static var jsonSchema: BaseChatInference.JSONSchemaValue {
                    BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("object"), "properties": BaseChatInference.JSONSchemaValue.object(["tags": BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("array"), "items": BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("string")])])]), "required": BaseChatInference.JSONSchemaValue.array([BaseChatInference.JSONSchemaValue.string("tags")])])
                }
            }
            """,
            macros: testMacros
        )
    }

    // MARK: Nested struct reference

    func testNestedSchemaStructReference() {
        assertMacroExpansion(
            """
            @ToolSchema
            struct D {
                let origin: Location
            }
            """,
            expandedSource: """
            struct D {
                let origin: Location

                public static var jsonSchema: BaseChatInference.JSONSchemaValue {
                    BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("object"), "properties": BaseChatInference.JSONSchemaValue.object(["origin": Location.jsonSchema]), "required": BaseChatInference.JSONSchemaValue.array([BaseChatInference.JSONSchemaValue.string("origin")])])
                }
            }
            """,
            macros: testMacros
        )
    }

    // MARK: Default values

    func testDefaultValueEmitsDefaultAndRemovesFromRequired() {
        assertMacroExpansion(
            """
            @ToolSchema
            struct E {
                let city: String
                let limit: Int = 10
                let verbose: Bool = false
            }
            """,
            expandedSource: """
            struct E {
                let city: String
                let limit: Int = 10
                let verbose: Bool = false

                public static var jsonSchema: BaseChatInference.JSONSchemaValue {
                    BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("object"), "properties": BaseChatInference.JSONSchemaValue.object(["city": BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("string")]), "limit": BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("integer"), "default": BaseChatInference.JSONSchemaValue.number(10)]), "verbose": BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("boolean"), "default": BaseChatInference.JSONSchemaValue.bool(false)])]), "required": BaseChatInference.JSONSchemaValue.array([BaseChatInference.JSONSchemaValue.string("city")])])
                }
            }
            """,
            macros: testMacros
        )
    }

    // MARK: Negative default

    func testNegativeIntegerDefault() {
        // Negative numeric literals parse as PrefixOperatorExpr("-", IntegerLiteral).
        // The macro explicitly handles this shape — guard against a regression where
        // literalSchemaValue silently drops the negation and emits a positive number.
        assertMacroExpansion(
            """
            @ToolSchema
            struct K {
                let offset: Int = -5
                let ratio: Double = -1.25
            }
            """,
            expandedSource: """
            struct K {
                let offset: Int = -5
                let ratio: Double = -1.25

                public static var jsonSchema: BaseChatInference.JSONSchemaValue {
                    BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("object"), "properties": BaseChatInference.JSONSchemaValue.object(["offset": BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("integer"), "default": BaseChatInference.JSONSchemaValue.number(-5)]), "ratio": BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("number"), "default": BaseChatInference.JSONSchemaValue.number(-1.25)])])])
                }
            }
            """,
            macros: testMacros
        )
    }

    // MARK: Enum diagnostic (non-String raw type)

    func testEnumWithoutStringRawTypeEmitsDiagnostic() {
        assertMacroExpansion(
            """
            @ToolSchema
            enum Priority: Int {
                case low = 0
                case high = 1
            }
            """,
            expandedSource: """
            enum Priority: Int {
                case low = 0
                case high = 1
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@ToolSchema on an enum requires a String raw type (e.g. `enum Foo: String { ... }`).",
                    line: 1,
                    column: 1
                )
            ],
            macros: testMacros
        )
    }

    // MARK: Multi-line doc comment

    func testMultiLineDocCommentJoinedWithSpaces() {
        assertMacroExpansion(
            #"""
            @ToolSchema
            struct L {
                /// First line of description.
                /// Second line elaborates.
                let topic: String
            }
            """#,
            expandedSource: #"""
            struct L {
                /// First line of description.
                /// Second line elaborates.
                let topic: String

                public static var jsonSchema: BaseChatInference.JSONSchemaValue {
                    BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("object"), "properties": BaseChatInference.JSONSchemaValue.object(["topic": BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("string"), "description": BaseChatInference.JSONSchemaValue.string("First line of description. Second line elaborates.")])]), "required": BaseChatInference.JSONSchemaValue.array([BaseChatInference.JSONSchemaValue.string("topic")])])
                }
            }
            """#,
            macros: testMacros
        )
    }

    // MARK: Doc comments

    func testDocCommentBecomesDescription() {
        assertMacroExpansion(
            #"""
            @ToolSchema
            struct F {
                /// City name (e.g. "San Francisco")
                let city: String
            }
            """#,
            expandedSource: #"""
            struct F {
                /// City name (e.g. "San Francisco")
                let city: String

                public static var jsonSchema: BaseChatInference.JSONSchemaValue {
                    BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("object"), "properties": BaseChatInference.JSONSchemaValue.object(["city": BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("string"), "description": BaseChatInference.JSONSchemaValue.string("City name (e.g. \"San Francisco\")")])]), "required": BaseChatInference.JSONSchemaValue.array([BaseChatInference.JSONSchemaValue.string("city")])])
                }
            }
            """#,
            macros: testMacros
        )
    }

    // MARK: Diagnostics

    func testTupleFieldEmitsDiagnostic() {
        assertMacroExpansion(
            """
            @ToolSchema
            struct G {
                let pair: (Int, Int)
            }
            """,
            expandedSource: """
            struct G {
                let pair: (Int, Int)

                public static var jsonSchema: BaseChatInference.JSONSchemaValue {
                    BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("object"), "properties": BaseChatInference.JSONSchemaValue.object(["pair": BaseChatInference.JSONSchemaValue.object([:])]), "required": BaseChatInference.JSONSchemaValue.array([BaseChatInference.JSONSchemaValue.string("pair")])])
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@ToolSchema does not support field type 'tuple'. Supported: primitives (String, Int, Double, Bool), arrays of supported types, optionals, nested @ToolSchema structs, and @ToolSchema-annotated enums.",
                    line: 3,
                    column: 5
                )
            ],
            macros: testMacros
        )
    }

    func testClosureFieldEmitsDiagnostic() {
        assertMacroExpansion(
            """
            @ToolSchema
            struct H {
                let handler: (Int) -> Void
            }
            """,
            expandedSource: """
            struct H {
                let handler: (Int) -> Void

                public static var jsonSchema: BaseChatInference.JSONSchemaValue {
                    BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("object"), "properties": BaseChatInference.JSONSchemaValue.object(["handler": BaseChatInference.JSONSchemaValue.object([:])]), "required": BaseChatInference.JSONSchemaValue.array([BaseChatInference.JSONSchemaValue.string("handler")])])
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@ToolSchema does not support field type 'closure'. Supported: primitives (String, Int, Double, Bool), arrays of supported types, optionals, nested @ToolSchema structs, and @ToolSchema-annotated enums.",
                    line: 3,
                    column: 5
                )
            ],
            macros: testMacros
        )
    }

    func testAnyFieldEmitsDiagnostic() {
        assertMacroExpansion(
            """
            @ToolSchema
            struct I {
                let blob: Any
            }
            """,
            expandedSource: """
            struct I {
                let blob: Any

                public static var jsonSchema: BaseChatInference.JSONSchemaValue {
                    BaseChatInference.JSONSchemaValue.object(["type": BaseChatInference.JSONSchemaValue.string("object"), "properties": BaseChatInference.JSONSchemaValue.object(["blob": BaseChatInference.JSONSchemaValue.object([:])]), "required": BaseChatInference.JSONSchemaValue.array([BaseChatInference.JSONSchemaValue.string("blob")])])
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@ToolSchema does not support field type 'Any'. Supported: primitives (String, Int, Double, Bool), arrays of supported types, optionals, nested @ToolSchema structs, and @ToolSchema-annotated enums.",
                    line: 3,
                    column: 5
                )
            ],
            macros: testMacros
        )
    }

    func testAppliedToClassEmitsDiagnostic() {
        assertMacroExpansion(
            """
            @ToolSchema
            class J {
                let x: Int = 0
            }
            """,
            expandedSource: """
            class J {
                let x: Int = 0
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@ToolSchema can only be applied to a struct or a String-raw-type enum.",
                    line: 1,
                    column: 1
                )
            ],
            macros: testMacros
        )
    }
}
#endif
