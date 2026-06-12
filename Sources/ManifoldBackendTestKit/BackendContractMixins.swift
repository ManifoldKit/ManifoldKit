import XCTest
import ManifoldInference

/// XCTest-visible mixins for opt-in backend protocol contracts.
///
/// Extension methods are intentionally assertion helpers rather than `test_…`
/// methods: XCTest does not discover protocol-extension tests. Adopting suites
/// call these helpers from concrete test methods so each backend explicitly opts
/// into the protocol contracts it supports.
/// All contract mixin protocols are `@MainActor`-isolated so that conforming
/// test classes (which are `@MainActor`) satisfy Swift 6's isolation boundary
/// checks without wrapping factory calls in extra closures.
@MainActor
public protocol BackendContractMixin: AnyObject {
    associatedtype BackendUnderContract: InferenceBackend

    var contractBackendName: String { get }
    func makeContractBackend() -> BackendUnderContract
}

extension BackendContractMixin where Self: XCTestCase {
    @MainActor
    public func assertUniversalBackendContract(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        BackendContractChecks.assertAllInvariants(
            makingBackend: makeContractBackend,
            file: file,
            line: line
        )
    }
}

public protocol GrammarFailClosedContractMixin: BackendContractMixin {}

extension GrammarFailClosedContractMixin where Self: XCTestCase {
    @MainActor
    public func assertGrammarFailClosedContract(
        forbiddenRequestURL: URL? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await BackendContractChecks.assertGrammarFailClosedContract(
            backendName: contractBackendName,
            makingBackend: makeContractBackend,
            forbiddenRequestURL: forbiddenRequestURL,
            file: file,
            line: line
        )
    }
}

@MainActor
public protocol ConversationHistoryReceiverContractMixin: BackendContractMixin where BackendUnderContract: ConversationHistoryReceiver {}

extension ConversationHistoryReceiverContractMixin where Self: XCTestCase {
    @MainActor
    public func assertConversationHistoryReceiverContract(
        readHistory: (BackendUnderContract) -> [(role: String, content: String)]?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let backend = makeContractBackend()
        let firstHistory: [(role: String, content: String)] = [
            (role: "system", content: "You are concise."),
            (role: "user", content: "Hello"),
            (role: "assistant", content: "Hi")
        ]
        backend.setConversationHistory(firstHistory)
        assertHistory(readHistory(backend), equals: firstHistory, file: file, line: line)

        let replacementHistory: [(role: String, content: String)] = [
            (role: "user", content: "Replacement history")
        ]
        backend.setConversationHistory(replacementHistory)
        assertHistory(readHistory(backend), equals: replacementHistory, file: file, line: line)
    }

    private func assertHistory(
        _ actual: [(role: String, content: String)]?,
        equals expected: [(role: String, content: String)],
        file: StaticString,
        line: UInt
    ) {
        guard let actual else {
            XCTFail("Expected backend to retain conversation history", file: file, line: line)
            return
        }
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (index, expectedEntry) in expected.enumerated() where index < actual.count {
            XCTAssertEqual(actual[index].role, expectedEntry.role, file: file, line: line)
            XCTAssertEqual(actual[index].content, expectedEntry.content, file: file, line: line)
        }
    }
}

@MainActor
public protocol StructuredHistoryReceiverContractMixin: BackendContractMixin where BackendUnderContract: StructuredHistoryReceiver {}

extension StructuredHistoryReceiverContractMixin where Self: XCTestCase {
    @MainActor
    public func assertStructuredHistoryReceiverContract(
        readHistory: (BackendUnderContract) -> [StructuredMessage]?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let backend = makeContractBackend()
        let firstHistory = [
            StructuredMessage(role: "user", parts: [.text("Question")]),
            StructuredMessage(role: "assistant", parts: [.thinking("Reasoning", signature: "sig-1"), .text("Answer")])
        ]
        backend.setStructuredHistory(firstHistory)
        XCTAssertEqual(readHistory(backend), firstHistory, file: file, line: line)

        let replacementHistory = [
            StructuredMessage(role: "tool", parts: [.text("{\"ok\":true}")])
        ]
        backend.setStructuredHistory(replacementHistory)
        XCTAssertEqual(readHistory(backend), replacementHistory, file: file, line: line)
    }
}
