import XCTest
import BaseChatPersistenceSwiftData
import BaseChatInference

@MainActor
final class SettingsServiceTests: XCTestCase {

    private var suiteName: String!
    private var testDefaults: UserDefaults!
    private var service: SettingsService!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsServiceTests-\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
        service = SettingsService(defaults: testDefaults)
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Global Defaults

    func test_globalDefaults_nilWhenUnset() {
        XCTAssertNil(service.globalTemperature)
        XCTAssertNil(service.globalTopP)
        XCTAssertNil(service.globalRepeatPenalty)
    }

    func test_globalDefaults_persistAcrossInstances() {
        service.globalTemperature = 1.5
        service.globalTopP = 0.5
        service.globalRepeatPenalty = 1.8

        // Create a new instance pointing to the same defaults
        let service2 = SettingsService(defaults: testDefaults)

        XCTAssertEqual(service2.globalTemperature!, 1.5, accuracy: 0.01)
        XCTAssertEqual(service2.globalTopP!, 0.5, accuracy: 0.01)
        XCTAssertEqual(service2.globalRepeatPenalty!, 1.8, accuracy: 0.01)
    }

    // MARK: - Effective Values (Session Override)

    func test_effectiveTemperature_sessionOverrideWins() {
        service.globalTemperature = 0.7

        let session = ChatSession()
        session.temperature = 1.5

        XCTAssertEqual(service.effectiveTemperature(session: session), 1.5, accuracy: 0.01)
    }

    func test_effectiveTemperature_fallsToGlobalWhenNil() {
        service.globalTemperature = 0.8

        let session = ChatSession()
        // temperature is nil by default

        XCTAssertEqual(service.effectiveTemperature(session: session), 0.8, accuracy: 0.01)
    }

    func test_effectiveTopP_sessionOverrideWins() {
        service.globalTopP = 0.9

        let session = ChatSession()
        session.topP = 0.5

        XCTAssertEqual(service.effectiveTopP(session: session), 0.5, accuracy: 0.01)
    }

    func test_effectiveRepeatPenalty_fallsToGlobalWhenNil() {
        service.globalRepeatPenalty = 1.2

        let session = ChatSession()

        XCTAssertEqual(service.effectiveRepeatPenalty(session: session), 1.2, accuracy: 0.01)
    }

    func test_effectiveValues_nilSession_usesGlobal() {
        service.globalTemperature = 0.5

        XCTAssertEqual(service.effectiveTemperature(session: ChatSession?.none), 0.5, accuracy: 0.01)
    }

    func test_chatSessionOverloads_matchRecordOverloads() {
        service.globalTemperature = 0.6
        service.globalTopP = 0.85
        service.globalRepeatPenalty = 1.05

        let session = ChatSession()
        session.temperature = 0.8
        session.topP = nil
        session.repeatPenalty = 1.2

        XCTAssertEqual(
            service.effectiveTemperature(session: session),
            service.effectiveTemperature(session: session.record),
            accuracy: 0.01
        )
        XCTAssertEqual(
            service.effectiveTopP(session: session),
            service.effectiveTopP(session: session.record),
            accuracy: 0.01
        )
        XCTAssertEqual(
            service.effectiveRepeatPenalty(session: session),
            service.effectiveRepeatPenalty(session: session.record),
            accuracy: 0.01
        )
    }

    // MARK: - Appearance

    func test_appearanceMode_defaultsToSystem() {
        XCTAssertEqual(service.appearanceMode, .system)
    }

    func test_appearanceMode_persistsChoice() {
        service.appearanceMode = .dark

        let service2 = SettingsService(defaults: testDefaults)
        XCTAssertEqual(service2.appearanceMode, .dark)
    }

    func test_appearanceMode_allCasesRoundTrip() {
        for mode in AppearanceMode.allCases {
            service.appearanceMode = mode
            let service2 = SettingsService(defaults: testDefaults)
            XCTAssertEqual(service2.appearanceMode, mode,
                          "Round-trip failed for \(mode.rawValue)")
        }
    }

    // MARK: - Prompt Template

    func test_globalPromptTemplate_defaultsToNil() {
        XCTAssertNil(service.globalPromptTemplate)
    }

    func test_globalPromptTemplate_persistsValue() {
        service.globalPromptTemplate = .llama3

        let service2 = SettingsService(defaults: testDefaults)
        XCTAssertEqual(service2.globalPromptTemplate, .llama3)
    }

    func test_globalPromptTemplate_clearsToNil() {
        service.globalPromptTemplate = .chatML
        service.globalPromptTemplate = nil

        let service2 = SettingsService(defaults: testDefaults)
        XCTAssertNil(service2.globalPromptTemplate)
    }

    // MARK: - Nil vs Zero Distinction

    func test_globalTemperature_zeroIsDistinctFromNil() {
        service.globalTemperature = 0.0

        XCTAssertEqual(service.globalTemperature, 0.0,
                       "Setting to 0.0 should persist as 0.0, not be treated as unset")
    }

    func test_globalTemperature_settingNilRemovesKey() {
        service.globalTemperature = 0.5
        XCTAssertNotNil(service.globalTemperature)

        service.globalTemperature = nil
        XCTAssertNil(service.globalTemperature)
    }

    func test_effectiveTemperature_nilGlobalFallsToHardcodedDefault() {
        // Neither session nor global is set
        XCTAssertEqual(service.effectiveTemperature(session: ChatSession?.none), 0.7, accuracy: 0.01)
    }

    func test_effectiveTopP_nilGlobalFallsToHardcodedDefault() {
        XCTAssertEqual(service.effectiveTopP(session: ChatSession?.none), 0.9, accuracy: 0.01)
    }

    func test_effectiveRepeatPenalty_nilGlobalFallsToHardcodedDefault() {
        XCTAssertEqual(service.effectiveRepeatPenalty(session: ChatSession?.none), 1.1, accuracy: 0.01)
    }

    func test_effectiveTemperature_zeroGlobalDoesNotFallToDefault() {
        service.globalTemperature = 0.0

        XCTAssertEqual(service.effectiveTemperature(session: ChatSession?.none), 0.0, accuracy: 0.01,
                       "Global 0.0 should be used, not the hardcoded 0.7 default")
    }
}
