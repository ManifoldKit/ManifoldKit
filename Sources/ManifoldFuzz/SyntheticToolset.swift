import Foundation
import ManifoldInference

/// Known-answer tool fixtures injected by the `--tools` flag.
///
/// Two tools with non-trivial JSON Schemas — covers the four shapes the validator
/// guards (object-required, enum, integer-bounds, additionalProperties: false). The
/// shapes deliberately avoid features the in-tree `JSONSchemaValidator` rejects
/// (`anyOf`, `pattern`, `$ref`, etc.) so a clean tool call validates cleanly and
/// any failure traces back to a real backend bug rather than schema-feature gaps.
public enum SyntheticToolset {

    /// Definitions surfaced via `GenerationConfig.tools`.
    public static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: "get_weather",
            description: "Returns current weather for a city.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "city": .object([
                        "type": .string("string"),
                        "minLength": .number(1),
                        "maxLength": .number(64),
                    ]),
                    "units": .object([
                        "type": .string("string"),
                        "enum": .array([.string("metric"), .string("imperial")]),
                    ]),
                ]),
                "required": .array([.string("city")]),
                "additionalProperties": .bool(false),
            ])
        ),
        ToolDefinition(
            name: "schedule_alarm",
            description: "Schedules an alarm at the given time.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "label": .object([
                        "type": .string("string"),
                        "minLength": .number(1),
                    ]),
                    "minutes_from_now": .object([
                        "type": .string("integer"),
                        "minimum": .number(0),
                        "maximum": .number(1440),
                    ]),
                ]),
                "required": .array([.string("label"), .string("minutes_from_now")]),
                "additionalProperties": .bool(false),
            ])
        ),
    ]
}
