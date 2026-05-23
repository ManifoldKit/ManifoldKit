#if AppIntents
import XCTest
import ManifoldInference
@testable import ManifoldAppIntents

#if canImport(AppIntents)
import AppIntents

// MARK: - Mock handler

/// Simple mock that returns a fixed reply or throws a caller-supplied error.
///
/// `AskManifoldHandler` requires `Actor` isolation — an `actor` is the right
/// shape here, not `@unchecked Sendable` on a class.
@available(iOS 18, macOS 15, *)
actor MockAskManifoldHandler: AskManifoldHandler {
    let reply: String
    let name: String
    let errorToThrow: Error?

    init(reply: String = "mock reply", name: String = "MockHandler", errorToThrow: Error? = nil) {
        self.reply = reply
        self.name = name
        self.errorToThrow = errorToThrow
    }

    func ask(_ prompt: String) async throws -> String {
        if let error = errorToThrow { throw error }
        return reply
    }

    func displayName() async -> String { name }
}

// MARK: - Tests

@available(iOS 18, macOS 15, *)
final class AskManifoldIntentTests: XCTestCase {

    override func setUp() async throws {
        // Reset the shared singleton so each test starts with no handler.
        // Without this, tests that install a handler bleed state into
        // subsequent tests — ordering determines which paths get exercised.
        await ManifoldIntentConfiguration.shared.clearHandler()
    }

    // MARK: - perform() with configured handler

    func test_perform_returnsDialogWhenHandlerConfigured() async throws {
        let handler = MockAskManifoldHandler(reply: "42", name: "TestBot")
        await ManifoldIntentConfiguration.shared.configure(handler: handler)

        var intent = AskManifoldIntent()
        intent.prompt = "What is the answer?"
        // Must not throw — AskManifoldIntent catches all errors internally.
        let result = try await intent.perform()

        // `String(describing:)` of the IntentResultContainer reliably contains
        // the dialog text even when public-API mirror extraction returns nil
        // (see AppIntentToolExecutorTests for the full explanation of why
        // IntentDialog storage is opaque on iOS 26 / macOS 26).
        let dump = String(describing: result)
        XCTAssertTrue(
            dump.contains("TestBot") || dump.contains("42"),
            "Expected dialog to contain handler name or reply; got: \(dump)"
        )
    }

    // MARK: - perform() without handler

    func test_perform_returnsGracefulDialogWhenHandlerNil() async throws {
        // setUp() clears shared, so no handler is configured at this point.
        var intent = AskManifoldIntent()
        intent.prompt = "test"
        let result = try await intent.perform()
        let dump = String(describing: result)
        XCTAssertTrue(
            dump.contains("not configured"),
            "Expected 'not configured' dialog when no handler is set; got: \(dump)"
        )
    }

    // MARK: - perform() when handler throws

    func test_perform_returnsGracefulDialogWhenHandlerThrows() async throws {
        struct FakeError: Error, LocalizedError {
            var errorDescription: String? { "backend unavailable" }
        }
        let handler = MockAskManifoldHandler(errorToThrow: FakeError())
        await ManifoldIntentConfiguration.shared.configure(handler: handler)

        var intent = AskManifoldIntent()
        intent.prompt = "Will this fail?"
        // Must NOT throw — handler errors are caught and turned into a dialog.
        let result = try await intent.perform()

        let dump = String(describing: result)
        // The raw error message must not leak into the dialog — only the
        // generic fallback text is acceptable.
        XCTAssertFalse(
            dump.contains("backend unavailable"),
            "Raw error message must not leak into the Siri dialog; got: \(dump)"
        )
        XCTAssertTrue(
            dump.contains("Something went wrong"),
            "Expected graceful error dialog; got: \(dump)"
        )
    }

    // MARK: - configure() latest-wins

    func test_configure_latestHandlerWins() async throws {
        let first = MockAskManifoldHandler(reply: "first reply", name: "FirstBot")
        let second = MockAskManifoldHandler(reply: "second reply", name: "SecondBot")
        await ManifoldIntentConfiguration.shared.configure(handler: first)
        await ManifoldIntentConfiguration.shared.configure(handler: second)

        // The registered handler after two calls must be the second one.
        let registered = await ManifoldIntentConfiguration.shared.handler
        // Cast to MockAskManifoldHandler to verify identity via displayName.
        let resolvedName = await registered?.displayName()
        XCTAssertEqual(
            resolvedName,
            "SecondBot",
            "Expected second handler to win; got displayName: \(String(describing: resolvedName))"
        )
    }

    // MARK: - displayName() appears in dialog

    func test_perform_dialogContainsDisplayName() async throws {
        let handler = MockAskManifoldHandler(reply: "hello world", name: "MyCustomBot")
        await ManifoldIntentConfiguration.shared.configure(handler: handler)

        var intent = AskManifoldIntent()
        intent.prompt = "ping"
        let result = try await intent.perform()

        let dump = String(describing: result)
        // displayName() must appear somewhere in the result representation so
        // Siri can read back which service answered.
        XCTAssertTrue(
            dump.contains("MyCustomBot"),
            "displayName() must appear in the intent result; got: \(dump)"
        )
    }
}

#endif // canImport(AppIntents)
#endif // AppIntents
