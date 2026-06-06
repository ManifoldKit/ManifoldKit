import XCTest
@testable import ManifoldPersistenceSwiftData
@testable import ManifoldInference

/// Integration tests for ``ManifoldBootstrap/makeInMemory(configuration:inferenceService:ragConfiguration:)``.
///
/// Validates the public in-memory bootstrap path introduced in P6.1: that the
/// factory correctly signals ephemeral storage via ``ManifoldBootstrap/isInMemory``
/// and that the full persistence stack is functional for message round-trips.
@MainActor
final class ManifoldBootstrapInMemoryTests: XCTestCase {

    // Stash the original configuration so each test can restore it cleanly.
    private var originalConfiguration: ManifoldConfiguration!

    override func setUp() {
        super.setUp()
        originalConfiguration = ManifoldConfiguration.shared
    }

    override func tearDown() {
        ManifoldConfiguration.shared = originalConfiguration
        super.tearDown()
    }

    // MARK: - isInMemory

    func test_makeInMemory_isInMemory() throws {
        let bootstrap = try ManifoldBootstrap.makeInMemory(
            configuration: ManifoldConfiguration(
                appName: "InMemory Test",
                bundleIdentifier: "com.manifoldkit.bootstrap-inmemory-tests.ismemory.\(UUID().uuidString)"
            )
        )

        XCTAssertTrue(bootstrap.isInMemory,
            "makeInMemory must set isInMemory = true so callers can detect ephemeral mode")
    }

    func test_standardInit_isNotInMemory() throws {
        // Guards that the normal init path leaves isInMemory == false, confirming
        // that makeInMemory is the only route that sets the flag.
        let bootstrap = try ManifoldBootstrap(
            configuration: ManifoldConfiguration(
                appName: "Standard Init",
                bundleIdentifier: "com.manifoldkit.bootstrap-inmemory-tests.standard.\(UUID().uuidString)"
            ),
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )

        XCTAssertFalse(bootstrap.isInMemory,
            "The standard init must leave isInMemory = false")
    }

    // MARK: - Message round-trip

    func test_makeInMemory_messageStoreWorks() async throws {
        let bootstrap = try ManifoldBootstrap.makeInMemory(
            configuration: ManifoldConfiguration(
                appName: "Message Round-trip",
                bundleIdentifier: "com.manifoldkit.bootstrap-inmemory-tests.roundtrip.\(UUID().uuidString)"
            )
        )

        // Insert a session so the message foreign-key constraint is satisfied.
        let session = ManifoldInference.ChatSession(title: "Incognito Session")
        try await bootstrap.persistence.insertSession(session)

        // Insert a message and fetch it back through the same provider.
        let message = ManifoldInference.ChatMessage(
            role: .user,
            content: "Hello from in-memory land",
            sessionID: session.id
        )
        try await bootstrap.persistence.insertMessage(message)

        let fetched = try await bootstrap.persistence.fetchMessages(for: session.id)

        XCTAssertEqual(fetched.count, 1,
            "One message was inserted; fetchMessages must return exactly one record")
        XCTAssertEqual(fetched.first?.id, message.id,
            "The fetched message must have the same ID as the inserted record")
        XCTAssertEqual(fetched.first?.role, .user,
            "The message role must survive the round-trip")
    }
}
