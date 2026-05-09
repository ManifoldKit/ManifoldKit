import XCTest
@testable import ManifoldInference

/// Tests for SSEStreamParser byte-stream parsing.
final class SSEStreamParserTests: XCTestCase {

    // MARK: - Helpers

    private func makeByteStream(_ string: String) -> AsyncThrowingStream<UInt8, Error> {
        let bytes = Array(string.utf8)
        return AsyncThrowingStream { continuation in
            for byte in bytes {
                continuation.yield(byte)
            }
            continuation.finish()
        }
    }

    private func collect(_ string: String) async throws -> [String] {
        let stream = SSEStreamParser.parse(bytes: makeByteStream(string))
        var results: [String] = []
        for try await value in stream {
            results.append(value)
        }
        return results
    }

    private func collectNamed(_ string: String) async throws -> [SSEStreamParser.NamedEvent] {
        let stream = SSEStreamParser.parseNamed(bytes: makeByteStream(string))
        var results: [SSEStreamParser.NamedEvent] = []
        for try await value in stream {
            results.append(value)
        }
        return results
    }

    // MARK: - Tests

    func test_parse_singleDataLine() async throws {
        let results = try await collect("data: hello\n\n")
        XCTAssertEqual(results, ["hello"])
    }

    func test_parse_multipleDataLines() async throws {
        let input = "data: first\n\ndata: second\n\ndata: third\n\n"
        let results = try await collect(input)
        XCTAssertEqual(results, ["first", "second", "third"])
    }

    func test_parse_doneStopsStream() async throws {
        let input = "data: hello\ndata: [DONE]\ndata: after\n"
        let results = try await collect(input)
        XCTAssertEqual(results, ["hello"],
                       "Should stop at [DONE] and not yield 'after'")
    }

    func test_parse_ignoresEventLines() async throws {
        let input = "event: message\ndata: payload\n\n"
        let results = try await collect(input)
        XCTAssertEqual(results, ["payload"])
    }

    func test_parse_ignoresBlankLines() async throws {
        let input = "\n\ndata: hello\n\n\n\n"
        let results = try await collect(input)
        XCTAssertEqual(results, ["hello"])
    }

    func test_parse_stripsWhitespace() async throws {
        let input = "data:  hello  \n\n"
        let results = try await collect(input)
        XCTAssertEqual(results, ["hello"])
    }

    func test_parse_emptyDataIgnored() async throws {
        let input = "data: \n\n"
        let results = try await collect(input)
        XCTAssertTrue(results.isEmpty, "Empty data payload should be ignored")
    }

    func test_parse_jsonPayload() async throws {
        let json = #"{"choices":[{"delta":{"content":"hi"}}]}"#
        let input = "data: \(json)\n\n"
        let results = try await collect(input)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first, json)
    }

    func test_parse_emptyInput() async throws {
        let results = try await collect("")
        XCTAssertTrue(results.isEmpty, "Empty input should yield nothing")
    }

    func test_parseNamed_namedEvent_yieldsNameAndPayload() async throws {
        let input = "event: response.output_text.delta\ndata: {\"delta\":\"hi\"}\n\n"
        let results = try await collectNamed(input)
        XCTAssertEqual(results, [
            .init(name: "response.output_text.delta", data: #"{"delta":"hi"}"#, id: nil)
        ])
    }

    func test_parseNamed_dataWithoutEventName_yieldsNilName() async throws {
        let input = "data: payload\n\n"
        let results = try await collectNamed(input)
        XCTAssertEqual(results, [
            .init(name: nil, data: "payload", id: nil)
        ])
    }

    func test_parseNamed_multipleDataLines_coalescesWithNewline() async throws {
        let input = """
        event: joined
        data: one
        data: two

        """
        let results = try await collectNamed(input)
        XCTAssertEqual(results, [
            .init(name: "joined", data: "one\ntwo", id: nil)
        ])
    }

    // MARK: - Limits

    /// A normal OpenAI-style SSE trace completes under the default caps with
    /// every token yielded in order. Guards against over-tightening defaults.
    func test_limits_defaultsDoNotThrottleRealProviderTraffic() async throws {
        var sse = ""
        for i in 0..<1_000 {
            sse += #"data: {"choices":[{"delta":{"content":"tok\#(i)"}}]}\#n\#n"#
        }
        let stream = SSEStreamParser.parse(
            bytes: makeByteStream(sse),
            limits: .default
        )
        var count = 0
        for try await _ in stream { count += 1 }
        XCTAssertEqual(count, 1_000)
    }

    /// A single ~2 MB `data:` line must be rejected with
    /// `SSEStreamError.eventTooLarge` before it can be fully buffered.
    func test_limits_eventTooLarge_rejectsOversizedLine() async throws {
        // Build a 2 MB payload; the parser enforces the cap while buffering.
        let big = String(repeating: "A", count: 2_000_000)
        let sse = "data: \(big)\n\n"
        let limits = SSEStreamLimits(
            maxEventBytes: 1_000_000,
            maxTotalBytes: 50_000_000,
            maxEventsPerSecond: 5_000
        )

        let stream = SSEStreamParser.parse(
            bytes: makeByteStream(sse),
            limits: limits
        )

        do {
            for try await _ in stream {}
            XCTFail("Expected SSEStreamError.eventTooLarge")
        } catch let error as SSEStreamError {
            guard case .eventTooLarge(let size) = error else {
                XCTFail("Expected .eventTooLarge, got \(error)")
                return
            }
            XCTAssertGreaterThan(size, 1_000_000, "Reported size should exceed the cap")
        }
    }

    /// Many legitimate-looking small events that sum above the total-bytes
    /// cap must be rejected with `SSEStreamError.streamTooLarge`.
    func test_limits_streamTooLarge_rejectsUnboundedStream() async throws {
        // Craft a stream whose cumulative bytes exceed the 50 KB cap we set
        // while each individual event stays small.
        var sse = ""
        for i in 0..<10_000 {
            sse += "data: \(i)\n\n"  // ~10+ bytes each
        }

        let limits = SSEStreamLimits(
            maxEventBytes: 1_000_000,
            maxTotalBytes: 50_000,
            maxEventsPerSecond: 100_000
        )

        let stream = SSEStreamParser.parse(
            bytes: makeByteStream(sse),
            limits: limits
        )

        do {
            for try await _ in stream {}
            XCTFail("Expected SSEStreamError.streamTooLarge")
        } catch let error as SSEStreamError {
            guard case .streamTooLarge(let total) = error else {
                XCTFail("Expected .streamTooLarge, got \(error)")
                return
            }
            XCTAssertGreaterThan(total, 50_000)
        }
    }

    /// A burst of events within a single one-second window that exceeds
    /// `maxEventsPerSecond` must be rejected with `.eventRateExceeded`.
    func test_limits_eventRateExceeded_rejectsFlood() async throws {
        // 6,000 small events over the 5,000 / s cap.
        var sse = ""
        for _ in 0..<6_000 {
            sse += "data: x\n\n"
        }

        let limits = SSEStreamLimits(
            maxEventBytes: 1_000_000,
            maxTotalBytes: 50_000_000,
            maxEventsPerSecond: 5_000
        )

        let stream = SSEStreamParser.parse(
            bytes: makeByteStream(sse),
            limits: limits
        )

        do {
            for try await _ in stream {}
            XCTFail("Expected SSEStreamError.eventRateExceeded")
        } catch let error as SSEStreamError {
            guard case .eventRateExceeded(let count) = error else {
                XCTFail("Expected .eventRateExceeded, got \(error)")
                return
            }
            XCTAssertGreaterThan(count, 5_000)
        }
    }

    /// Sabotage check: raising the rate cap 100x must let the same 6,000-event
    /// burst complete without tripping `.eventRateExceeded`.
    func test_limits_eventRateExceeded_sabotage_raisedCapPasses() async throws {
        var sse = ""
        for _ in 0..<6_000 {
            sse += "data: x\n\n"
        }

        let limits = SSEStreamLimits(
            maxEventBytes: 1_000_000,
            maxTotalBytes: 50_000_000,
            maxEventsPerSecond: 500_000  // 100x the default
        )

        let stream = SSEStreamParser.parse(
            bytes: makeByteStream(sse),
            limits: limits
        )

        var count = 0
        for try await _ in stream { count += 1 }
        XCTAssertEqual(count, 6_000, "Flood should pass with rate cap raised 100x")
    }

    // MARK: - Event ID Tracking

    func testParsesEventID() async throws {
        let sseData = "id: evt-001\ndata: hello\n\ndata: world\n\n"
        let bytes = AsyncStream<UInt8> { continuation in
            for byte in sseData.utf8 { continuation.yield(byte) }
            continuation.finish()
        }
        let tracker = SSEEventIDTracker()
        var payloads: [String] = []
        for try await payload in SSEStreamParser.parse(bytes: bytes, eventIDTracker: tracker) {
            payloads.append(payload)
        }
        XCTAssertEqual(payloads, ["hello", "world"])
        XCTAssertEqual(tracker.lastEventID, "evt-001")
    }

    func testEmptyIDResetsToNil() async throws {
        let sseData = "id: abc\ndata: first\n\nid:\ndata: second\n\n"
        let bytes = AsyncStream<UInt8> { continuation in
            for byte in sseData.utf8 { continuation.yield(byte) }
            continuation.finish()
        }
        let tracker = SSEEventIDTracker()
        var payloads: [String] = []
        for try await payload in SSEStreamParser.parse(bytes: bytes, eventIDTracker: tracker) {
            payloads.append(payload)
        }
        XCTAssertEqual(payloads, ["first", "second"])
        XCTAssertNil(tracker.lastEventID, "Empty id: should reset lastEventID to nil")
    }

    // MARK: - ManifoldConfiguration wiring

    func test_config_sseStreamLimits_defaultIsShared() {
        // Restoring shared state around the assertion prevents flakes if
        // another test mutated it.
        let original = ManifoldConfiguration.shared.sseStreamLimits
        defer { ManifoldConfiguration.shared.sseStreamLimits = original }

        ManifoldConfiguration.shared.sseStreamLimits = .default
        XCTAssertEqual(ManifoldConfiguration.shared.sseStreamLimits, .default)
    }

    func test_config_sseStreamLimits_overrideIsHonoured() async throws {
        let original = ManifoldConfiguration.shared.sseStreamLimits
        defer { ManifoldConfiguration.shared.sseStreamLimits = original }

        ManifoldConfiguration.shared.sseStreamLimits = SSEStreamLimits(
            maxEventBytes: 10,
            maxTotalBytes: 50_000_000,
            maxEventsPerSecond: 5_000
        )

        let sse = "data: this-is-more-than-ten-bytes\n\n"
        let stream = SSEStreamParser.parse(bytes: makeByteStream(sse))

        do {
            for try await _ in stream {}
            XCTFail("Expected SSEStreamError.eventTooLarge from global override")
        } catch let error as SSEStreamError {
            guard case .eventTooLarge = error else {
                XCTFail("Expected .eventTooLarge, got \(error)")
                return
            }
        }
    }
}
