import XCTest
@testable import BaseChatInference

/// Tests for the ``ToolRegistry`` dispatch surface introduced alongside the
/// ``ToolExecutor`` protocol in wave 1.
///
/// Coverage:
/// - register/contains/unregister lifecycle
/// - case-insensitive name lookup
/// - dispatch → unknown tool / invalid JSON / thrown-error / happy-path
/// - register overrides (with warning) and `definitions` sort order
@MainActor
final class ToolRegistryTests: XCTestCase {

    // MARK: - Fixtures

    private struct CityArgs: Decodable, Sendable, Equatable {
        let city: String
    }

    private struct WeatherResult: Codable, Sendable, Equatable {
        let summary: String
        let celsius: Double
    }

    private func makeWeatherExecutor(
        name: String = "get_weather"
    ) -> TypedToolExecutor<CityArgs, WeatherResult> {
        TypedToolExecutor(
            definition: ToolDefinition(
                name: name,
                description: "Returns weather for a city.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "city": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("city")])
                ])
            )
        ) { args in
            WeatherResult(summary: "Sunny in \(args.city)", celsius: 22.0)
        }
    }

    /// Minimal raw-protocol executor that records the payload it was called
    /// with. Lets us assert dispatch passes through the parsed JSONSchemaValue
    /// unchanged without routing through TypedToolExecutor.
    private final class RecordingExecutor: ToolExecutor, @unchecked Sendable {
        let definition: ToolDefinition
        var lastArguments: JSONSchemaValue?

        init(name: String) {
            self.definition = ToolDefinition(name: name, description: "record", parameters: .object([:]))
        }

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            lastArguments = arguments
            return ToolResult(callId: "", content: "ok", errorKind: nil)
        }
    }

    /// Executor that always throws. Drives the `.permanent` classification path.
    private struct ThrowingExecutor: ToolExecutor {
        struct Boom: Error, CustomStringConvertible { var description: String { "boom-message" } }
        let definition: ToolDefinition

        init(name: String) {
            self.definition = ToolDefinition(name: name, description: "throws", parameters: .object([:]))
        }

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            throw Boom()
        }
    }

    // MARK: - register / contains / unregister

    func test_register_then_containsExactName() {
        let registry = ToolRegistry()
        registry.register(makeWeatherExecutor(name: "get_weather"))
        XCTAssertTrue(registry.contains(name: "get_weather"))
    }

    func test_contains_isCaseInsensitive() {
        let registry = ToolRegistry()
        registry.register(makeWeatherExecutor(name: "GetWeather"))
        XCTAssertTrue(registry.contains(name: "getweather"))
        XCTAssertTrue(registry.contains(name: "GETWEATHER"))
    }

    func test_unregister_removesTool() async {
        let registry = ToolRegistry()
        registry.register(makeWeatherExecutor(name: "get_weather"))
        registry.unregister(name: "get_weather")
        XCTAssertFalse(registry.contains(name: "get_weather"))

        let result = await registry.dispatch(
            ToolCall(id: "call-1", toolName: "get_weather", arguments: #"{"city":"Paris"}"#)
        )
        XCTAssertEqual(result.errorKind, .unknownTool)
    }

    func test_init_withTools_registersAll() {
        let registry = ToolRegistry(tools: [
            makeWeatherExecutor(name: "alpha"),
            makeWeatherExecutor(name: "bravo")
        ])
        XCTAssertTrue(registry.contains(name: "alpha"))
        XCTAssertTrue(registry.contains(name: "bravo"))
    }

    // MARK: - definitions

    func test_definitions_returnsSortedByName() {
        let registry = ToolRegistry()
        registry.register(makeWeatherExecutor(name: "zebra"))
        registry.register(makeWeatherExecutor(name: "alpha"))
        registry.register(makeWeatherExecutor(name: "mango"))

        let names = registry.definitions.map(\.name)
        // Sabotage check: returning tools.values.map directly (no sort) makes
        // this fail because Dictionary iteration order is unstable.
        XCTAssertEqual(names, ["alpha", "mango", "zebra"])
    }

    func test_advertisedDefinitions_applyCaseInsensitiveAllowListWithoutBlockingDispatch() async {
        let registry = ToolRegistry()
        registry.register(makeWeatherExecutor(name: "mcp_alpha"))
        registry.register(makeWeatherExecutor(name: "app_status"))
        registry.register(makeWeatherExecutor(name: "mcp_zebra"))

        registry.advertisedToolNames = ["MCP_ALPHA", "app_status"]

        XCTAssertEqual(registry.advertisedDefinitions.map(\.name), ["app_status", "mcp_alpha"])
        XCTAssertEqual(registry.definitions.map(\.name), ["app_status", "mcp_alpha", "mcp_zebra"])

        let hiddenResult = await registry.dispatch(
            ToolCall(id: "call-hidden", toolName: "mcp_zebra", arguments: #"{"city":"Paris"}"#)
        )
        XCTAssertEqual(hiddenResult.errorKind, nil)
        XCTAssertTrue(hiddenResult.content.contains("Sunny in Paris"))
    }

    func test_register_override_replacesExistingTool() async {
        let registry = ToolRegistry()

        let first = TypedToolExecutor<CityArgs, WeatherResult>(
            definition: ToolDefinition(name: "get_weather", description: "v1", parameters: .object([:]))
        ) { _ in WeatherResult(summary: "v1", celsius: 1.0) }

        let second = TypedToolExecutor<CityArgs, WeatherResult>(
            definition: ToolDefinition(name: "get_weather", description: "v2", parameters: .object([:]))
        ) { _ in WeatherResult(summary: "v2", celsius: 2.0) }

        registry.register(first)
        registry.register(second)

        let result = await registry.dispatch(
            ToolCall(id: "call-o", toolName: "get_weather", arguments: #"{"city":"Paris"}"#)
        )
        XCTAssertEqual(result.errorKind, nil)
        XCTAssertTrue(result.content.contains("v2"), "Override must win on dispatch. Got: \(result.content)")
        XCTAssertFalse(result.content.contains("v1"))
    }

    // MARK: - dispatch: unknown tool

    func test_unknownTool_returnsUnknownToolKind() async {
        let registry = ToolRegistry()
        let call = ToolCall(id: "call-42", toolName: "nonexistent", arguments: "{}")

        let result = await registry.dispatch(call)

        // Sabotage check: force the lookup to always resolve makes this fail.
        XCTAssertEqual(result.errorKind, .unknownTool)
        XCTAssertEqual(result.callId, "call-42")
        XCTAssertTrue(result.content.contains("nonexistent"))
    }

    // MARK: - dispatch: case-insensitive lookup

    func test_dispatch_resolvesCaseInsensitively() async {
        let registry = ToolRegistry()
        registry.register(makeWeatherExecutor(name: "GetWeather"))

        let result = await registry.dispatch(
            ToolCall(id: "c1", toolName: "getweather", arguments: #"{"city":"Rome"}"#)
        )
        XCTAssertEqual(result.errorKind, nil)
        XCTAssertEqual(result.callId, "c1")
        XCTAssertTrue(result.content.contains("Rome"))
    }

    // MARK: - dispatch: malformed JSON

    func test_malformedArguments_returnsInvalidArguments() async {
        let registry = ToolRegistry()
        registry.register(makeWeatherExecutor())

        let call = ToolCall(id: "call-7", toolName: "get_weather", arguments: "not json {")
        let result = await registry.dispatch(call)

        XCTAssertEqual(result.errorKind, .invalidArguments)
        XCTAssertEqual(result.callId, "call-7")
        XCTAssertTrue(result.content.contains("not valid JSON"))
    }

    func test_emptyArguments_treatedAsEmptyObject() async {
        let registry = ToolRegistry()
        let recorder = RecordingExecutor(name: "record")
        registry.register(recorder)

        let result = await registry.dispatch(
            ToolCall(id: "c", toolName: "record", arguments: "")
        )
        XCTAssertEqual(result.errorKind, nil)
        XCTAssertEqual(recorder.lastArguments, .object([:]))
    }

    // MARK: - dispatch: executor throws

    func test_executorThrows_returnsPermanentWithDescription() async {
        let registry = ToolRegistry()
        registry.register(ThrowingExecutor(name: "bomb"))

        let call = ToolCall(id: "call-b", toolName: "bomb", arguments: "{}")
        let result = await registry.dispatch(call)

        XCTAssertEqual(result.errorKind, .permanent)
        XCTAssertEqual(result.callId, "call-b")
        XCTAssertTrue(result.content.contains("boom-message"), "Content should include the error description. Got: \(result.content)")
    }

    // MARK: - dispatch: atomicity contract (#630)

    /// Executor that performs visible "partial work" into a caller-owned
    /// buffer before throwing. Locks in the ``ToolExecutor`` atomicity
    /// contract: no partial state reaches the ``ToolResult``; only the thrown
    /// error description is surfaced to the orchestrator.
    private final class PartialWorkExecutor: ToolExecutor, @unchecked Sendable {
        struct MidFlightError: Error, CustomStringConvertible {
            var description: String { "disk io failed after 2 chunks" }
        }

        let definition: ToolDefinition
        /// Shared buffer the executor "emits into" during work. Tests read
        /// this to confirm the executor did accumulate state before throwing
        /// — and that the registry dropped it.
        let partialBuffer: PartialBuffer

        init(name: String, buffer: PartialBuffer) {
            self.definition = ToolDefinition(name: name, description: "partial", parameters: .object([:]))
            self.partialBuffer = buffer
        }

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            // Simulate streaming work by appending chunks to the buffer and
            // then failing — exactly the shape the contract forbids exposing
            // to the orchestrator.
            await partialBuffer.append("chunk-1")
            await partialBuffer.append("chunk-2")
            throw MidFlightError()
        }
    }

    /// Async-safe accumulator used by ``PartialWorkExecutor``. An actor is
    /// the simplest way to make the "caller-owned buffer" pattern concurrent
    /// without reaching for locks.
    private actor PartialBuffer {
        private(set) var chunks: [String] = []
        func append(_ chunk: String) { chunks.append(chunk) }
        func snapshot() -> [String] { chunks }
    }

    func test_executorAtomicity_partialWorkDiscarded_onThrow() async {
        // Given an executor that accumulates state into a side-channel buffer
        // and then throws mid-work, the orchestrator must see only the
        // thrown-error ToolResult — no partial content leaks into the
        // transcript via ``ToolResult/content``.
        let registry = ToolRegistry()
        let buffer = PartialBuffer()
        registry.register(PartialWorkExecutor(name: "partial", buffer: buffer))

        let call = ToolCall(id: "call-atomic", toolName: "partial", arguments: "{}")
        let result = await registry.dispatch(call)

        // Thrown executor errors classify as .permanent by design: an
        // uncategorised throw is the catch-all escape hatch, and marking it
        // retry-safe would loop agents on real permanent failures (logic
        // bugs, schema mismatches, auth denials). Executors that know their
        // failure is retriable must return a ToolResult with .transient
        // explicitly — see the ToolExecutor atomicity DocC note.
        XCTAssertEqual(result.errorKind, .permanent)
        XCTAssertEqual(result.callId, "call-atomic")
        XCTAssertTrue(
            result.content.contains("disk io failed after 2 chunks"),
            "Error description must surface in ToolResult.content. Got: \(result.content)"
        )

        // The executor definitely accumulated partial state — confirm the
        // side-channel buffer saw both chunks. This proves the test is
        // actually exercising the "work happened before the throw" path and
        // not silently skipping it.
        let seen = await buffer.snapshot()
        XCTAssertEqual(seen, ["chunk-1", "chunk-2"])

        // None of the partial state must have leaked into the ToolResult
        // that the orchestrator records in the transcript.
        XCTAssertFalse(
            result.content.contains("chunk-1"),
            "Partial chunk leaked into ToolResult.content: \(result.content)"
        )
        XCTAssertFalse(
            result.content.contains("chunk-2"),
            "Partial chunk leaked into ToolResult.content: \(result.content)"
        )
    }

    // MARK: - dispatch: happy path

    func test_typedExecutor_happyPath_roundTrip() async throws {
        let registry = ToolRegistry()
        registry.register(makeWeatherExecutor())

        let call = ToolCall(
            id: "call-hp",
            toolName: "get_weather",
            arguments: #"{"city":"London"}"#
        )
        let result = await registry.dispatch(call)

        XCTAssertEqual(result.errorKind, nil)
        XCTAssertEqual(result.callId, "call-hp")
        // Content should be a JSON-encoded WeatherResult.
        let payload = try JSONDecoder().decode(WeatherResult.self, from: Data(result.content.utf8))
        XCTAssertEqual(payload.summary, "Sunny in London")
        XCTAssertEqual(payload.celsius, 22.0, accuracy: 0.001)
    }

    func test_typedExecutor_malformedShape_returnsPermanent() async {
        // JSON is valid but doesn't match CityArgs (missing "city"). The decode
        // error is thrown out of `execute` and caught by dispatch as .permanent.
        let registry = ToolRegistry()
        registry.register(makeWeatherExecutor())

        let call = ToolCall(
            id: "call-x",
            toolName: "get_weather",
            arguments: #"{"wrong":"shape"}"#
        )
        let result = await registry.dispatch(call)

        XCTAssertEqual(result.errorKind, .permanent)
        XCTAssertEqual(result.callId, "call-x")
    }

    // MARK: - validator property

    func test_validator_defaultsToNil() {
        let registry = ToolRegistry()
        XCTAssertNil(registry.validator)
    }
}
