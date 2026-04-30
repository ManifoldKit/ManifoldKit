import XCTest
@testable import BaseChatPersistenceSwiftData

final class SamplerPresetTests: XCTestCase {

    func test_init_setsNameAndDefaults() {
        let preset = SamplerPreset(name: "Default")

        XCTAssertEqual(preset.name, "Default")
        XCTAssertEqual(preset.temperature, 0.7, accuracy: 0.01)
        XCTAssertEqual(preset.topP, 0.9, accuracy: 0.01)
        XCTAssertEqual(preset.repeatPenalty, 1.1, accuracy: 0.01)
        XCTAssertNotNil(preset.id)
        XCTAssertNotNil(preset.createdAt)
    }

    func test_init_customValues() {
        let preset = SamplerPreset(
            name: "Creative",
            temperature: 1.5,
            topP: 0.95,
            repeatPenalty: 1.3
        )

        XCTAssertEqual(preset.name, "Creative")
        XCTAssertEqual(preset.temperature, 1.5, accuracy: 0.01)
        XCTAssertEqual(preset.topP, 0.95, accuracy: 0.01)
        XCTAssertEqual(preset.repeatPenalty, 1.3, accuracy: 0.01)
    }

    func test_uniqueIDs() {
        let preset1 = SamplerPreset(name: "A")
        let preset2 = SamplerPreset(name: "B")

        XCTAssertNotEqual(preset1.id, preset2.id)
    }
}
