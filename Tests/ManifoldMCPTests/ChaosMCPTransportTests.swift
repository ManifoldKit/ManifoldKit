#if MCP
import XCTest
@testable import ManifoldMCP

/// Per-failure-mode tests for `ChaosMCPTransport`. Each test uses an OOD
/// nonce embedded in scripted message payloads so a passing test can't be
/// reproduced by an implementation that hallucinates the response — the
/// nonce must round-trip verbatim.
///
/// All assertions ship with `// Sabotage-evidence:` blocks documenting:
///   M1 — production-side line whose mutation flips the assertion,
///   M2 — value mutation (nonce flip) that flips it,
///   M3 — capability-skip path (none here are capability-gated; recorded
///         for completeness so the orchestrator's review pass succeeds).
final class ChaosMCPTransportTests: XCTestCase {

    /// Helper: drain `incomingMessages` to completion, returning the bytes
    /// observed and the final error (nil on clean finish).
    private func collect(_ transport: ChaosMCPTransport) async -> (messages: [Data], error: Error?) {
        do {
            try await transport.start()
        } catch {
            return ([], error)
        }
        var collected: [Data] = []
        do {
            for try await message in transport.incomingMessages {
                collected.append(message)
            }
            return (collected, nil)
        } catch {
            return (collected, error)
        }
    }

    private func nonceMessage(_ tag: String) -> Data {
        Data("{\"jsonrpc\":\"2.0\",\"id\":\"\(tag)\",\"result\":{\"content\":\"§MCPC§\(tag)§\"}}".utf8)
    }

    // MARK: - .none

    /// Sabotage-evidence:
    ///   M1: in `applyAndDeliver` `case .none`, comment out `continuation.yield(message)`;
    ///       this test fails because `messages` is empty.
    ///   M2: change tag from "alpha" to "beta"; the value-based assertion below flips.
    ///   M3: not capability-gated.
    func test_none_deliversAllScriptedMessagesInOrder() async throws {
        let scripted = [nonceMessage("alpha"), nonceMessage("bravo"), nonceMessage("charlie")]
        let transport = ChaosMCPTransport(scriptedMessages: scripted, mode: .none)

        let (messages, error) = await collect(transport)
        XCTAssertNil(error, ".none must finish cleanly")
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages, scripted, "messages must round-trip verbatim — bytes-for-bytes")
        XCTAssertEqual(transport.messagesEmittedCount.load(ordering: .relaxed), 3)
    }

    // MARK: - .closeAfter

    /// Sabotage-evidence:
    ///   M1: in `applyAndDeliver` `case .closeAfter`, change the guard to
    ///       `if true` (yield everything); this test fails because messages.count > 2.
    ///   M2: change `count: 2` to `count: 1`; the count assertion flips.
    ///   M3: not capability-gated.
    func test_closeAfter_yieldsPrefixThenFinishesCleanly() async throws {
        let scripted = (0..<5).map { nonceMessage("close-\($0)") }
        let transport = ChaosMCPTransport(scriptedMessages: scripted, mode: .closeAfter(count: 2))

        let (messages, error) = await collect(transport)
        XCTAssertNil(error, "closeAfter must finish cleanly, not throw")
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages, [scripted[0], scripted[1]])
    }

    // MARK: - .malformedAt

    /// Sabotage-evidence:
    ///   M1: in `applyAndDeliver` `case .malformedAt`, drop the swap and yield
    ///       `message` instead of `replacement`; this test fails because the
    ///       message at index 1 is the original payload, not the corruption.
    ///   M2: change the OOD garbage `not-jsonrpc-§MAL§…` to `{}`; the
    ///       contains-check on "§MAL§" flips.
    ///   M3: not capability-gated.
    func test_malformedAt_replacesIndexedMessageWithGarbage() async throws {
        let nonce = "§MAL§\(UUID().uuidString.prefix(8))"
        let scripted = [nonceMessage("ok-0"), nonceMessage("ok-1"), nonceMessage("ok-2")]
        let garbage = Data("not-jsonrpc-\(nonce)".utf8)
        let transport = ChaosMCPTransport(
            scriptedMessages: scripted,
            mode: .malformedAt(index: 1, replacement: garbage)
        )

        let (messages, error) = await collect(transport)
        XCTAssertNil(error)
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0], scripted[0])
        XCTAssertEqual(messages[1], garbage,
                       "Index 1 must be replaced with the garbage payload — verbatim, with the nonce")
        XCTAssertEqual(messages[2], scripted[2])

        let body1 = String(decoding: messages[1], as: UTF8.self)
        XCTAssertTrue(body1.contains(nonce), "OOD nonce must round-trip in the corrupted replacement")
    }

    // MARK: - .transportFailureAt

    /// Sabotage-evidence:
    ///   M1: in `applyAndDeliver` `case .transportFailureAt`, replace
    ///       `continuation.finish(throwing:)` with `continuation.finish()`;
    ///       this test fails because `error` is nil.
    ///   M2: change `failIndex: 2` to `failIndex: 0`; the prefix length assertion flips.
    ///   M3: not capability-gated.
    func test_transportFailureAt_yieldsPrefixThenThrows() async throws {
        let nonce = "§TF§\(UUID().uuidString.prefix(8))"
        let scripted = [nonceMessage("a"), nonceMessage("b"), nonceMessage("c"), nonceMessage("d")]
        let transport = ChaosMCPTransport(
            scriptedMessages: scripted,
            mode: .transportFailureAt(index: 2, message: "chaos-\(nonce)")
        )

        let (messages, error) = await collect(transport)
        XCTAssertEqual(messages, [scripted[0], scripted[1]],
                       "transportFailureAt must deliver the prefix verbatim before throwing")

        guard case .transportFailure(let reason) = error as? MCPError else {
            XCTFail("Expected MCPError.transportFailure, got \(String(describing: error))")
            return
        }
        XCTAssertTrue(reason.contains(nonce), "transportFailure reason must round-trip the OOD nonce")
    }

    // MARK: - .startWithOAuth401

    /// Sabotage-evidence:
    ///   M1: in `start()` `case .startWithOAuth401`, change `throw MCPError…`
    ///       to `return`; this test fails because `error` is nil.
    ///   M2: change the reason string to "OK"; the contains-check on "§401§" flips.
    ///   M3: not capability-gated.
    func test_startWithOAuth401_failsBeforeAnyMessageFlows() async throws {
        let nonce = "§401§\(UUID().uuidString.prefix(8))"
        let transport = ChaosMCPTransport(
            scriptedMessages: [nonceMessage("never")],
            mode: .startWithOAuth401(reason: "auth-\(nonce)")
        )

        do {
            try await transport.start()
            XCTFail("startWithOAuth401 must throw")
        } catch let error as MCPError {
            guard case .authorizationFailed(let reason) = error else {
                XCTFail("Expected authorizationFailed, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains(nonce))
        }
        XCTAssertEqual(transport.messagesEmittedCount.load(ordering: .relaxed), 0,
                       "no messages must flow when start() throws")
    }

    // MARK: - .oneShotSendAuth401 (the OAuth refresh race)

    /// First send throws auth-failed; second send succeeds. Models the
    /// "401 → refresh → retry" path that consumers must re-enter exactly
    /// once. Counters confirm the path was exercised.
    ///
    /// Sabotage-evidence:
    ///   M1: in `send(_:)` `case .oneShotSendAuth401`, remove the `if isFirst`
    ///       gate (always throw); this test fails on the second send call.
    ///   M2: change the reason to "OK"; the contains-check flips.
    ///   M3: not capability-gated.
    func test_oneShotSendAuth401_failsOnceThenAllowsRetry() async throws {
        let nonce = "§ONE§\(UUID().uuidString.prefix(8))"
        let transport = ChaosMCPTransport(
            scriptedMessages: [],
            mode: .oneShotSendAuth401(reason: "first-call-\(nonce)")
        )
        try await transport.start()

        // First send must throw with the nonce in the reason.
        do {
            try await transport.send(Data("{\"id\":1}".utf8))
            XCTFail("first send must throw under .oneShotSendAuth401")
        } catch let error as MCPError {
            guard case .authorizationFailed(let reason) = error else {
                XCTFail("Expected authorizationFailed, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains(nonce))
        }

        // Second send must succeed.
        try await transport.send(Data("{\"id\":2}".utf8))

        XCTAssertEqual(transport.sendCallCount.load(ordering: .relaxed), 2)
        XCTAssertEqual(transport.sendErrorsCount.load(ordering: .relaxed), 1,
                       "exactly one send error — proves the 'one-shot' part")
        XCTAssertEqual(transport.capturedSends.count, 2,
                       "both payloads captured even though one threw")
    }

    // MARK: - close idempotence

    func test_close_isIdempotent() async throws {
        let transport = ChaosMCPTransport(scriptedMessages: [])
        try await transport.start()
        await transport.close()
        await transport.close()  // must not crash or assert
    }
}

#endif
