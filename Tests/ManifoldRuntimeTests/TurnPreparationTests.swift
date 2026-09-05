@preconcurrency import XCTest
import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference
import ManifoldPersistenceSwiftData
import ManifoldPersistenceTestSupport

/// Direct unit coverage of ``TurnPreparation`` pure helpers and the
/// history-shaper validation rules extracted from ConversationTurnExecutor
/// (#1957 Priority 3). Full prepareHistory/prepareGeneration paths remain
/// covered by ConversationRuntimeTurnPreparationTests + characterization
/// goldens; these pin the now-isolated seams.
final class TurnPreparationTests: XCTestCase {

    @MainActor
    func test_boundedHealedHistory_usesKeysetOrderAcrossEqualTimestampTenThousandBoundary() async throws {
        let stack = try InMemoryPersistenceHarness.make()
        let sessionID = UUID()
        let timestamp = Date(timeIntervalSinceReferenceDate: 1)
        let records = (0...10_000).map { index in
            ChatMessage(role: .user, content: "m\(index)", timestamp: timestamp, sessionID: sessionID)
        }
        try await stack.provider.performMessageMutations(records.map(MessageStoreMutation.insert))
        let bounded = try await stack.provider.fetchRecentHealedMessages(for: sessionID, limit: 3)
        let expected = records.sorted { $0.id < $1.id }.suffix(3).map(\.id)
        XCTAssertEqual(bounded.map(\.id), expected)
    }

    /// A counting façade over the production SwiftData adapter. The test below
    /// uses its page record to distinguish a bounded generation read from an
    /// accidental whole-session read without replacing persistence with an
    /// in-memory dictionary.
    @MainActor
    private final class CountingSwiftDataMessageStore: MessageStore {
        struct PageRequest: Equatable {
            let cursor: MessageHistoryCursor?
            let limit: Int
        }

        private let provider: SwiftDataPersistenceProvider
        private(set) var wholeFetchCount = 0
        private(set) var pageRequests: [PageRequest] = []

        init(provider: SwiftDataPersistenceProvider) {
            self.provider = provider
        }

        func insertMessage(_ message: ChatMessage) async throws {
            try await provider.insertMessage(message)
        }

        func updateMessage(_ message: ChatMessage) async throws {
            try await provider.updateMessage(message)
        }

        func deleteMessage(_ messageID: UUID) async throws {
            try await provider.deleteMessage(messageID)
        }

        func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] {
            wholeFetchCount += 1
            return try await provider.fetchMessages(for: sessionID)
        }

        func fetchMessageHistoryPage(
            for sessionID: UUID,
            cursor: MessageHistoryCursor?,
            limit: Int
        ) async throws -> MessageHistoryPage {
            pageRequests.append(PageRequest(cursor: cursor, limit: limit))
            return try await provider.fetchMessageHistoryPage(
                for: sessionID,
                cursor: cursor,
                limit: limit
            )
        }

        func deleteMessages(for sessionID: UUID) async throws {
            try await provider.deleteMessages(for: sessionID)
        }
    }

    @MainActor
    func test_prepareHistory_usesBoundedSwiftDataPage_notWholeTranscript() async throws {
        let stack = try InMemoryPersistenceHarness.make()
        let sessionID = UUID()
        let records = (0...10_000).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "history-\(index)",
                timestamp: Date(timeIntervalSinceReferenceDate: Double(index)),
                sessionID: sessionID
            )
        }
        try await stack.provider.performMessageMutations(records.map(MessageStoreMutation.insert))

        let messageStore = CountingSwiftDataMessageStore(provider: stack.provider)
        let persistence = ConversationPersistencePort(messageStore: messageStore, sessionStore: nil)
        let inference = InferenceService()
        let preparation = TurnPreparation(
            persistence: persistence,
            inferenceService: inference,
            pipeline: nil,
            budgetPlanner: nil,
            ragService: nil,
            events: TurnEventEmitter { _ in },
            historyShaper: nil,
            historyAssembler: HistoryAssembler(providers: []),
            hostTurnContextProvider: nil,
            legacyTurnContextProvider: nil,
            bindings: RuntimeBindingsBox(),
            toolDispatch: SessionToolDispatchBinder(inferenceService: inference)
        )

        let prepared = try await preparation.prepareHistory(
            sessionID: sessionID,
            turnKind: .send(text: "next"),
            userPrompt: "next"
        )

        XCTAssertEqual(prepared.history.count, 10_000)
        XCTAssertEqual(prepared.history.first?.id, records[1].id)
        XCTAssertEqual(prepared.history.last?.id, records.last?.id)
        XCTAssertEqual(messageStore.wholeFetchCount, 0)
        XCTAssertEqual(messageStore.pageRequests, [.init(cursor: nil, limit: 10_000)])
    }

    // MARK: composeSystemPrompt

    func test_composeSystemPrompt_nilBase_noSlots_returnsNil() {
        XCTAssertNil(TurnPreparation.composeSystemPrompt(nil, slots: []))
    }

    func test_composeSystemPrompt_nilBase_withSlots_returnsJoinedSlots() {
        let slots = [
            PromptSlot(id: "a", content: "slot-a", label: "A"),
            PromptSlot(id: "b", content: "slot-b", label: "B")
        ]
        XCTAssertEqual(
            TurnPreparation.composeSystemPrompt(nil, slots: slots),
            "slot-a\n\nslot-b"
        )
    }

    func test_composeSystemPrompt_baseOnly_returnsBase() {
        XCTAssertEqual(
            TurnPreparation.composeSystemPrompt("you are helpful", slots: []),
            "you are helpful"
        )
    }

    func test_composeSystemPrompt_emptyBase_withSlots_returnsSlots() {
        let slots = [PromptSlot(id: "a", content: "only-slot", label: "A")]
        XCTAssertEqual(
            TurnPreparation.composeSystemPrompt("", slots: slots),
            "only-slot"
        )
    }

    func test_composeSystemPrompt_baseAndSlots_joinsWithBlankLine() {
        let slots = [PromptSlot(id: "a", content: "ctx", label: "A")]
        XCTAssertEqual(
            TurnPreparation.composeSystemPrompt("base", slots: slots),
            "base\n\nctx"
        )
    }

    func test_composeSystemPrompt_disabledAndEmptySlots_areSkipped() {
        let slots = [
            PromptSlot(id: "on", content: "keep", label: "On"),
            PromptSlot(id: "off", content: "drop", isEnabled: false, label: "Off"),
            PromptSlot(id: "empty", content: "", label: "Empty")
        ]
        XCTAssertEqual(
            TurnPreparation.composeSystemPrompt("base", slots: slots),
            "base\n\nkeep"
        )
    }

    // MARK: validateShapedHistory

    func test_validateShapedHistory_identity_passes() throws {
        let sid = UUID()
        let a = ChatMessage(role: .user, content: "a", sessionID: sid)
        let b = ChatMessage(role: .assistant, content: "b", sessionID: sid)
        try TurnPreparation.validateShapedHistory([a, b], against: [a, b])
    }

    func test_validateShapedHistory_subsetPreservingOrder_passes() throws {
        let sid = UUID()
        let a = ChatMessage(role: .user, content: "a", sessionID: sid)
        let b = ChatMessage(role: .assistant, content: "b", sessionID: sid)
        let c = ChatMessage(role: .user, content: "c", sessionID: sid)
        try TurnPreparation.validateShapedHistory([a, c], against: [a, b, c])
    }

    func test_validateShapedHistory_duplicateIDs_throws() {
        let a = ChatMessage(role: .user, content: "a", sessionID: UUID())
        XCTAssertThrowsError(
            try TurnPreparation.validateShapedHistory([a, a], against: [a])
        )
    }

    func test_validateShapedHistory_nonCanonicalID_throws() {
        let sid = UUID()
        let a = ChatMessage(role: .user, content: "a", sessionID: sid)
        let foreign = ChatMessage(role: .user, content: "x", sessionID: sid)
        XCTAssertThrowsError(
            try TurnPreparation.validateShapedHistory([foreign], against: [a])
        )
    }

    func test_validateShapedHistory_orderViolation_throws() {
        let sid = UUID()
        let a = ChatMessage(role: .user, content: "a", sessionID: sid)
        let b = ChatMessage(role: .assistant, content: "b", sessionID: sid)
        XCTAssertThrowsError(
            try TurnPreparation.validateShapedHistory([b, a], against: [a, b])
        )
    }
}
