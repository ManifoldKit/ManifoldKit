import XCTest
@testable import ManifoldPersistenceSwiftData
import ManifoldInference

final class ChatSessionTests: XCTestCase {

    func test_init_setsDefaults() {
        let session = PersistedChatSession()

        XCTAssertEqual(session.title, "New Chat")
        XCTAssertEqual(session.systemPrompt, "")
    }

    func test_init_customTitle() {
        let session = PersistedChatSession(title: "My Chat")
        XCTAssertEqual(session.title, "My Chat")
    }

    func test_optionalOverrides_nilByDefault() {
        let session = PersistedChatSession()

        XCTAssertNil(session.temperature)
        XCTAssertNil(session.topP)
        XCTAssertNil(session.repeatPenalty)
        XCTAssertNil(session.promptTemplateRawValue)
        XCTAssertNil(session.contextSizeOverride)
        XCTAssertNil(session.selectedModelID)
        XCTAssertNil(session.selectedEndpointID)
    }

    func test_promptTemplate_roundTrip() {
        let session = PersistedChatSession()

        session.promptTemplate = .llama3
        XCTAssertEqual(session.promptTemplate, .llama3)
        XCTAssertEqual(session.promptTemplateRawValue, "Llama 3")

        session.promptTemplate = nil
        XCTAssertNil(session.promptTemplate)
        XCTAssertNil(session.promptTemplateRawValue)
    }

    func test_promptTemplate_allCases() {
        let session = PersistedChatSession()

        for template in PromptTemplate.allCases {
            session.promptTemplate = template
            XCTAssertEqual(session.promptTemplate, template,
                          "Round-trip failed for \(template.rawValue)")
        }
    }

    func test_generationOverrides_setAndRead() {
        let session = PersistedChatSession()

        session.temperature = 1.5
        session.topP = 0.8
        session.repeatPenalty = 1.3

        XCTAssertEqual(session.temperature, 1.5)
        XCTAssertEqual(session.topP, 0.8)
        XCTAssertEqual(session.repeatPenalty, 1.3)
    }

    func test_record_mapsSessionState() {
        let session = PersistedChatSession(title: "Bridge")
        let selectedModelID = UUID()
        let selectedEndpointID = UUID()
        let firstPinnedID = UUID()
        let secondPinnedID = UUID()
        let createdAt = Date(timeIntervalSinceReferenceDate: 100)
        let updatedAt = Date(timeIntervalSinceReferenceDate: 200)

        session.id = UUID()
        session.createdAt = createdAt
        session.updatedAt = updatedAt
        session.systemPrompt = "System prompt"
        session.selectedModelID = selectedModelID
        session.selectedEndpointID = selectedEndpointID
        session.temperature = 0.8
        session.topP = 0.95
        session.repeatPenalty = 1.25
        session.promptTemplate = .llama3
        session.contextSizeOverride = 4096
        session.pinnedMessageIDs = [firstPinnedID, secondPinnedID]

        let record = session.record

        XCTAssertEqual(record.id, session.id)
        XCTAssertEqual(record.title, "Bridge")
        XCTAssertEqual(record.createdAt, createdAt)
        XCTAssertEqual(record.updatedAt, updatedAt)
        XCTAssertEqual(record.systemPrompt, "System prompt")
        XCTAssertEqual(record.selectedModelID, selectedModelID)
        XCTAssertEqual(record.selectedEndpointID, selectedEndpointID)
        XCTAssertEqual(record.temperature, 0.8)
        XCTAssertEqual(record.topP, 0.95)
        XCTAssertEqual(record.repeatPenalty, 1.25)
        XCTAssertEqual(record.promptTemplate, .llama3)
        XCTAssertEqual(record.contextSizeOverride, 4096)
        XCTAssertEqual(record.pinnedMessageIDs, [firstPinnedID, secondPinnedID])
    }
}
