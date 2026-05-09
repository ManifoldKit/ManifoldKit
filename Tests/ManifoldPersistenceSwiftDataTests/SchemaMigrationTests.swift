import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldTestSupport

/// Tests for the SwiftData schema and ModelContainerFactory infrastructure.
final class SchemaMigrationTests: XCTestCase {
    private var tempStoreDirectory: URL?

    override func tearDownWithError() throws {
        if let tempStoreDirectory {
            try? FileManager.default.removeItem(at: tempStoreDirectory)
        }
        tempStoreDirectory = nil
        try super.tearDownWithError()
    }

    private func makeStoreDirectory(named prefix: String) throws -> URL {
        let storeDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        tempStoreDirectory = storeDirectory
        return storeDirectory
    }

    // MARK: - ManifoldSchemaV4

    func test_schemaV4_versionIdentifier() {
        XCTAssertEqual(ManifoldSchemaV4.versionIdentifier, Schema.Version(4, 0, 0))
    }

    func test_schemaV4_modelsContainsAllExpectedTypes() {
        let models = ManifoldSchemaV4.models
        XCTAssertEqual(models.count, 5)
        let ids = models.map { ObjectIdentifier($0) }
        XCTAssertTrue(ids.contains(ObjectIdentifier(ManifoldSchemaV4.ChatMessage.self)))
        XCTAssertTrue(ids.contains(ObjectIdentifier(ManifoldSchemaV4.ChatSession.self)))
        XCTAssertTrue(ids.contains(ObjectIdentifier(ManifoldSchemaV4.SamplerPreset.self)))
        XCTAssertTrue(ids.contains(ObjectIdentifier(ManifoldSchemaV4.APIEndpoint.self)))
        XCTAssertTrue(ids.contains(ObjectIdentifier(ManifoldSchemaV4.ModelBenchmarkCache.self)))
    }

    func test_publicTypealiases_matchV4ModelTypes() {
        XCTAssertEqual(ObjectIdentifier(ChatMessage.self), ObjectIdentifier(ManifoldSchemaV4.ChatMessage.self))
        XCTAssertEqual(ObjectIdentifier(ChatSession.self), ObjectIdentifier(ManifoldSchemaV4.ChatSession.self))
        XCTAssertEqual(ObjectIdentifier(SamplerPreset.self), ObjectIdentifier(ManifoldSchemaV4.SamplerPreset.self))
        XCTAssertEqual(ObjectIdentifier(APIEndpoint.self), ObjectIdentifier(ManifoldSchemaV4.APIEndpoint.self))
        XCTAssertEqual(ObjectIdentifier(ModelBenchmarkCache.self), ObjectIdentifier(ManifoldSchemaV4.ModelBenchmarkCache.self))
    }

    // MARK: - ModelContainerFactory

    func test_containerFactory_opensSuccessfully() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let sessionID = UUID()
        let message = ChatMessage(role: .user, content: "ping", sessionID: sessionID)
        context.insert(message)
        try context.save()
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        let fetched = try context.fetch(descriptor)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.content, "ping")
    }

    func test_containerFactory_makeContainer_inMemoryConfig() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainerFactory.makeContainer(configurations: [config])
        XCTAssertNotNil(container)
    }

    func test_containerFactory_currentSchema_isV5() {
        XCTAssertEqual(ObjectIdentifier(ModelContainerFactory.currentSchema), ObjectIdentifier(ManifoldSchemaV5.self))
    }

    func test_containerFactory_reopensPersistedStore() throws {
        let storeDirectory = try makeStoreDirectory(named: "ManifoldSchemaV4")
        let storeURL = storeDirectory.appendingPathComponent("Manifold.sqlite")
        let originalSessionID: UUID

        do {
            let config = ModelConfiguration(url: storeURL)
            let container = try ModelContainerFactory.makeContainer(configurations: [config])
            let context = ModelContext(container)

            let session = ChatSession(title: "Persisted session")
            context.insert(session)
            try context.save()
            originalSessionID = session.id
        }

        let reopenConfig = ModelConfiguration(url: storeURL)
        let reopenedContainer = try ModelContainerFactory.makeContainer(configurations: [reopenConfig])
        let reopenedContext = ModelContext(reopenedContainer)
        let fetchedSessions = try reopenedContext.fetch(FetchDescriptor<ChatSession>(
            predicate: #Predicate { $0.id == originalSessionID }
        ))

        XCTAssertEqual(fetchedSessions.count, 1)
        XCTAssertEqual(fetchedSessions.first?.title, "Persisted session")
    }

    func test_migrationPlan_migratesV3SamplerPresetToV4WithNilPenaltyKnobs() throws {
        let storeDirectory = try makeStoreDirectory(named: "ManifoldSchemaV3ToV4")
        let storeURL = storeDirectory.appendingPathComponent("Manifold.sqlite")
        let presetID: UUID

        do {
            let config = ModelConfiguration(url: storeURL)
            let container = try ModelContainer(
                for: Schema(versionedSchema: ManifoldSchemaV3.self),
                configurations: [config]
            )
            let context = ModelContext(container)
            let preset = ManifoldSchemaV3.SamplerPreset(
                name: "Legacy",
                temperature: 0.4,
                topP: 0.8,
                repeatPenalty: 1.2
            )
            context.insert(preset)
            try context.save()
            presetID = preset.id
        }

        let migratedContainer = try ModelContainerFactory.makeContainer(
            configurations: [ModelConfiguration(url: storeURL)]
        )
        let migratedContext = ModelContext(migratedContainer)
        let fetched = try migratedContext.fetch(FetchDescriptor<SamplerPreset>(
            predicate: #Predicate { $0.id == presetID }
        ))

        XCTAssertEqual(fetched.count, 1)
        let migratedPreset = try XCTUnwrap(fetched.first)
        XCTAssertEqual(migratedPreset.name, "Legacy")
        XCTAssertEqual(migratedPreset.temperature, 0.4, accuracy: 0.001)
        XCTAssertEqual(migratedPreset.topP, 0.8, accuracy: 0.001)
        XCTAssertEqual(migratedPreset.repeatPenalty, 1.2, accuracy: 0.001)
        XCTAssertNil(migratedPreset.presencePenalty)
        XCTAssertNil(migratedPreset.frequencyPenalty)
        XCTAssertNil(migratedPreset.repetitionContextSize)
        XCTAssertNil(migratedPreset.presenceContextSize)
        XCTAssertNil(migratedPreset.frequencyContextSize)
    }

    func test_schemaOwnedModelAndPublicAlias_areInterchangeable() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let nestedMessage = ManifoldSchemaV4.ChatMessage(role: .user, content: "alias check", sessionID: UUID())
        context.insert(nestedMessage)
        try context.save()
        let nestedMessageID = nestedMessage.id

        let fetchedViaAlias = try context.fetch(FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.id == nestedMessageID }
        ))
        XCTAssertEqual(fetchedViaAlias.count, 1)
        XCTAssertEqual(fetchedViaAlias.first?.content, "alias check")
    }

    // MARK: - Codable round-trip (ChatMessage)

    func test_chatMessage_codableRoundTrip() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let sessionID = UUID()
        let message = ChatMessage(role: .user, content: "Hello, world!", sessionID: sessionID)
        message.promptTokens = 10
        message.completionTokens = 42

        context.insert(message)
        try context.save()

        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        let fetched = try context.fetch(descriptor)
        XCTAssertEqual(fetched.count, 1)
        let fetched0 = try XCTUnwrap(fetched.first)
        XCTAssertEqual(fetched0.content, "Hello, world!")
        XCTAssertEqual(fetched0.role, .user)
        XCTAssertEqual(fetched0.promptTokens, 10)
        XCTAssertEqual(fetched0.completionTokens, 42)
    }

    // MARK: - Codable round-trip (ChatSession)

    func test_chatSession_codableRoundTrip() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let session = ChatSession(title: "Migration test")
        session.systemPrompt = "You are helpful."
        session.temperature = 0.8

        context.insert(session)
        try context.save()

        let sessionID = session.id
        let descriptor = FetchDescriptor<ChatSession>(
            predicate: #Predicate { $0.id == sessionID }
        )
        let fetched = try context.fetch(descriptor)
        XCTAssertEqual(fetched.count, 1)
        let fetched0 = try XCTUnwrap(fetched.first)
        XCTAssertEqual(fetched0.title, "Migration test")
        XCTAssertEqual(fetched0.systemPrompt, "You are helpful.")
        let temp = try XCTUnwrap(fetched0.temperature)
        XCTAssertEqual(Double(temp), 0.8, accuracy: 0.001)
    }

    // MARK: - Codable round-trip (SamplerPreset)

    func test_samplerPreset_codableRoundTrip() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let preset = SamplerPreset(
            name: "Creative",
            temperature: 1.2,
            topP: 0.95,
            repeatPenalty: 1.05,
            presencePenalty: 0.2,
            frequencyPenalty: 0.3,
            repetitionContextSize: 96,
            presenceContextSize: 48,
            frequencyContextSize: 24
        )
        context.insert(preset)
        try context.save()

        let presetID = preset.id
        let descriptor = FetchDescriptor<SamplerPreset>(
            predicate: #Predicate { $0.id == presetID }
        )
        let fetched = try context.fetch(descriptor)
        XCTAssertEqual(fetched.count, 1)
        let fetched0 = try XCTUnwrap(fetched.first)
        XCTAssertEqual(fetched0.name, "Creative")
        XCTAssertEqual(fetched0.temperature, 1.2, accuracy: 0.001)
        XCTAssertEqual(fetched0.topP, 0.95, accuracy: 0.001)
        XCTAssertEqual(fetched0.repeatPenalty, 1.05, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(fetched0.presencePenalty), 0.2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(fetched0.frequencyPenalty), 0.3, accuracy: 0.001)
        XCTAssertEqual(fetched0.repetitionContextSize, 96)
        XCTAssertEqual(fetched0.presenceContextSize, 48)
        XCTAssertEqual(fetched0.frequencyContextSize, 24)
    }

    // MARK: - Codable round-trip (APIEndpoint)

    func test_apiEndpoint_codableRoundTrip() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let endpoint = APIEndpoint(
            name: "Local LM Studio",
            provider: .lmStudio,
            baseURL: "http://localhost:1234",
            modelName: "custom-model"
        )
        context.insert(endpoint)
        try context.save()

        let endpointID = endpoint.id
        let descriptor = FetchDescriptor<APIEndpoint>(
            predicate: #Predicate { $0.id == endpointID }
        )
        let fetched = try context.fetch(descriptor)
        XCTAssertEqual(fetched.count, 1)
        let fetched0 = try XCTUnwrap(fetched.first)
        XCTAssertEqual(fetched0.name, "Local LM Studio")
        XCTAssertEqual(fetched0.provider, .lmStudio)
        XCTAssertEqual(fetched0.baseURL, "http://localhost:1234")
        XCTAssertEqual(fetched0.modelName, "custom-model")
        XCTAssertTrue(fetched0.isEnabled)
    }

    // MARK: - makeInMemoryContainer helper

    func test_makeInMemoryContainer_matchesFactory() throws {
        let container = try makeInMemoryContainer()
        XCTAssertNotNil(container)

        let context = ModelContext(container)
        let sessionID = UUID()
        let message = ChatMessage(role: .assistant, content: "Test", sessionID: sessionID)
        context.insert(message)
        XCTAssertNoThrow(try context.save())
    }

    // MARK: - Tool-call message round-trip

    /// Persists a `ChatMessage` whose `contentParts` mix `.text`, `.toolCall`,
    /// and `.toolResult`, then fetches it back and asserts that every payload
    /// field round-trips through SwiftData via `contentPartsJSON`. Guards
    /// against silent corruption of the tool-calling wire format — a renamed
    /// discriminator or coding key would strand persisted history.
    func test_chatMessage_toolCallRoundTrip() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let sessionID = UUID()
        let call = ToolCall(
            id: "call_abc123",
            toolName: "get_weather",
            arguments: #"{"city":"Dublin","units":"metric"}"#
        )
        let result = ToolResult(
            callId: "call_abc123",
            content: #"{"temperature":11,"conditions":"rain"}"#,
            errorKind: nil
        )
        let parts: [MessagePart] = [
            .text("Looking that up for you."),
            .toolCall(call),
            .toolResult(result),
        ]

        let message = ChatMessage(role: .assistant, contentParts: parts, sessionID: sessionID)
        context.insert(message)
        try context.save()

        let messageID = message.id
        let fetched = try context.fetch(FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.id == messageID }
        ))
        XCTAssertEqual(fetched.count, 1)
        let fetched0 = try XCTUnwrap(fetched.first)

        let roundTripped = fetched0.contentParts
        XCTAssertEqual(roundTripped, parts)
        XCTAssertEqual(roundTripped.count, 3)

        // Pin the on-disk discriminator strings. The encode→decode round-trip
        // above would still pass if both keys were renamed in lockstep, so
        // assert against the raw persisted JSON to lock the wire format
        // independently of the in-process Codable pair.
        let persistedJSON = fetched0.contentPartsJSON
        XCTAssertTrue(
            persistedJSON.contains("\"toolCall\""),
            "Expected pinned discriminator \"toolCall\" in persisted JSON, got: \(persistedJSON)"
        )
        XCTAssertTrue(
            persistedJSON.contains("\"toolResult\""),
            "Expected pinned discriminator \"toolResult\" in persisted JSON, got: \(persistedJSON)"
        )
        XCTAssertTrue(
            persistedJSON.contains("\"text\""),
            "Expected pinned discriminator \"text\" in persisted JSON, got: \(persistedJSON)"
        )

        guard case .text(let text) = roundTripped[0] else {
            return XCTFail("Expected .text at index 0, got \(roundTripped[0])")
        }
        XCTAssertEqual(text, "Looking that up for you.")

        let roundTrippedCall = try XCTUnwrap(roundTripped[1].toolCallContent)
        XCTAssertEqual(roundTrippedCall.id, "call_abc123")
        XCTAssertEqual(roundTrippedCall.toolName, "get_weather")
        XCTAssertEqual(roundTrippedCall.arguments, #"{"city":"Dublin","units":"metric"}"#)

        let roundTrippedResult = try XCTUnwrap(roundTripped[2].toolResultContent)
        XCTAssertEqual(roundTrippedResult.callId, "call_abc123")
        XCTAssertEqual(roundTrippedResult.content, #"{"temperature":11,"conditions":"rain"}"#)
        XCTAssertNil(roundTrippedResult.errorKind)
        XCTAssertFalse(roundTrippedResult.isError)
    }

    /// Pre-v4 persisted `ToolResult` rows used a bare `isError: true` flag with
    /// no `errorKind`. The custom decoder in `ToolTypes.swift` migrates those
    /// to `ErrorKind.permanent`. Lock the migration in so future refactors of
    /// the codable shape can't silently drop legacy history on the floor.
    func test_toolResult_legacyIsErrorDecodesToErrorKindPermanent() throws {
        let legacyJSON = #"{"callId":"call_legacy","content":"failed","isError":true}"#
        let data = try XCTUnwrap(legacyJSON.data(using: .utf8))

        let decoded = try JSONDecoder().decode(ToolResult.self, from: data)

        XCTAssertEqual(decoded.callId, "call_legacy")
        XCTAssertEqual(decoded.content, "failed")
        XCTAssertEqual(decoded.errorKind, .permanent)
        XCTAssertTrue(decoded.isError)

        // The success-shaped legacy row (`isError: false`) must decode to nil
        // errorKind — otherwise we'd misclassify successful tool runs as
        // failures on the wire.
        let successLegacyJSON = #"{"callId":"call_ok","content":"ok","isError":false}"#
        let successData = try XCTUnwrap(successLegacyJSON.data(using: .utf8))
        let successDecoded = try JSONDecoder().decode(ToolResult.self, from: successData)
        XCTAssertNil(successDecoded.errorKind)
        XCTAssertFalse(successDecoded.isError)
    }

    /// `ToolResult.encode(to:)` is the migration's other half: it must NOT
    /// emit `isError` because that field is derived from `errorKind` and
    /// shipping both would put two sources of truth on the wire. Re-encoding
    /// must preserve `errorKind` exactly when decoded back.
    func test_toolResult_encodingDoesNotEmitIsError() throws {
        let original = ToolResult(
            callId: "call_xyz",
            content: "request timed out",
            errorKind: .timeout
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(original)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(
            json.contains("\"isError\""),
            "Encoded ToolResult must not emit the legacy isError key (got: \(json))"
        )

        let decoded = try JSONDecoder().decode(ToolResult.self, from: data)
        XCTAssertEqual(decoded.callId, original.callId)
        XCTAssertEqual(decoded.content, original.content)
        XCTAssertEqual(decoded.errorKind, .timeout)
        XCTAssertEqual(decoded, original)
    }
}
