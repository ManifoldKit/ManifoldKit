#if AppIntents
import XCTest
import BaseChatInference
@testable import BaseChatAppIntents

#if canImport(AppIntents)
import AppIntents

// MARK: - Test intent

/// Minimal echo intent: takes a `message` string and returns it verbatim.
///
/// Defined here rather than imported from `AppIntentToolExecutorTests` because
/// test targets are not importable — each test file stands alone.
@available(iOS 26, macOS 26, *)
struct EchoIntent: AppIntent, Decodable {

    static let title: LocalizedStringResource = "Echo"

    @Parameter(title: "Message")
    var message: String

    init() { self.message = "" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.message = try c.decode(String.self, forKey: .message)
    }

    private enum CodingKeys: CodingKey { case message }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: message)
    }
}

// MARK: - Tests

/// End-to-end dispatch of an ``AppIntentToolExecutor`` through
/// ``ToolRegistry/dispatch(_:)``.
///
/// The existing `AppIntentToolExecutorTests` already covers the executor in
/// isolation (decode → perform → serialise). This file adds the next layer:
/// register the executor in a ``ToolRegistry`` and drive it via
/// ``ToolRegistry/dispatch(_:ToolCall)``, which is the path the generation
/// coordinator uses in production.
///
/// Sabotage-evidence:
///   M1: change `nonce` in `XCTAssertEqual` to any other string → assertion
///       fails (value-sensitive; can't be satisfied by a stub).
///   M2: unregister the executor before `dispatch` → the registry returns an
///       error ``ToolResult``; `result.errorKind` is non-nil and `result.content`
///       doesn't match the nonce.
@available(iOS 26, macOS 26, *)
final class AppIntentDispatchE2ETests: XCTestCase {

    // MARK: - Happy path

    /// Dispatching a ``ToolCall`` whose name matches ``EchoIntent`` must
    /// produce a ``ToolResult`` whose `content` equals the payload's
    /// `message` value.
    @MainActor
    func testDispatchRoutesThroughRegistryToEchoIntent() async throws {
        let executor = AppIntentToolExecutor(EchoIntent.self, approvalPolicy: .readOnlyAutoApprove)
        let registry = ToolRegistry(tools: [executor])

        // Unique nonce so coincidental content matches are impossible.
        let nonce = "§ECHO§\(UUID().uuidString.prefix(8))"

        let call = ToolCall(
            id: "echo-1",
            toolName: executor.definition.name,
            arguments: "{\"message\": \"\(nonce)\"}"
        )

        let result = await registry.dispatch(call)

        XCTAssertNil(
            result.errorKind,
            "Happy-path dispatch must not produce an error kind. Got: \(String(describing: result.errorKind))"
        )
        // The executor JSON-serialises the IntentResult; the nonce must appear
        // somewhere in the output even if wrapped in a JSON object.
        XCTAssertTrue(
            result.content.contains(nonce),
            "Result content must contain the echoed nonce (\(nonce)). Got: \(result.content)"
        )
    }

    // MARK: - Tool name derivation

    /// ``AppIntentToolExecutor`` derives the tool name via snake-casing.
    /// Verifying the derived name here proves that ``ToolRegistry/dispatch``
    /// resolves the call by the same name the executor registered under.
    @MainActor
    func testDispatchResolvesBySnakeCasedIntentName() async throws {
        let executor = AppIntentToolExecutor(EchoIntent.self, approvalPolicy: .readOnlyAutoApprove)

        // Snake-cased name: EchoIntent → echo_intent
        XCTAssertEqual(
            executor.definition.name,
            "echo_intent",
            "Executor name must be derived by snake-casing the intent type name"
        )

        let registry = ToolRegistry(tools: [executor])
        let nonce = "§NAME-CHECK§\(UUID().uuidString.prefix(8))"

        // Dispatch using the exact derived name so the test proves end-to-end
        // name resolution (executor registers as "echo_intent", call uses
        // "echo_intent", dispatch succeeds).
        let call = ToolCall(
            id: "echo-name",
            toolName: "echo_intent",
            arguments: "{\"message\": \"\(nonce)\"}"
        )

        let result = await registry.dispatch(call)
        XCTAssertNil(result.errorKind)
        XCTAssertTrue(result.content.contains(nonce))
    }

    // MARK: - Unregistered tool returns error

    /// Dispatching a ``ToolCall`` for an unregistered tool name must return a
    /// ``ToolResult`` whose `errorKind` is non-nil. This validates the registry
    /// doesn't silently swallow unknown-tool requests.
    @MainActor
    func testDispatchUnregisteredToolReturnsError() async throws {
        // Empty registry — nothing registered.
        let registry = ToolRegistry()

        let call = ToolCall(
            id: "ghost-1",
            toolName: "nonexistent_tool",
            arguments: "{}"
        )

        let result = await registry.dispatch(call)

        XCTAssertNotNil(
            result.errorKind,
            "Dispatching an unregistered tool name must produce a non-nil errorKind"
        )
    }
}

#endif // canImport(AppIntents)
#endif
