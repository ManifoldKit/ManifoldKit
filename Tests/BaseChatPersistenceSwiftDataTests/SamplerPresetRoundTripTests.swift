import XCTest
import SwiftData
@testable import BaseChatPersistenceSwiftData
import BaseChatTestSupport

final class SamplerPresetRoundTripTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try makeInMemoryContainer()
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
    }

    // MARK: - Save and fetch round-trip

    func test_insertAndFetch_allValuesMatch() throws {
        let preset = SamplerPreset(
            name: "Precise",
            temperature: 0.2,
            topP: 0.85,
            repeatPenalty: 1.05,
            presencePenalty: 0.25,
            frequencyPenalty: 0.5,
            repetitionContextSize: 96,
            presenceContextSize: 48,
            frequencyContextSize: 24
        )
        let savedID = preset.id

        context.insert(preset)
        try context.save()

        var descriptor = FetchDescriptor<SamplerPreset>(
            predicate: #Predicate { $0.id == savedID }
        )
        descriptor.fetchLimit = 1
        let results = try context.fetch(descriptor)

        XCTAssertEqual(results.count, 1)
        let fetched = try XCTUnwrap(results.first)
        XCTAssertEqual(fetched.id, savedID)
        XCTAssertEqual(fetched.name, "Precise")
        XCTAssertEqual(fetched.temperature, 0.2, accuracy: 0.001)
        XCTAssertEqual(fetched.topP, 0.85, accuracy: 0.001)
        XCTAssertEqual(fetched.repeatPenalty, 1.05, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(fetched.presencePenalty), 0.25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(fetched.frequencyPenalty), 0.5, accuracy: 0.001)
        XCTAssertEqual(fetched.repetitionContextSize, 96)
        XCTAssertEqual(fetched.presenceContextSize, 48)
        XCTAssertEqual(fetched.frequencyContextSize, 24)
        XCTAssertLessThanOrEqual(fetched.createdAt, Date())
    }

    // MARK: - Update round-trip

    func test_updateAndFetch_persistsNewValue() throws {
        let preset = SamplerPreset(
            name: "Draft",
            temperature: 0.9,
            topP: 0.95,
            repeatPenalty: 1.2
        )
        let savedID = preset.id

        context.insert(preset)
        try context.save()

        // Mutate and re-save
        preset.temperature = 1.4
        preset.presencePenalty = 0.3
        preset.repetitionContextSize = 80
        preset.name = "Creative"
        try context.save()

        var descriptor = FetchDescriptor<SamplerPreset>(
            predicate: #Predicate { $0.id == savedID }
        )
        descriptor.fetchLimit = 1
        let results = try context.fetch(descriptor)

        let fetched = try XCTUnwrap(results.first)
        XCTAssertEqual(fetched.name, "Creative")
        XCTAssertEqual(fetched.temperature, 1.4, accuracy: 0.001)
        // Unchanged fields stay intact
        XCTAssertEqual(fetched.topP, 0.95, accuracy: 0.001)
        XCTAssertEqual(fetched.repeatPenalty, 1.2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(fetched.presencePenalty), 0.3, accuracy: 0.001)
        XCTAssertEqual(fetched.repetitionContextSize, 80)
        XCTAssertNil(fetched.frequencyPenalty)
        XCTAssertNil(fetched.presenceContextSize)
        XCTAssertNil(fetched.frequencyContextSize)
    }

    // MARK: - Multiple presets coexist

    func test_multiplePresets_fetchedIndependently() throws {
        let presetA = SamplerPreset(name: "A", temperature: 0.1, topP: 0.5, repeatPenalty: 1.0)
        let presetB = SamplerPreset(name: "B", temperature: 1.8, topP: 0.99, repeatPenalty: 1.5)
        let presetC = SamplerPreset(name: "C", temperature: 0.7, topP: 0.9, repeatPenalty: 1.1)

        context.insert(presetA)
        context.insert(presetB)
        context.insert(presetC)
        try context.save()

        // Fetch all
        let all = try context.fetch(FetchDescriptor<SamplerPreset>())
        XCTAssertEqual(all.count, 3)

        // Fetch each by ID and verify independence
        let idA = presetA.id
        let idB = presetB.id

        let fetchedA = try context.fetch(FetchDescriptor<SamplerPreset>(
            predicate: #Predicate { $0.id == idA }
        ))
        XCTAssertEqual(fetchedA.count, 1)
        XCTAssertEqual(fetchedA.first?.name, "A")
        XCTAssertEqual(fetchedA.first?.temperature ?? -1, 0.1, accuracy: 0.001)

        let fetchedB = try context.fetch(FetchDescriptor<SamplerPreset>(
            predicate: #Predicate { $0.id == idB }
        ))
        XCTAssertEqual(fetchedB.count, 1)
        XCTAssertEqual(fetchedB.first?.name, "B")
        XCTAssertEqual(fetchedB.first?.temperature ?? -1, 1.8, accuracy: 0.001)
        XCTAssertEqual(fetchedB.first?.repeatPenalty ?? -1, 1.5, accuracy: 0.001)
    }
}
