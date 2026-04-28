import XCTest
import SwiftData
@testable import BaseChatCore
import BaseChatInference
import BaseChatTestSupport

/// Integration tests for ``SwiftDataPersistenceProvider/searchMessages(query:limit:)``
/// and ``SwiftDataPersistenceProvider/fetchSessions(offset:limit:)``.
///
/// Drives a real SwiftData store via ``InMemoryPersistenceHarness`` so the
/// `#Predicate` substring search and `fetchOffset/fetchLimit` paging hit
/// the same code paths that ship in production.
@MainActor
final class SwiftDataPersistenceProviderSearchTests: XCTestCase {

    private var stack: InMemoryPersistenceHarness.Stack!

    override func setUp() async throws {
        try await super.setUp()
        stack = try InMemoryPersistenceHarness.make()
    }

    override func tearDown() async throws {
        stack = nil
        try await super.tearDown()
    }

    private var provider: SwiftDataPersistenceProvider { stack.provider }

    // MARK: - searchMessages

    func test_searchMessages_returnsCaseInsensitiveMatches() async throws {
        let session = ChatSessionRecord(title: "Search Test")
        try await provider.insertSession(session)
        try await provider.insertMessage(ChatMessageRecord(role: .user, content: "Tell me about DRAGONS in fantasy", sessionID: session.id))
        try await provider.insertMessage(ChatMessageRecord(role: .assistant, content: "Dragons are mythical creatures.", sessionID: session.id))
        try await provider.insertMessage(ChatMessageRecord(role: .user, content: "What about elves?", sessionID: session.id))

        let hits = try await provider.searchMessages(query: "dragon", limit: 100)

        XCTAssertEqual(hits.count, 2, "Both messages mentioning 'dragon' (any case) should match")
        XCTAssertTrue(hits.allSatisfy { $0.snippet.localizedStandardContains("dragon") })
    }

    func test_searchMessages_emptyQueryReturnsNoHits() async throws {
        let session = ChatSessionRecord(title: "Empty Query")
        try await provider.insertSession(session)
        try await provider.insertMessage(ChatMessageRecord(role: .user, content: "anything", sessionID: session.id))

        let emptyHits = try await provider.searchMessages(query: "", limit: 100)
        XCTAssertTrue(emptyHits.isEmpty)
        let whitespaceHits = try await provider.searchMessages(query: "   ", limit: 100)
        XCTAssertTrue(whitespaceHits.isEmpty)
    }

    func test_searchMessages_respectsLimit() async throws {
        let session = ChatSessionRecord(title: "Limit Test")
        try await provider.insertSession(session)
        for i in 0..<25 {
            try await provider.insertMessage(ChatMessageRecord(
                role: .user,
                content: "needle row \(i)",
                timestamp: Date(timeIntervalSince1970: Double(1_000 + i)),
                sessionID: session.id
            ))
        }

        let hits = try await provider.searchMessages(query: "needle", limit: 10)
        XCTAssertEqual(hits.count, 10, "Limit should cap result count")
    }

    func test_searchMessages_snippetCentersOnMatchAndElides() async throws {
        let session = ChatSessionRecord(title: "Snippet")
        try await provider.insertSession(session)
        let prefix = String(repeating: "alpha ", count: 40)   // ~240 chars before
        let suffix = String(repeating: "omega ", count: 40)   // ~240 chars after
        let body = "\(prefix)NEEDLE\(suffix)"
        try await provider.insertMessage(ChatMessageRecord(role: .user, content: body, sessionID: session.id))

        let hits = try await provider.searchMessages(query: "needle", limit: 10)
        XCTAssertEqual(hits.count, 1)
        let hit = try XCTUnwrap(hits.first)
        XCTAssertTrue(hit.snippet.hasPrefix("…"), "Snippet should be elided on the left")
        XCTAssertTrue(hit.snippet.hasSuffix("…"), "Snippet should be elided on the right")
        XCTAssertTrue(hit.snippet.localizedStandardContains("needle"), "Snippet must contain the matched term")
        XCTAssertTrue(hit.snippet.count < body.count, "Snippet must be shorter than the source content")

        // matchRange must locate the term within the snippet so the UI can highlight
        // without re-running a search.
        let matched = hit.snippet[hit.matchRange]
        XCTAssertEqual(String(matched).lowercased(), "needle")
    }

    func test_searchMessages_sortsMostRecentFirst() async throws {
        let session = ChatSessionRecord(title: "Sorted")
        try await provider.insertSession(session)
        try await provider.insertMessage(ChatMessageRecord(role: .user, content: "needle one",
                                                    timestamp: Date(timeIntervalSince1970: 1_000), sessionID: session.id))
        try await provider.insertMessage(ChatMessageRecord(role: .user, content: "needle three",
                                                    timestamp: Date(timeIntervalSince1970: 3_000), sessionID: session.id))
        try await provider.insertMessage(ChatMessageRecord(role: .user, content: "needle two",
                                                    timestamp: Date(timeIntervalSince1970: 2_000), sessionID: session.id))

        let hits = try await provider.searchMessages(query: "needle", limit: 100)
        XCTAssertEqual(hits.map(\.snippet).map { $0.replacingOccurrences(of: "…", with: "") },
                       ["needle three", "needle two", "needle one"])
    }

    func test_searchMessages_returnsNoHitsWhenQueryDoesNotMatch() async throws {
        let session = ChatSessionRecord(title: "Miss")
        try await provider.insertSession(session)
        try await provider.insertMessage(ChatMessageRecord(role: .user, content: "hello world", sessionID: session.id))

        let hits = try await provider.searchMessages(query: "absent", limit: 100)
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: - fetchSessions(offset:limit:)

    func test_fetchSessionsPage_returnsRequestedSlice() async throws {
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<10 {
            // Higher i = newer, so descending order = 9,8,7,...,0
            try await provider.insertSession(ChatSessionRecord(
                title: "S\(i)",
                updatedAt: base.addingTimeInterval(Double(i))
            ))
        }

        let firstPage = try await provider.fetchSessions(offset: 0, limit: 4)
        XCTAssertEqual(firstPage.map(\.title), ["S9", "S8", "S7", "S6"])

        let secondPage = try await provider.fetchSessions(offset: 4, limit: 4)
        XCTAssertEqual(secondPage.map(\.title), ["S5", "S4", "S3", "S2"])

        let lastPage = try await provider.fetchSessions(offset: 8, limit: 4)
        XCTAssertEqual(lastPage.map(\.title), ["S1", "S0"])
    }

    func test_fetchSessionsPage_returnsEmptyBeyondEnd() async throws {
        try await provider.insertSession(ChatSessionRecord(title: "only"))
        let hits = try await provider.fetchSessions(offset: 50, limit: 50)
        XCTAssertTrue(hits.isEmpty)
    }
}
