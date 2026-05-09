#if Macros
import Foundation

// MARK: - @ToolSchema

/// Synthesises `static var jsonSchema: JSONSchemaValue` on a `Decodable` struct
/// by reflecting its stored properties — removing the single biggest friction
/// point in tool-calling adoption.
///
/// ## Before
///
/// ```swift
/// struct WeatherArguments: Decodable, Sendable {
///     let city: String
///     let units: String
/// }
///
/// let tool = ToolDefinition(
///     name: "get_weather",
///     description: "Returns weather for a city.",
///     parameters: .object([
///         "type": .string("object"),
///         "properties": .object([
///             "city": .object([
///                 "type": .string("string"),
///                 "description": .string("City name")
///             ]),
///             "units": .object([
///                 "type": .string("string"),
///                 "enum": .array([.string("metric"), .string("imperial")])
///             ])
///         ]),
///         "required": .array([.string("city"), .string("units")])
///     ])
/// )
/// ```
///
/// ## After
///
/// ```swift
/// @ToolSchema
/// enum Units: String, Decodable, CaseIterable, Sendable {
///     case metric, imperial
/// }
///
/// @ToolSchema
/// struct WeatherArguments: Decodable, Sendable {
///     /// City name (e.g. "San Francisco")
///     let city: String
///     /// Unit system
///     let units: Units
/// }
///
/// let tool = ToolDefinition(
///     name: "get_weather",
///     description: "Returns weather for a city.",
///     parameters: WeatherArguments.jsonSchema
/// )
/// ```
///
/// The macro plugs directly into ``TypedToolExecutor``:
///
/// ```swift
/// let executor = TypedToolExecutor<WeatherArguments, WeatherResult>(
///     definition: ToolDefinition(
///         name: "get_weather",
///         description: "Returns weather for a city.",
///         parameters: WeatherArguments.jsonSchema
///     ),
///     handler: { args in WeatherResult(summary: "Sunny", celsius: 22.0) }
/// )
/// ```
///
/// ## Field-type mapping
///
/// | Swift                            | JSON Schema                                 |
/// |----------------------------------|---------------------------------------------|
/// | `String`                         | `{"type":"string"}`                         |
/// | `Int`, `Int32`, `Int64`          | `{"type":"integer"}`                        |
/// | `Double`, `Float`                | `{"type":"number"}`                         |
/// | `Bool`                           | `{"type":"boolean"}`                        |
/// | `[T]`                            | `{"type":"array","items":<T>}`              |
/// | `T?`                             | same as `T`, but not in `required`          |
/// | Default value `= x`              | adds `"default": <x>` (not in `required`)   |
/// | Nested `@ToolSchema` struct      | references `T.jsonSchema`                   |
/// | `@ToolSchema enum T: String`     | `{"type":"string","enum":[...cases...]}`    |
///
/// Doc comments on a field (`///`) become the field's `"description"`.
///
/// ## Limits
///
/// The macro intentionally implements a conservative JSON Schema subset:
///
/// - **No `anyOf` / union types.** Union-shaped arguments aren't well-supported
///   across inference providers; tool arguments are usually single-shape.
/// - **No constrained strings.** No `pattern`/`format`/`minLength`/`maxLength`.
///   Validate constraints at the handler level.
/// - **No nullable unions.** Use `T?` for optional — the field is simply absent
///   when not provided. Explicit `null` values in JSON are not accepted.
/// - **No tuples, closures, or `Any`-typed fields** — the macro emits a
///   compile-time diagnostic for these.
///
/// Attach via:
///
/// ```swift
/// @attached(member, names: named(jsonSchema))
/// ```
///
/// The macro is a `MemberMacro` — it adds a new member (the static
/// `jsonSchema` property) without modifying any existing declarations.
@attached(member, names: named(jsonSchema))
public macro ToolSchema() = #externalMacro(module: "ManifoldMacrosPlugin", type: "ToolSchemaMacro")
#endif
