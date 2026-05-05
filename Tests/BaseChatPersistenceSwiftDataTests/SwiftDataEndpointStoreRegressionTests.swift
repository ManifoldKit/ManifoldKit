import XCTest
import SwiftData
import BaseChatRuntime
@testable import BaseChatPersistenceSwiftData
import BaseChatInference

@MainActor
final class SwiftDataEndpointStoreRegressionTests: XCTestCase {

    func test_inMemoryStore_createEditDeleteLoadAndRestoreBySameID() async throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let firstStore = SwiftDataEndpointStore(modelContext: ModelContext(container))

        let endpointID = UUID()
        let original = APIEndpointRecord(
            id: endpointID,
            name: "Original",
            provider: .openAI,
            baseURL: "https://api.openai.com/v1",
            modelName: "gpt-4o-mini",
            createdAt: Date(timeIntervalSinceReferenceDate: 10)
        )

        try await firstStore.insertEndpoint(original)

        var edited = original
        edited.name = "Edited"
        edited.provider = .custom
        edited.baseURL = "https://example.com/v1"
        edited.modelName = "custom-model"
        edited.isEnabled = false
        try await firstStore.updateEndpoint(edited)

        let reloadedStore = SwiftDataEndpointStore(modelContext: ModelContext(container))
        let reloadedEndpoints = try await reloadedStore.fetchEndpoints()
        let reloaded = try XCTUnwrap(reloadedEndpoints.first)
        XCTAssertEqual(reloaded.id, endpointID)
        XCTAssertEqual(reloaded.name, "Edited")
        XCTAssertEqual(reloaded.provider, .custom)
        XCTAssertEqual(reloaded.baseURL, "https://example.com/v1")
        XCTAssertEqual(reloaded.modelName, "custom-model")
        XCTAssertFalse(reloaded.isEnabled)

        try await reloadedStore.deleteEndpoint(endpointID)
        let endpointsAfterDelete = try await reloadedStore.fetchEndpoints()
        XCTAssertTrue(endpointsAfterDelete.isEmpty)

        var restored = original
        restored.name = "Restored"
        restored.modelName = "restored-model"
        try await reloadedStore.insertEndpoint(restored)

        let restoredRows = try await SwiftDataEndpointStore(modelContext: ModelContext(container)).fetchEndpoints()
        XCTAssertEqual(restoredRows.map(\.id), [endpointID])
        XCTAssertEqual(restoredRows.first?.name, "Restored")
        XCTAssertEqual(restoredRows.first?.keychainAccount, endpointID.uuidString)
    }

    func test_fetchEndpoints_preservesDisabledStateForCallerFiltering() async throws {
        let store = SwiftDataEndpointStore(modelContext: ModelContext(try ModelContainerFactory.makeInMemoryContainer()))
        let enabled = APIEndpointRecord(name: "Enabled", provider: .openAI, isEnabled: true)
        let disabled = APIEndpointRecord(name: "Disabled", provider: .claude, isEnabled: false)

        try await store.insertEndpoint(enabled)
        try await store.insertEndpoint(disabled)

        let fetched = try await store.fetchEndpoints()
        XCTAssertEqual(Set(fetched.map(\.id)), Set([enabled.id, disabled.id]))
        XCTAssertEqual(fetched.first(where: { $0.id == disabled.id })?.isEnabled, false)
        XCTAssertEqual(fetched.filter(\.isEnabled).map(\.id), [enabled.id])
    }
}
