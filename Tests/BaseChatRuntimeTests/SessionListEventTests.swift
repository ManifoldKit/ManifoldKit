import XCTest
@testable import BaseChatRuntime
import BaseChatInference

/// Locks the public ``SessionListEvent`` case set and the ``SearchResults``
/// value type.
///
/// `SessionListService` itself is `package`-visible — direct unit coverage of
/// the service lives in ``SessionListServiceTests`` (in `BaseChatUITests`,
/// which can see `package` symbols). This file defends only the *public*
/// event surface that adapters in arbitrary host modules subscribe to.
final class SessionListEventTests: XCTestCase {

    // MARK: - SearchResults

    func test_searchResults_empty_isAllEmptyCollections() {
        let empty = SearchResults.empty
        XCTAssertTrue(empty.titleMatches.isEmpty)
        XCTAssertTrue(empty.messageHitsBySession.isEmpty)
        XCTAssertTrue(empty.messageMatchSessions.isEmpty)
    }

    func test_searchResults_storesAllFields() {
        let session = ChatSessionRecord(title: "S")
        let snippet = "needle in haystack"
        let range = snippet.range(of: "needle")!
        let hit = MessageSearchHit(
            messageID: UUID(),
            sessionID: session.id,
            snippet: snippet,
            matchRange: range,
            timestamp: .init(timeIntervalSinceReferenceDate: 0)
        )

        let results = SearchResults(
            titleMatches: [session],
            messageHitsBySession: [session.id: [hit]],
            messageMatchSessions: [session]
        )

        XCTAssertEqual(results.titleMatches.map(\.id), [session.id])
        XCTAssertEqual(results.messageHitsBySession[session.id]?.count, 1)
        XCTAssertEqual(results.messageMatchSessions.map(\.id), [session.id])
    }

    // MARK: - SessionListEvent

    /// Compile-time exhaustiveness guard: every case must be reachable in the
    /// switch below. Adding a case without updating this switch fails to
    /// compile, surfacing the new case at review time.
    func test_sessionListEvent_switchExhaustiveness() {
        let session = ChatSessionRecord(title: "S")
        let probes: [SessionListEvent] = [
            .sessionsLoaded([session], hasMore: false, offset: 0),
            .sessionRenamed(session.id, title: "renamed"),
            .sessionDeleted(session.id),
            .searchResultsChanged(.empty),
            .titleGenerated(session.id, title: "auto"),
            .persistenceFailure(URLError(.cannotOpenFile)),
        ]

        for event in probes {
            switch event {
            case let .sessionsLoaded(sessions, hasMore, offset):
                XCTAssertEqual(sessions.map(\.id), [session.id])
                XCTAssertFalse(hasMore)
                XCTAssertEqual(offset, 0)
            case let .sessionRenamed(id, title):
                XCTAssertEqual(id, session.id)
                XCTAssertEqual(title, "renamed")
            case let .sessionDeleted(id):
                XCTAssertEqual(id, session.id)
            case let .searchResultsChanged(results):
                XCTAssertTrue(results.titleMatches.isEmpty)
            case let .titleGenerated(id, title):
                XCTAssertEqual(id, session.id)
                XCTAssertEqual(title, "auto")
            case let .persistenceFailure(error):
                XCTAssertTrue(error is URLError)
            }
        }
    }
}
