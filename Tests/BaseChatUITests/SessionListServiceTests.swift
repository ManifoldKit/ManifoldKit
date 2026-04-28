@preconcurrency import XCTest
import SwiftData
@testable import BaseChatUI
@testable import BaseChatCore
@testable import BaseChatInference
import BaseChatTestSupport

/// Integration tests exercising ``SessionListService`` directly, below the adapter layer.
///
/// These verify that the runtime-as-events pattern works: commands persist data
/// and surface the expected ``SessionListEvent`` cases through `service.events`.
@MainActor
final class SessionListServiceTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var service: SessionListService!

    override func setUp() async throws {
        try await super.setUp()
        container = try makeInMemoryContainer()
        context = container.mainContext
        service = SessionListService()
        service.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))
        // No initial event is emitted by configure — the event stream starts
        // empty. Tests collect only the events they trigger.
    }

    override func tearDown() async throws {
        container = nil
        context = nil
        service = nil
        try await super.tearDown()
    }

    // MARK: - Test 1: createSession emits .sessionInserted then .sessionsLoaded

    func test_createSession_emitsInsertAndReload() async throws {
        // Collect the next two events: the reload triggered after insert.
        // The service emits .sessionInserted then triggers a reload which
        // emits .sessionsLoaded — we want to see both.
        let expectInserted = expectation(description: "sessionInserted received")
        let expectLoaded = expectation(description: "sessionsLoaded received after insert")

        var insertedRecord: ChatSessionRecord?
        var loadedSessions: [ChatSessionRecord]?

        let collector = Task { [service = service!] in
            for await event in service.events {
                switch event {
                case .sessionInserted(let record):
                    insertedRecord = record
                    expectInserted.fulfill()
                case .sessionsLoaded(let sessions, _):
                    loadedSessions = sessions
                    expectLoaded.fulfill()
                    return
                default:
                    break
                }
            }
        }

        let created = try await service.createSession(title: "Spike Test")

        await fulfillment(of: [expectInserted, expectLoaded], timeout: 2)
        collector.cancel()

        XCTAssertEqual(created.title, "Spike Test")
        XCTAssertEqual(insertedRecord?.id, created.id, "sessionInserted should carry the new record")
        XCTAssertEqual(loadedSessions?.count, 1)
        XCTAssertEqual(loadedSessions?.first?.id, created.id)

        // Sabotage check: if the service never yields .sessionInserted, the
        // expectation times out. Verified by temporarily removing the
        // `continuation.yield(.sessionInserted(record))` line in
        // SessionListService.createSession and confirming test failure.
    }

    // MARK: - Test 2: runTitleSearch emits .searchResultsChanged

    func test_runTitleSearch_emitsSearchResultsChanged() async throws {
        // Start collecting events before seeding sessions, so we know when
        // the seeds are complete and can then issue the search.
        let expectSearch = expectation(description: "searchResultsChanged received")
        var searchResults: SearchResults?

        // We need to skip the 6 setup events (3× sessionInserted + 3× sessionsLoaded)
        // before we see the search result. The collector below skips anything
        // that isn't a searchResultsChanged so we don't need an exact count.
        let collector = Task { [service = service!] in
            for await event in service.events {
                if case .searchResultsChanged(let results) = event {
                    // Only report a non-empty result (the search, not the cleared state).
                    if !results.titleMatches.isEmpty {
                        searchResults = results
                        expectSearch.fulfill()
                        return
                    }
                }
            }
        }

        // Seed three sessions. The async collector is already running.
        _ = try await service.createSession(title: "Swift Concurrency")
        _ = try await service.createSession(title: "SwiftUI Layout")
        _ = try await service.createSession(title: "CoreData Migration")

        // Now issue the search. Pass all sessions from persistence directly.
        let allSessions = try service._persistenceAccessor!.fetchSessions()
        service.runTitleSearch("Swift", against: allSessions)

        await fulfillment(of: [expectSearch], timeout: 2)
        collector.cancel()

        let results = try XCTUnwrap(searchResults)
        XCTAssertEqual(results.titleMatches.count, 2, "Should match 'Swift Concurrency' and 'SwiftUI Layout'")
        XCTAssertTrue(results.titleMatches.allSatisfy { $0.title.contains("Swift") })

        // Sabotage check: if runTitleSearch never yields a searchResultsChanged
        // event, the expectation times out. Verified by temporarily removing
        // the `continuation.yield(.searchResultsChanged(...))` call and confirming failure.
    }
}
