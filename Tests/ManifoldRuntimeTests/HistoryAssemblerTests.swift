@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference

/// Coverage for ``HistoryAssembler`` and ``HistoryProvider`` protocol — the
/// pre-generation record injection stage that runs between persistence fetch
/// and context assembly.
final class HistoryAssemblerTests: XCTestCase {

    // MARK: - Helpers

    private let sessionID = UUID()

    private func makeRecord(
        role: MessageRole = .user,
        content: String = "hello",
        timestamp: Date = Date(),
        kind: MessageKind = .chat
    ) -> ChatMessageRecord {
        ChatMessageRecord(
            role: role,
            content: content,
            timestamp: timestamp,
            sessionID: sessionID,
            kind: kind
        )
    }

    private func makeTurnContext(history: [ChatMessageRecord] = []) -> TurnContext {
        TurnContext(sessionID: sessionID, messageCount: history.count)
    }

    // MARK: - Provider fixtures

    struct SingleContributionProvider: HistoryProvider {
        let contribution: HistoryContribution
        func contribute(
            history: [ChatMessageRecord],
            context: TurnContext
        ) async throws -> [HistoryContribution] {
            [contribution]
        }
    }

    struct ThrowingProvider: HistoryProvider {
        struct TestError: Error {}
        func contribute(
            history: [ChatMessageRecord],
            context: TurnContext
        ) async throws -> [HistoryContribution] {
            throw TestError()
        }
    }

    // MARK: - Tests

    func test_identityProvider_returnsUnchangedHistory() async throws {
        let records = [
            makeRecord(role: .user, content: "msg1"),
            makeRecord(role: .assistant, content: "msg2")
        ]
        let assembler = HistoryAssembler(providers: [IdentityHistoryProvider()])
        let result = try await assembler.assemble(history: records, context: makeTurnContext(history: records))
        XCTAssertEqual(result.map(\.content), records.map(\.content))
        XCTAssertEqual(result.count, 2)
    }

    func test_atDepth_insertsAtCorrectPosition() async throws {
        let base = Date()
        let records = [
            makeRecord(role: .user, content: "A", timestamp: base),
            makeRecord(role: .assistant, content: "B", timestamp: base.addingTimeInterval(1)),
            makeRecord(role: .user, content: "C", timestamp: base.addingTimeInterval(2))
        ]
        // atDepth(2) from tail on 3 items = index 1 (between A and B)
        let injected = ChatMessageRecord(
            role: .system,
            content: "memory-injected",
            sessionID: sessionID,
            kind: .memory("test")
        )
        let provider = SingleContributionProvider(
            contribution: HistoryContribution(record: injected, position: .atDepth(2))
        )
        let assembler = HistoryAssembler(providers: [provider])
        let result = try await assembler.assemble(history: records, context: makeTurnContext(history: records))
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[1].content, "memory-injected")

        // Sabotage: wrong depth would put it elsewhere
        XCTAssertNotEqual(result[0].content, "memory-injected")
        XCTAssertNotEqual(result[3].content, "memory-injected")
    }

    func test_head_insertsFirst() async throws {
        let records = [
            makeRecord(role: .user, content: "first"),
            makeRecord(role: .assistant, content: "second")
        ]
        let injected = makeRecord(role: .system, content: "header", kind: .memory("header"))
        let provider = SingleContributionProvider(
            contribution: HistoryContribution(record: injected, position: .head)
        )
        let assembler = HistoryAssembler(providers: [provider])
        let result = try await assembler.assemble(history: records, context: makeTurnContext(history: records))
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].content, "header")
        XCTAssertEqual(result[1].content, "first")

        // Sabotage: any other position would not be at index 0
        XCTAssertNotEqual(result[1].content, "header")
    }

    func test_tail_appendsLast() async throws {
        let records = [
            makeRecord(role: .user, content: "first"),
            makeRecord(role: .assistant, content: "second")
        ]
        let injected = makeRecord(role: .system, content: "footer", kind: .memory("footer"))
        let provider = SingleContributionProvider(
            contribution: HistoryContribution(record: injected, position: .tail)
        )
        let assembler = HistoryAssembler(providers: [provider])
        let result = try await assembler.assemble(history: records, context: makeTurnContext(history: records))
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.last?.content, "footer")

        // Sabotage: head would put it first, not last
        XCTAssertNotEqual(result[0].content, "footer")
    }

    func test_beforeRecord_insertsBeforeTarget() async throws {
        let r1 = makeRecord(role: .user, content: "A")
        let r2 = makeRecord(role: .assistant, content: "B")
        let records = [r1, r2]
        let injected = makeRecord(role: .system, content: "before-B", kind: .memory("m"))
        let provider = SingleContributionProvider(
            contribution: HistoryContribution(record: injected, position: .beforeRecord(r2.id))
        )
        let assembler = HistoryAssembler(providers: [provider])
        let result = try await assembler.assemble(history: records, context: makeTurnContext(history: records))
        XCTAssertEqual(result.count, 3)
        // before-B should be at index 1, B should be at index 2
        XCTAssertEqual(result[1].content, "before-B")
        XCTAssertEqual(result[2].content, "B")

        // Sabotage: afterRecord would put it after B
        XCTAssertNotEqual(result[2].content, "before-B")
    }

    func test_afterRecord_insertsAfterTarget() async throws {
        let r1 = makeRecord(role: .user, content: "A")
        let r2 = makeRecord(role: .assistant, content: "B")
        let records = [r1, r2]
        let injected = makeRecord(role: .system, content: "after-A", kind: .memory("m"))
        let provider = SingleContributionProvider(
            contribution: HistoryContribution(record: injected, position: .afterRecord(r1.id))
        )
        let assembler = HistoryAssembler(providers: [provider])
        let result = try await assembler.assemble(history: records, context: makeTurnContext(history: records))
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].content, "A")
        XCTAssertEqual(result[1].content, "after-A")
        XCTAssertEqual(result[2].content, "B")

        // Sabotage: beforeRecord(r1.id) would put it at index 0
        XCTAssertNotEqual(result[0].content, "after-A")
    }

    func test_beforeRecord_missingID_appendsToTail() async throws {
        let records = [
            makeRecord(role: .user, content: "A"),
            makeRecord(role: .assistant, content: "B")
        ]
        let missingID = UUID()
        let injected = makeRecord(role: .system, content: "orphan", kind: .memory("m"))
        let provider = SingleContributionProvider(
            contribution: HistoryContribution(record: injected, position: .beforeRecord(missingID))
        )
        let assembler = HistoryAssembler(providers: [provider])
        let result = try await assembler.assemble(history: records, context: makeTurnContext(history: records))
        // Missing ID falls back to endIndex (tail)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.last?.content, "orphan")

        // Sabotage: if it were dropped entirely, count would be 2
        XCTAssertNotEqual(result.count, 2)
    }

    func test_multipleProviders_appliedInRegistrationOrder() async throws {
        let base = makeRecord(role: .user, content: "base")
        let records = [base]

        // Provider 1 injects at tail: ["base", "from-p1"]
        // Provider 2 sees ["base", "from-p1"] and injects at tail: ["base", "from-p1", "from-p2"]
        let p1Record = makeRecord(role: .system, content: "from-p1", kind: .memory("p1"))
        let p2Record = makeRecord(role: .system, content: "from-p2", kind: .memory("p2"))

        struct P2Provider: HistoryProvider {
            let record: ChatMessageRecord
            func contribute(
                history: [ChatMessageRecord],
                context: TurnContext
            ) async throws -> [HistoryContribution] {
                // Verifies that history includes prior provider's output
                XCTAssertTrue(history.contains(where: { $0.content == "from-p1" }),
                    "P2 should see P1's contribution in history")
                return [HistoryContribution(record: record, position: .tail)]
            }
        }

        let providers: [any HistoryProvider] = [
            SingleContributionProvider(contribution: HistoryContribution(record: p1Record, position: .tail)),
            P2Provider(record: p2Record)
        ]
        let assembler = HistoryAssembler(providers: providers)
        let result = try await assembler.assemble(history: records, context: makeTurnContext(history: records))
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[1].content, "from-p1")
        XCTAssertEqual(result[2].content, "from-p2")

        // Sabotage: reversed order would put p2 before p1
        XCTAssertNotEqual(result[1].content, "from-p2")
    }

    func test_throwingProvider_propagatesError() async throws {
        let records = [makeRecord(role: .user, content: "A")]
        let assembler = HistoryAssembler(providers: [ThrowingProvider()])
        do {
            _ = try await assembler.assemble(history: records, context: makeTurnContext(history: records))
            XCTFail("Expected assembler to throw when a provider throws")
        } catch {
            XCTAssertTrue(error is ThrowingProvider.TestError)
        }
    }

    // Test 10: chronological order invariant — only meaningful in DEBUG builds.
    // In release, the assert is compiled out, so we skip the test rather than
    // producing a false negative.
    func test_chronologicalOrderInvariant_debugMode() async throws {
        #if !DEBUG
        throw XCTSkip("Chronological order assert is DEBUG-only")
        #else
        // Build a history where a provider inserts a .chat record with an
        // older timestamp than an existing record, violating the invariant.
        // The assert fires, which crashes the test process — so we instead
        // verify the path with a compliant provider and trust the assert
        // wording from the implementation covers the failure case.
        //
        // An in-process crash from assert() isn't catchable via XCTest, so
        // we structure this as a positive test: a provider that inserts a
        // non-.chat (memory) record with an older timestamp does NOT trip
        // the invariant because the check only covers .chat user/assistant
        // records. This boundary condition documents the invariant scope.
        let base = Date()
        let r1 = makeRecord(role: .user, content: "A", timestamp: base, kind: .chat)
        let r2 = makeRecord(role: .assistant, content: "B", timestamp: base.addingTimeInterval(1), kind: .chat)
        let records = [r1, r2]

        // A .memory record with an old timestamp inserted at head — should NOT
        // trip the .chat invariant.
        let oldMemory = ChatMessageRecord(
            role: .system,
            content: "ancient-memory",
            timestamp: base.addingTimeInterval(-100),
            sessionID: sessionID,
            kind: .memory("m")
        )
        let provider = SingleContributionProvider(
            contribution: HistoryContribution(record: oldMemory, position: .head)
        )
        let assembler = HistoryAssembler(providers: [provider])
        // Must not crash — the invariant skips non-.chat records.
        let result = try await assembler.assemble(history: records, context: makeTurnContext(history: records))
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].content, "ancient-memory")
        #endif
    }
}
