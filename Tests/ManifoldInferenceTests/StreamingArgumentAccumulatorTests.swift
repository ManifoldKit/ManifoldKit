import XCTest
@testable import ManifoldInference
@testable import ManifoldContract  // #1719: streaming/tokenizer seams moved to Contract

/// Unit tests for ``StreamingArgumentAccumulator``.
///
/// Covers:
/// - Single-chunk arguments (no deltas, complete `.toolCall` in one shot)
/// - Multi-chunk argument deltas assemble correctly
/// - Two parallel call slots accumulate independently
/// - Empty arguments produce a valid (empty string normalized to "{}") result
final class StreamingArgumentAccumulatorTests: XCTestCase {

    // MARK: - Single-chunk arguments

    func test_singleChunk_producesCorrectEntry() {
        let acc = StreamingArgumentAccumulator()

        acc.upsert(key: "0", id: "call-abc", name: "get_weather", argumentsDelta: "{\"city\":\"London\"}")

        let entries = acc.finalizedEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].callId, "call-abc")
        XCTAssertEqual(entries[0].name, "get_weather")
        XCTAssertEqual(entries[0].arguments, "{\"city\":\"London\"}")

        // Sabotage check: if the entry's id is ignored and we always return
        // the synthetic fallback, the callId would be "openai-call-0", not
        // "call-abc". Verify the assertion above would catch that regression.
        XCTAssertNotEqual(entries[0].callId, "openai-call-0",
            "Sabotage: sticky id should be 'call-abc', not the synthetic fallback")
    }

    // MARK: - Multi-chunk argument deltas

    func test_multipleDeltas_assembleInOrder() {
        let acc = StreamingArgumentAccumulator()

        // First delta creates the entry; subsequent ones append.
        acc.upsert(key: "0", id: "call-xyz", name: "search", argumentsDelta: "{\"q\":")
        acc.upsert(key: "0", id: nil, name: nil, argumentsDelta: "\"swift\"}")

        let entries = acc.finalizedEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].arguments, "{\"q\":\"swift\"}")

        // Sabotage: if deltas were not appended (e.g., replaced), the
        // second chunk would be missing.
        XCTAssertTrue(entries[0].arguments.contains("\"q\":"),
            "Sabotage: first delta fragment must be present")
        XCTAssertTrue(entries[0].arguments.contains("\"swift\""),
            "Sabotage: second delta fragment must be present")
    }

    // MARK: - Parallel slots accumulate independently

    func test_twoParallelSlots_accumulateIndependently() {
        let acc = StreamingArgumentAccumulator()

        // Interleaved deltas for two different call indices.
        acc.upsert(key: "0", id: "call-1", name: "tool_a", argumentsDelta: "{\"x\":")
        acc.upsert(key: "1", id: "call-2", name: "tool_b", argumentsDelta: "{\"y\":")
        acc.upsert(key: "0", id: nil, name: nil, argumentsDelta: "1}")
        acc.upsert(key: "1", id: nil, name: nil, argumentsDelta: "2}")

        let entries = acc.finalizedEntries()
        XCTAssertEqual(entries.count, 2)

        // Insertion order is preserved.
        XCTAssertEqual(entries[0].callId, "call-1")
        XCTAssertEqual(entries[0].name, "tool_a")
        XCTAssertEqual(entries[0].arguments, "{\"x\":1}")

        XCTAssertEqual(entries[1].callId, "call-2")
        XCTAssertEqual(entries[1].name, "tool_b")
        XCTAssertEqual(entries[1].arguments, "{\"y\":2}")

        // Sabotage: if slots shared state, arguments would be cross-contaminated.
        XCTAssertFalse(entries[0].arguments.contains("y"),
            "Sabotage: slot 0 must not contain fragments from slot 1")
        XCTAssertFalse(entries[1].arguments.contains("x"),
            "Sabotage: slot 1 must not contain fragments from slot 0")
    }

    // MARK: - Empty arguments normalise to "{}"

    func test_emptyArguments_normaliseToEmptyObject() {
        let acc = StreamingArgumentAccumulator()

        // Tool call with no argument delta at all.
        acc.upsert(key: "0", id: "call-no-args", name: "ping", argumentsDelta: nil)

        let entries = acc.finalizedEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].arguments, "{}",
            "Empty arguments must normalise to '{}' so downstream JSON consumers can always parse")

        // Sabotage: if empty arguments were passed through as "", the
        // assertion above would fail.
        XCTAssertNotEqual(entries[0].arguments, "",
            "Sabotage: empty arguments must not be an empty string")
    }

    // MARK: - Sticky id

    func test_stickyId_firstNonEmptyIdWins() {
        let acc = StreamingArgumentAccumulator()

        // First delta has no id; second has the real id.
        acc.upsert(key: "0", id: nil, name: "tool_c", argumentsDelta: "{")
        acc.upsert(key: "0", id: "call-real", name: nil, argumentsDelta: "}")

        let entries = acc.finalizedEntries()
        XCTAssertEqual(entries[0].callId, "call-real")
    }

    // MARK: - markStarted

    func test_markStarted_setsStartedFlag() {
        let acc = StreamingArgumentAccumulator()
        acc.upsert(key: "0", id: "id-1", name: "tool_d", argumentsDelta: nil)

        XCTAssertFalse(acc.entriesByKey["0"]?.started ?? true)
        acc.markStarted(key: "0")
        XCTAssertTrue(acc.entriesByKey["0"]?.started ?? false)
    }

    // MARK: - resolvedId fallback

    func test_resolvedId_syntheticFallbackWhenNoId() {
        let acc = StreamingArgumentAccumulator()
        acc.upsert(key: "7", id: nil, name: "tool_e", argumentsDelta: nil)

        XCTAssertEqual(acc.resolvedId(forKey: "7"), "openai-call-7")
    }

    func test_resolvedId_returnsStoredIdWhenPresent() {
        let acc = StreamingArgumentAccumulator()
        acc.upsert(key: "7", id: "real-id", name: "tool_f", argumentsDelta: nil)

        XCTAssertEqual(acc.resolvedId(forKey: "7"), "real-id")
    }

    // MARK: - Entries with no name are dropped

    func test_finalizedEntries_dropsEntriesWithNoName() {
        let acc = StreamingArgumentAccumulator()
        acc.upsert(key: "0", id: "call-ghost", name: nil, argumentsDelta: "{}")

        // Name never arrives — the entry must be dropped from finalizedEntries.
        let entries = acc.finalizedEntries()
        XCTAssertTrue(entries.isEmpty,
            "Entries with no name must be dropped — the model never finished declaring them")
    }
}
