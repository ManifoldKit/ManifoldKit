import XCTest
import SwiftData
@testable import ManifoldRuntime
import ManifoldInference
import ManifoldPersistenceSwiftData
import ManifoldPersistenceTestSupport
import ManifoldTestSupport

/// Integration coverage for the branch-origin pointer (#2307 branch-origin
/// chip): ``SessionBranchCoordinator/branch(sourceSessionID:branchMessageID:newSessionID:newSessionTitle:)``
/// persists ``ChatSession/branchOriginSessionID`` + ``ChatSession/branchOriginTitleSnapshot``,
/// and ``SessionListService/branchOriginTitle(for:)`` is the read-path seam
/// that resolves them back into the plain `String?` `BranchOriginChipView`
/// consumes.
///
/// Uses the real SwiftData stack (``InMemoryPersistenceHarness``) rather than
/// hand-rolled in-memory stores — this is exactly the schema-mismatch /
/// round-trip surface those in-memory doubles cannot catch.
@MainActor
/// Integration coverage uses real SwiftData; existing lower-level cases stay in this suite.
final class SessionBranchCoordinatorIntegrationTests: XCTestCase {

    private var stack: InMemoryPersistenceHarness.Stack!
    private var coordinator: SessionBranchCoordinator!
    private var listService: SessionListService!

    override func setUp() async throws {
        try await super.setUp()
        stack = try InMemoryPersistenceHarness.make()
        let port = ConversationPersistencePort(messageStore: stack.provider, sessionStore: stack.provider)
        coordinator = SessionBranchCoordinator(persistence: port)
        listService = SessionListService(persistence: stack.provider)
    }

    override func tearDown() async throws {
        listService = nil
        coordinator = nil
        stack = nil
        try await super.tearDown()
    }

    /// Seeds a source session with `messageCount` user/assistant messages
    /// alternating starting with `.user`, and returns the seeded message ids
    /// in order.
    @discardableResult
    private func seedSourceSession(
        id: UUID = UUID(),
        title: String,
        messageCount: Int
    ) async throws -> (sessionID: UUID, messageIDs: [UUID]) {
        let session = ChatSession(id: id, title: title)
        try await stack.provider.insertSession(session)

        var ids: [UUID] = []
        for index in 0..<messageCount {
            let role: MessageRole = index.isMultiple(of: 2) ? .user : .assistant
            let message = ChatMessage(role: role, content: "msg \(index)", sessionID: id)
            try await stack.provider.insertMessage(message)
            ids.append(message.id)
        }
        return (id, ids)
    }

    // MARK: - Origin persisted + readable

    func test_branch_persistsOriginPointer_readableThroughBranchOriginTitle() async throws {
        let (sourceID, messageIDs) = try await seedSourceSession(title: "Planning the Q3 roadmap", messageCount: 3)
        let newSessionID = UUID()

        _ = try await coordinator.branch(
            sourceSessionID: sourceID,
            branchMessageID: messageIDs[1],
            newSessionID: newSessionID,
            newSessionTitle: nil
        )

        let fetchedBranched = try await stack.provider.fetchSession(id: newSessionID)
        let branched = try XCTUnwrap(fetchedBranched)
        XCTAssertEqual(branched.branchOriginSessionID, sourceID,
            "branch(...) must persist a pointer back to the source session")
        XCTAssertEqual(branched.branchOriginTitleSnapshot, "Planning the Q3 roadmap",
            "branch(...) must snapshot the source session's title at branch time")

        let resolvedTitle = await listService.branchOriginTitle(for: branched)
        XCTAssertEqual(resolvedTitle, "Planning the Q3 roadmap",
            "branchOriginTitle(for:) must resolve the chip's display title")
    }

    func test_branch_reachesOldestMessageBeyondFormerHistoryCap() async throws {
        let source = ChatSession(title: "Long history")
        try await stack.provider.insertSession(source)
        let start = Date(timeIntervalSince1970: 1)
        let history = (0...10_000).map { index in
            ChatMessage(role: .user, content: "m\(index)", timestamp: start.addingTimeInterval(Double(index)), sessionID: source.id)
        }
        try await stack.provider.performMessageMutations(history.map(MessageStoreMutation.insert))
        let childID = UUID()
        _ = try await coordinator.branch(sourceSessionID: source.id, branchMessageID: history[0].id, newSessionID: childID, newSessionTitle: nil)
        let copied = try await stack.provider.fetchMessages(for: childID)
        XCTAssertEqual(copied.map(\.content), [history[0].content])
        XCTAssertNotEqual(copied.first?.id, history[0].id)
        let unchanged = try await stack.provider.fetchMessages(for: source.id)
        XCTAssertEqual(unchanged.map(\.id), history.map(\.id))
    }

    func test_branch_preservesSourceOrderForEqualTimestampsWithFreshIDs() async throws {
        let source = ChatSession(title: "Ties")
        try await stack.provider.insertSession(source)
        let time = Date(timeIntervalSince1970: 1)
        let sourceMessages = (1...4).map { index in
            ChatMessage(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!, role: .user, content: "m\(index)", timestamp: time, sessionID: source.id)
        }
        try await stack.provider.performMessageMutations(sourceMessages.map(MessageStoreMutation.insert))
        let childID = UUID()
        _ = try await coordinator.branch(sourceSessionID: source.id, branchMessageID: sourceMessages.last!.id, newSessionID: childID, newSessionTitle: nil)
        let copied = try await stack.provider.fetchMessages(for: childID)
        XCTAssertEqual(copied.map(\.content), sourceMessages.map(\.content))
        XCTAssertTrue(Set(copied.map(\.id)).isDisjoint(with: Set(sourceMessages.map(\.id))))
    }

    func test_branch_nonBranchedSession_hasNoOriginTitle() async throws {
        let session = ChatSession(title: "Ordinary session")
        try await stack.provider.insertSession(session)

        let resolvedTitle = await listService.branchOriginTitle(for: session)
        XCTAssertNil(resolvedTitle, "A session that was not branched must not report an origin title")
    }

    // MARK: - Durable message snapshot

    func test_runtimeBranch_preservesDurableFieldsAndIndependentHistory() async throws {
        let source = ChatSession(title: "Annotated history")
        try await stack.provider.insertSession(source)
        let citation = Citation(documentID: UUID(), documentTitle: "Source", chunkIndex: 2,
                                snippet: "Supporting passage", score: 0.75)
        let kinds: [MessageKind] = [.chat, .annotation("review"), .memory("summary"),
                                   .custom("host-note"), .toolResult(callID: "receipt")]
        let base = Date(timeIntervalSince1970: 100)
        var history: [ChatMessage] = []
        for (index, kind) in kinds.enumerated() {
            let message = ChatMessage(
                role: .assistant,
                contentParts: [.text("record \(index)"),
                               .image(data: Data([1, 2, 3, UInt8(index)]), mimeType: "image/png")],
                timestamp: base.addingTimeInterval(Double(index)),
                sessionID: source.id,
                promptTokens: index == 1 ? nil : 40 + index,
                completionTokens: index == 1 ? nil : 10 + index,
                kind: kind,
                citations: index == 1 ? nil : (index == 2 ? [] : [citation]),
                agentID: index == 1 ? nil : UUID()
            )
            history.append(message)
            try await stack.provider.insertMessage(message)
        }
        let trailing = ChatMessage(role: .user, content: "Not in the branch",
                                   timestamp: base.addingTimeInterval(10), sessionID: source.id)
        try await stack.provider.insertMessage(trailing)
        let branchPoint = try XCTUnwrap(history.last)
        let runtime = ConversationRuntime(
            messageStore: stack.provider, sessionStore: stack.provider,
            inferenceService: InferenceService(backend: MockInferenceBackend(), name: "Unused")
        )
        let childID = UUID()
        let handle = try await runtime.processTurn(TurnInput(sessionID: source.id, kind: .branch(
            messageID: branchPoint.id, newSessionID: childID, generateAfter: false
        )))
        XCTAssertNil(handle)
        let child = try await stack.provider.fetchMessages(for: childID)
        XCTAssertEqual(child.count, history.count, "Branch includes the point but excludes trailing history")
        XCTAssertEqual(Set(child.map(\.id)).count, history.count)
        XCTAssertTrue(Set(child.map(\.id)).isDisjoint(with: Set(history.map(\.id))))
        for (original, copied) in zip(history, child) {
            var expected = original
            expected.id = copied.id
            expected.sessionID = childID
            expected.status = nil
            XCTAssertEqual(copied, expected, "Branch must preserve all durable fields, including nil vs empty citations")
            XCTAssertEqual(copied.kind.isWireVisible, original.kind.isWireVisible)
            XCTAssertEqual(copied.kind.backendRole, original.kind.backendRole)
        }
        let sourceAfterBranch = try await stack.provider.fetchMessages(for: source.id)
        XCTAssertEqual(sourceAfterBranch, history + [trailing])

        // A branch of a branch must retain the same semantics too.
        let childPoint = try XCTUnwrap(child.last)
        let grandchildID = UUID()
        _ = try await runtime.processTurn(TurnInput(sessionID: childID, kind: .branch(
            messageID: childPoint.id, newSessionID: grandchildID, generateAfter: false
        )))
        let grandchild = try await stack.provider.fetchMessages(for: grandchildID)
        XCTAssertEqual(grandchild.count, child.count)
        XCTAssertTrue(Set(grandchild.map(\.id)).isDisjoint(with: Set(child.map(\.id))))
        for (original, copied) in zip(child, grandchild) {
            var expected = original
            expected.id = copied.id
            expected.sessionID = grandchildID
            XCTAssertEqual(copied, expected)
        }

        // Edits and deletion of the source must not mutate either snapshot.
        var edited = try XCTUnwrap(history.first)
        edited.contentParts = [.text("Revised")]
        edited.citations = []
        edited.agentID = nil
        edited.kind = .annotation("changed")
        edited.promptTokens = 999
        try await stack.provider.updateMessage(edited)
        let childAfterEdit = try await stack.provider.fetchMessages(for: childID)
        XCTAssertEqual(childAfterEdit, child)
        try await stack.provider.deleteSession(source.id)
        let childAfterDeletion = try await stack.provider.fetchMessages(for: childID)
        let grandchildAfterDeletion = try await stack.provider.fetchMessages(for: grandchildID)
        XCTAssertEqual(childAfterDeletion, child)
        XCTAssertEqual(grandchildAfterDeletion, grandchild)
    }

    // MARK: - Original session unaffected

    func test_branch_leavesSourceSessionUnaffected() async throws {
        let (sourceID, messageIDs) = try await seedSourceSession(title: "Source", messageCount: 3)

        _ = try await coordinator.branch(
            sourceSessionID: sourceID,
            branchMessageID: messageIDs[1],
            newSessionID: UUID(),
            newSessionTitle: nil
        )

        let fetchedSource = try await stack.provider.fetchSession(id: sourceID)
        let source = try XCTUnwrap(fetchedSource)
        XCTAssertNil(source.branchOriginSessionID, "Branching FROM a session must not mutate its own origin pointer")
        XCTAssertNil(source.branchOriginTitleSnapshot)
        let sourceMessages = try await stack.provider.fetchMessages(for: sourceID)
        XCTAssertEqual(sourceMessages.count, 3, "The source session's own history must be untouched by a branch")
    }

    // MARK: - Chained branches

    func test_branchOfABranch_pointsAtItsDirectParentNotTheRoot() async throws {
        let (rootID, rootMessageIDs) = try await seedSourceSession(title: "Root", messageCount: 3)

        let childID = UUID()
        _ = try await coordinator.branch(
            sourceSessionID: rootID,
            branchMessageID: rootMessageIDs[1],
            newSessionID: childID,
            newSessionTitle: "Child"
        )
        let childMessages = try await stack.provider.fetchMessages(for: childID)

        let grandchildID = UUID()
        _ = try await coordinator.branch(
            sourceSessionID: childID,
            branchMessageID: childMessages.last!.id,
            newSessionID: grandchildID,
            newSessionTitle: nil
        )

        let fetchedGrandchild = try await stack.provider.fetchSession(id: grandchildID)
        let grandchild = try XCTUnwrap(fetchedGrandchild)
        XCTAssertEqual(grandchild.branchOriginSessionID, childID,
            "A branch of a branch must point at its direct parent, not the root session")
        XCTAssertEqual(grandchild.branchOriginTitleSnapshot, "Child")

        let resolvedTitle = await listService.branchOriginTitle(for: grandchild)
        XCTAssertEqual(resolvedTitle, "Child", "Live resolution must reflect the direct parent, not the root")
    }

    // MARK: - Source deleted (tombstone fallback)

    func test_branchOriginTitle_fallsBackToSnapshot_whenSourceSessionDeleted() async throws {
        let (sourceID, messageIDs) = try await seedSourceSession(title: "About to be deleted", messageCount: 3)
        let newSessionID = UUID()

        _ = try await coordinator.branch(
            sourceSessionID: sourceID,
            branchMessageID: messageIDs[1],
            newSessionID: newSessionID,
            newSessionTitle: nil
        )

        try await stack.provider.deleteSession(sourceID)

        let fetchedBranched = try await stack.provider.fetchSession(id: newSessionID)
        let branched = try XCTUnwrap(fetchedBranched)
        let fetchedSourceAfterDelete = try await stack.provider.fetchSession(id: sourceID)
        XCTAssertNil(fetchedSourceAfterDelete,
            "Precondition: the source session must actually be gone")

        let resolvedTitle = await listService.branchOriginTitle(for: branched)
        XCTAssertEqual(resolvedTitle, "About to be deleted",
            "branchOriginTitle(for:) must fall back to the title snapshot once the source session is deleted")
    }

    /// Renaming the source (while it still exists) must be reflected live —
    /// this is the reason the read path prefers a live lookup over the
    /// snapshot whenever the source is still resolvable.
    func test_branchOriginTitle_reflectsSourceRename_whenSourceStillExists() async throws {
        let (sourceID, messageIDs) = try await seedSourceSession(title: "Original title", messageCount: 3)
        let newSessionID = UUID()

        _ = try await coordinator.branch(
            sourceSessionID: sourceID,
            branchMessageID: messageIDs[1],
            newSessionID: newSessionID,
            newSessionTitle: nil
        )

        let fetchedSource = try await stack.provider.fetchSession(id: sourceID)
        var source = try XCTUnwrap(fetchedSource)
        source.title = "Renamed title"
        try await stack.provider.updateSession(source)

        let fetchedBranched = try await stack.provider.fetchSession(id: newSessionID)
        let branched = try XCTUnwrap(fetchedBranched)
        let resolvedTitle = await listService.branchOriginTitle(for: branched)
        XCTAssertEqual(resolvedTitle, "Renamed title",
            "Live resolution must reflect a rename of the still-existing source session")
        XCTAssertEqual(branched.branchOriginTitleSnapshot, "Original title",
            "The snapshot itself stays fixed at branch time — only the live-resolved value changes")
    }

    // MARK: - BranchOrigin side-table cleanup on delete

    /// Returns every `BranchOrigin` side-table row currently in the store —
    /// reaches past the `SessionStore`/`SessionListService` seam directly
    /// into the SwiftData context so a leaked row (one whose owning session
    /// was deleted but whose provenance row was left orphaned) is visible
    /// even though nothing in the public read path would surface it.
    private func fetchAllBranchOriginRows() throws -> [ManifoldSchemaV13.BranchOrigin] {
        try stack.context.fetch(FetchDescriptor<ManifoldSchemaV13.BranchOrigin>())
    }

    func test_deleteSession_removesTheBranchedSessionsOwnBranchOriginRow() async throws {
        let (sourceID, messageIDs) = try await seedSourceSession(title: "Source", messageCount: 3)
        let branchedID = UUID()

        _ = try await coordinator.branch(
            sourceSessionID: sourceID,
            branchMessageID: messageIDs[1],
            newSessionID: branchedID,
            newSessionTitle: nil
        )
        XCTAssertEqual(try fetchAllBranchOriginRows().count, 1,
            "Precondition: branching must have written exactly one BranchOrigin row")

        try await stack.provider.deleteSession(branchedID)

        XCTAssertTrue(try fetchAllBranchOriginRows().isEmpty,
            "Deleting a branched session must also delete its own BranchOrigin row — otherwise it leaks forever (BranchOrigin is a plain-UUID side table, not a SwiftData relationship, so nothing cascades it automatically)")
    }

    func test_deleteAllSessions_clearsTheBranchOriginTable() async throws {
        let (sourceID, messageIDs) = try await seedSourceSession(title: "Source", messageCount: 3)
        _ = try await coordinator.branch(
            sourceSessionID: sourceID,
            branchMessageID: messageIDs[1],
            newSessionID: UUID(),
            newSessionTitle: nil
        )
        XCTAssertEqual(try fetchAllBranchOriginRows().count, 1,
            "Precondition: branching must have written exactly one BranchOrigin row")

        try await stack.provider.deleteAll()

        XCTAssertTrue(try fetchAllBranchOriginRows().isEmpty,
            "deleteAll() must clear the BranchOrigin table along with every session and message")
    }
}
