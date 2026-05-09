#if Macros
import XCTest
import Foundation
@testable import ManifoldInference

// MARK: - ToolSchemaMacroIntegrationTests
//
// Runtime integration of @ToolSchema: applies the macro to a real struct,
// feeds the synthesised `.jsonSchema` into a `ToolDefinition`, dispatches a
// fake `ToolCall` through `TypedToolExecutor`, and asserts the handler runs
// and the result encodes back to JSON.
//
// These sit in the non-trait-gated ManifoldInferenceTests target so they run
// in the standard CI suite alongside the pure expansion tests.

// MARK: Fixtures

@ToolSchema
private enum WeatherUnits: String, CaseIterable, Decodable, Sendable {
    case metric, imperial
}

@ToolSchema
private struct WeatherArgs: Decodable, Sendable {
    /// City name, e.g. "San Francisco"
    let city: String
    /// Unit system (optional, defaults to metric)
    let units: WeatherUnits?
    /// Maximum forecast days to return
    let days: Int = 3
}

private struct WeatherResult: Encodable, Sendable {
    let summary: String
    let celsius: Double
}

// MARK: Tests

final class ToolSchemaMacroIntegrationTests: XCTestCase {

    func testSynthesisedSchemaShape() throws {
        let schema = WeatherArgs.jsonSchema
        guard case .object(let root) = schema else {
            return XCTFail("expected object root")
        }
        XCTAssertEqual(root["type"], .string("object"))
        guard case .object(let properties) = root["properties"] else {
            return XCTFail("expected properties object")
        }
        // Field shapes.
        XCTAssertEqual(
            properties["city"],
            .object([
                "type": .string("string"),
                "description": .string("City name, e.g. \"San Francisco\"")
            ])
        )
        // Optional: `units` references WeatherUnits.jsonSchema, which is a
        // string-enum object. The per-field `description` is NOT attached
        // because nested schema types' own keys take precedence — this is
        // the documented limit.
        XCTAssertEqual(
            properties["units"],
            .object([
                "type": .string("string"),
                "enum": .array([.string("metric"), .string("imperial")])
            ])
        )
        // Default value present, not in required.
        XCTAssertEqual(
            properties["days"],
            .object([
                "type": .string("integer"),
                "description": .string("Maximum forecast days to return"),
                "default": .number(3)
            ])
        )
        // Required: only `city`. `units` is Optional, `days` has a default.
        XCTAssertEqual(root["required"], .array([.string("city")]))
    }

    func testRoundTripThroughTypedToolExecutor() async throws {
        let definition = ToolDefinition(
            name: "get_weather",
            description: "Returns weather for a city.",
            parameters: WeatherArgs.jsonSchema
        )
        let executor = TypedToolExecutor<WeatherArgs, WeatherResult>(
            definition: definition
        ) { args in
            XCTAssertEqual(args.city, "Dublin")
            XCTAssertEqual(args.units, .metric)
            XCTAssertEqual(args.days, 3)
            return WeatherResult(summary: "Sunny in \(args.city)", celsius: 14.0)
        }

        // Build a realistic ToolCall argument payload as JSON text, then parse
        // it into a JSONSchemaValue the way ToolRegistry would at dispatch time.
        // `days` is included explicitly so synthesised Decodable is happy —
        // Swift's default-value synthesis only applies to init, not decode.
        let argsJSON = #"{"city":"Dublin","units":"metric","days":3}"#
        let argsData = Data(argsJSON.utf8)
        let parsed = try JSONDecoder().decode(JSONSchemaValue.self, from: argsData)

        let result = try await executor.execute(arguments: parsed)
        XCTAssertFalse(result.isError)
        // The TypedToolExecutor encodes the result as JSON text.
        struct DecodedResult: Decodable { let summary: String; let celsius: Double }
        let decoded = try JSONDecoder().decode(DecodedResult.self, from: Data(result.content.utf8))
        XCTAssertEqual(decoded.summary, "Sunny in Dublin")
        XCTAssertEqual(decoded.celsius, 14.0, accuracy: 0.0001)
    }

    func testOptionalFieldCanBeOmitted() async throws {
        let executor = TypedToolExecutor<WeatherArgs, WeatherResult>(
            definition: ToolDefinition(
                name: "get_weather",
                description: "",
                parameters: WeatherArgs.jsonSchema
            )
        ) { args in
            XCTAssertNil(args.units)
            return WeatherResult(summary: "ok", celsius: 0)
        }

        // Omit `units` entirely (it's Optional). `days` must be present because
        // synthesised Decodable doesn't use default values on decode.
        let argsJSON = #"{"city":"Reykjavik","days":3}"#
        let parsed = try JSONDecoder().decode(JSONSchemaValue.self, from: Data(argsJSON.utf8))
        let result = try await executor.execute(arguments: parsed)
        XCTAssertFalse(result.isError)
    }
}
#endif
