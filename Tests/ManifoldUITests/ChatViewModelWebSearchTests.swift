@preconcurrency import XCTest
import Foundation
@testable import ManifoldUI
@testable import ManifoldRuntime
@testable import ManifoldInference

/// Coverage for ``ChatViewModel`` web-search entry surface and the thin
/// ``WebSearchToolSource`` forwarder. Mirrors
/// `ChatViewModelImageGenerationTests` but for the request/response web-search
/// path: the runtime is a simple mock returning canned text, so the tests
/// assert forwarding and error mapping rather than an event stream.
@MainActor
final class ChatViewModelWebSearchTests: XCTestCase {

    // MARK: - Mock runtime

    final class MockWebSearchRuntime: WebSearchRuntime, @unchecked Sendable {
        var result: String = "stubbed result"
        var errorToThrow: (any Error)?
        private(set) var receivedQueries: [String] = []

        func search(query: String) async throws -> String {
            receivedQueries.append(query)
            if let errorToThrow { throw errorToThrow }
            return result
        }
    }

    struct BoomError: LocalizedError {
        var errorDescription: String? { "boom" }
    }

    // MARK: - Builders

    private func makeViewModel() -> ChatViewModel {
        ChatViewModel(
            inferenceService: InferenceService(),
            userDefaults: UserDefaults(suiteName: "ChatViewModelWebSearchTests-\(UUID().uuidString)")!
        )
    }

    // MARK: - searchWeb forwarding

    func test_searchWeb_withoutConfiguredRuntime_throwsNotConfigured() async {
        let vm = makeViewModel()
        do {
            _ = try await vm.searchWeb(query: "q")
            XCTFail("Expected throw")
        } catch let error as ChatViewModelWebSearchError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_searchWeb_forwardsQueryAndReturnsResult() async throws {
        let runtime = MockWebSearchRuntime()
        runtime.result = "the answer"
        let vm = makeViewModel()
        vm.configure(webSearchRuntime: runtime)

        let result = try await vm.searchWeb(query: "what is 2+2")
        XCTAssertEqual(result, "the answer")
        XCTAssertEqual(runtime.receivedQueries, ["what is 2+2"])
    }

    func test_searchWeb_propagatesRuntimeError() async {
        let runtime = MockWebSearchRuntime()
        runtime.errorToThrow = BoomError()
        let vm = makeViewModel()
        vm.configure(webSearchRuntime: runtime)

        do {
            _ = try await vm.searchWeb(query: "q")
            XCTFail("Expected throw")
        } catch let error as BoomError {
            XCTAssertEqual(error.errorDescription, "boom")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - WebSearchToolSource forwarding

    func test_toolSource_definesSearchWebTool() async {
        let vm = makeViewModel()
        let source = WebSearchToolSource(viewModel: vm)
        let session = ChatSession(title: "T")
        let defs = await source.toolDefinitions(for: session)
        XCTAssertEqual(defs.count, 1)
        XCTAssertEqual(defs.first?.name, "search_web")
    }

    func test_toolSource_resolve_forwardsToViewModelAndReturnsContent() async throws {
        let runtime = MockWebSearchRuntime()
        runtime.result = "live result"
        let vm = makeViewModel()
        vm.configure(webSearchRuntime: runtime)

        let source = WebSearchToolSource(viewModel: vm)
        let session = ChatSession(title: "T")
        let result = try await source.resolve(
            toolName: "search_web",
            arguments: #"{"query": "recent news"}"#,
            session: session
        )
        XCTAssertEqual(result.content, "live result")
        XCTAssertNil(result.errorKind)
        XCTAssertEqual(runtime.receivedQueries, ["recent news"])
    }

    func test_toolSource_resolve_unknownTool_returnsUnknownToolError() async throws {
        let vm = makeViewModel()
        let source = WebSearchToolSource(viewModel: vm)
        let session = ChatSession(title: "T")
        let result = try await source.resolve(
            toolName: "not_search",
            arguments: #"{"query": "x"}"#,
            session: session
        )
        XCTAssertEqual(result.errorKind, .unknownTool)
    }

    func test_toolSource_resolve_emptyQuery_returnsInvalidArguments() async throws {
        let runtime = MockWebSearchRuntime()
        let vm = makeViewModel()
        vm.configure(webSearchRuntime: runtime)
        let source = WebSearchToolSource(viewModel: vm)
        let session = ChatSession(title: "T")
        let result = try await source.resolve(
            toolName: "search_web",
            arguments: #"{"query": "   "}"#,
            session: session
        )
        XCTAssertEqual(result.errorKind, .invalidArguments)
        XCTAssertTrue(runtime.receivedQueries.isEmpty, "runtime must not be called for empty query")
    }

    func test_toolSource_resolve_runtimeError_returnsTransientError() async throws {
        let runtime = MockWebSearchRuntime()
        runtime.errorToThrow = BoomError()
        let vm = makeViewModel()
        vm.configure(webSearchRuntime: runtime)
        let source = WebSearchToolSource(viewModel: vm)
        let session = ChatSession(title: "T")
        let result = try await source.resolve(
            toolName: "search_web",
            arguments: #"{"query": "q"}"#,
            session: session
        )
        XCTAssertEqual(result.errorKind, .transient)
        XCTAssertTrue(result.content.contains("Search failed"))
    }

    func test_toolSource_resolve_notConfigured_returnsTransientError() async throws {
        // No runtime configured — searchWeb throws notConfigured, which the
        // tool maps to a transient error result rather than trapping.
        let vm = makeViewModel()
        let source = WebSearchToolSource(viewModel: vm)
        let session = ChatSession(title: "T")
        let result = try await source.resolve(
            toolName: "search_web",
            arguments: #"{"query": "q"}"#,
            session: session
        )
        XCTAssertEqual(result.errorKind, .transient)
    }
}
