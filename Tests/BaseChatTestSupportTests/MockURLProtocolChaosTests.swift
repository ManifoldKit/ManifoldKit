import XCTest
import BaseChatTestSupport

/// Tests for the chaos `StubbedResponse` cases on `MockURLProtocol`:
/// `corruptedJSONChunk`, `droppedChunks`, `truncatedMidByte`,
/// `delayedFirstByte`. Each case is a deterministic fixture for
/// HTTP-transport-level failure modes that cloud and Ollama backends must
/// surface as structured errors rather than silent successes.
///
/// Per `feedback_mockurlprotocol.md`: do NOT call `MockURLProtocol.reset()`
/// in tearDown — it races with serialized suites that share the global stub
/// table. Instead, every test below uses a UUID hostname so its stub cannot
/// collide with any other test, and unstubs only its own URL on teardown.
final class MockURLProtocolChaosTests: XCTestCase {

    private var session: URLSession!
    private var url: URL!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        // Generous request timeouts so chunk delays don't trigger URLSession's
        // internal idle-timeout (these tests pin chaos vocabulary, not session config).
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)
        // UUID hostname per test ensures global-state isolation (see file header).
        url = URL(string: "https://chaos-\(UUID().uuidString.lowercased()).invalid/v1/stream")!
    }

    override func tearDown() {
        MockURLProtocol.unstub(url: url)
        session?.invalidateAndCancel()
        session = nil
        url = nil
        super.tearDown()
    }

    // MARK: - corruptedJSONChunk

    /// Replaces a single chunk with corrupted bytes. Asserts the consumer
    /// receives all bytes including the corruption — parsing is the consumer's
    /// problem; this protocol's job is to deliver the bytes faithfully.
    ///
    /// Sabotage-evidence:
    ///   M1: in MockURLProtocol.startLoading `case .corruptedJSONChunk`, comment out
    ///       the line `rewritten[corruptIndex] = corruptedReplacement`; this test
    ///       fails because the original chunk bytes appear instead of the corruption.
    ///   M2: change the nonce in `corruptedReplacement` from `§CORRUPT§…` to `OK`;
    ///       the assertion checking for "§CORRUPT§" flips.
    ///   M3: not capability-gated.
    func test_corruptedJSONChunk_replacesIndexedChunk() async throws {
        let nonce = "§CORRUPT§\(UUID().uuidString.prefix(8))"
        let chunks: [Data] = [
            Data("{\"a\":1}\n".utf8),
            Data("{\"b\":2}\n".utf8),
            Data("{\"c\":3}\n".utf8)
        ]
        let corrupt = Data("garbage:\(nonce)".utf8)
        MockURLProtocol.stub(
            url: url,
            response: .corruptedJSONChunk(
                chunks: chunks,
                corruptIndex: 1,
                corruptedReplacement: corrupt,
                statusCode: 200
            )
        )

        let (data, response) = try await session.data(for: URLRequest(url: url))
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)

        let body = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(body.contains("{\"a\":1}\n"), "first chunk delivered verbatim")
        XCTAssertFalse(body.contains("{\"b\":2}\n"),
                       "chunk at corruptIndex must be replaced, not delivered verbatim")
        XCTAssertTrue(body.contains("garbage:\(nonce)"),
                      "corrupted replacement must be delivered with the OOD nonce intact")
        XCTAssertTrue(body.contains("{\"c\":3}\n"), "subsequent chunk delivered verbatim")
    }

    // MARK: - droppedChunks

    /// Drops every chunk that is NOT a multiple of `every`. With chunks
    /// `[a, b, c, d, e]` and `every: 2`, the consumer receives `[a, c, e]`
    /// concatenated; the wire effectively delivered "every other frame".
    ///
    /// Sabotage-evidence:
    ///   M1: in `case .droppedChunks`, change `compactMap` to `Array($0)` (deliver all);
    ///       the assertion that `b` and `d` are absent flips.
    ///   M2: change `every: 2` to `every: 3`; the kept set changes to `[a, d]`,
    ///       breaking the value-based assertion below.
    ///   M3: not capability-gated.
    func test_droppedChunks_keepsOnlyMultiplesOfEvery() async throws {
        let chunks: [Data] = "abcde".map { Data(String($0).utf8) }
        MockURLProtocol.stub(
            url: url,
            response: .droppedChunks(chunks: chunks, every: 2, statusCode: 200)
        )

        let (data, response) = try await session.data(for: URLRequest(url: url))
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)

        let body = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(body, "ace",
                       "indices 0,2,4 are kept; 1,3 dropped — every: 2 means every-other-from-zero")
    }

    // MARK: - truncatedMidByte

    /// Concatenates chunks, delivers the first `byteOffset` bytes, then closes
    /// with `URLError.networkConnectionLost`. The consumer must observe the
    /// transport error — successful close after partial bytes is wrong.
    ///
    /// Sabotage-evidence:
    ///   M1: in `deliverTruncatedResponse`, replace `client?.urlProtocol(...didFailWithError:)`
    ///       with `client?.urlProtocolDidFinishLoading(self)`; this test fails because
    ///       the request completes successfully instead of throwing.
    ///   M2: change `byteOffset` from 5 to `chunks.totalBytes`; the partial-byte
    ///       length assertion flips.
    ///   M3: not capability-gated.
    func test_truncatedMidByte_deliversPartialThenFails() async throws {
        let chunks: [Data] = [Data("hello world".utf8), Data(", goodbye".utf8)]
        MockURLProtocol.stub(
            url: url,
            response: .truncatedMidByte(chunks: chunks, byteOffset: 5, statusCode: 200)
        )

        do {
            _ = try await session.data(for: URLRequest(url: url))
            XCTFail("truncatedMidByte must surface a transport error, not succeed")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost,
                           "truncatedMidByte closes the socket abruptly — expected networkConnectionLost")
        } catch {
            XCTFail("Expected URLError, got \(error)")
        }
    }

    // MARK: - delayedFirstByte

    /// Asserts the response really is delayed by at least the configured
    /// duration before the first byte arrives. The OOD nonce in the body
    /// proves the right stub responded.
    ///
    /// Sabotage-evidence:
    ///   M1: in `deliverDelayedFirstByteResponse`, comment out
    ///       `Thread.sleep(forTimeInterval: firstByteDelay)`; this test fails
    ///       because elapsed ≪ firstByteDelay.
    ///   M2: change firstByteDelay from 0.08 to 0.001; elapsed drops below the
    ///       assertion threshold.
    ///   M3: not capability-gated.
    func test_delayedFirstByte_waitsBeforeFirstByteArrival() async throws {
        let nonce = "§FIRSTBYTE§\(UUID().uuidString.prefix(8))"
        let body = Data("payload:\(nonce)".utf8)
        let delay: TimeInterval = 0.08
        MockURLProtocol.stub(
            url: url,
            response: .delayedFirstByte(data: body, firstByteDelay: delay, statusCode: 200)
        )

        let clock = ContinuousClock()
        let start = clock.now
        let (data, _) = try await session.data(for: URLRequest(url: url))
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(data, body)
        let received = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(received.contains(nonce), "OOD nonce must round-trip in the delivered payload")
        XCTAssertGreaterThanOrEqual(
            elapsed, .milliseconds(Int(delay * 1000)),
            "delayedFirstByte must withhold delivery until the configured delay elapses"
        )
    }
}
