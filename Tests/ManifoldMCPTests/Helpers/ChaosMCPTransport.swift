#if MCP
import Foundation
import Synchronization
@testable import ManifoldMCP

/// Test-only `MCPTransport` decorator that emits scripted incoming messages
/// with deterministic chaos modes injected at known indices.
///
/// `MCPStreamableHTTPTransport` is the only production conformer of
/// `MCPTransport` today. Real integration tests against it require a live
/// HTTP server. `ChaosMCPTransport` short-circuits that: each test pins a
/// finite ordered list of `incomingMessages` and a `FailureMode` that decides
/// how the message stream is allowed to deviate from the happy path.
///
/// ## Why a separate type, not a layer of `MockURLProtocol`
///
/// The MCP transport surface includes stdio in addition to streamable-HTTP.
/// Decorating `URLSession` only covers half of the protocol shapes the
/// downstream `InternalMCPSession` consumer must handle. `ChaosMCPTransport`
/// works at the message-stream level, which is the actual abstraction that
/// session code reads from.
///
/// ## OOD nonces
///
/// Tests should embed an OOD nonce in `outgoingPayloadCheck` and the message
/// fixtures so a passing test cannot be reproduced by an MCP implementation
/// that hallucinates a happy-path response.
final class ChaosMCPTransport: MCPTransport, @unchecked Sendable {

    enum FailureMode: Sendable, Equatable {
        /// Deliver every message in `incomingMessages`, then finish cleanly.
        case none

        /// Deliver the first `count` messages, then finish cleanly without
        /// surfacing an error. Models a server that closes the SSE channel
        /// gracefully mid-conversation.
        case closeAfter(count: Int)

        /// Deliver every message except the one at `index`, which is replaced
        /// by `replacement`. Exercises the consumer's JSON-RPC parser
        /// robustness — the `replacement` payload is intentionally not valid
        /// JSON-RPC, so the consumer must structured-error rather than crash.
        case malformedAt(index: Int, replacement: Data)

        /// Deliver the first `index` messages, then finish the stream with
        /// `MCPError.transportFailure`. Models a connection that breaks
        /// mid-stream.
        case transportFailureAt(index: Int, message: String)

        /// Reject `start()` with `MCPError.authorizationFailed`. Models a
        /// 401 received before any messages flow.
        case startWithOAuth401(reason: String)

        /// On the first send and only the first send, throw
        /// `MCPError.authorizationFailed`. Subsequent sends succeed and the
        /// scripted messages flow normally. Models the "401 → refresh →
        /// retry" race that `MCPOAuthRefreshE2ETests` will exercise (T3A).
        case oneShotSendAuth401(reason: String)
    }

    // MARK: - MCPTransport conformance

    let incomingMessages: AsyncThrowingStream<Data, Error>

    // MARK: - Public counters (Atomic so test assertions are race-free)

    /// Lifetime count of `send(_:)` calls received.
    let sendCallCount = Atomic<UInt64>(0)

    /// Lifetime count of messages successfully yielded onto `incomingMessages`.
    let messagesEmittedCount = Atomic<UInt64>(0)

    /// Lifetime count of `send(_:)` calls that threw (rather than returning
    /// normally). Useful for the "one-shot 401" mode.
    let sendErrorsCount = Atomic<UInt64>(0)

    // MARK: - Internal state

    private let mode: FailureMode
    private let scriptedMessages: [Data]
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let stateLock = NSLock()
    private var hasStarted = false
    private var hasClosed = false
    private var firstSendObserved = false
    private var captureLock = NSLock()
    private var _capturedSends: [Data] = []

    /// Snapshot of every `send(_:)` payload, in order, captured under a lock
    /// so test assertions are stable even with concurrent senders.
    var capturedSends: [Data] {
        captureLock.lock()
        defer { captureLock.unlock() }
        return _capturedSends
    }

    init(scriptedMessages: [Data], mode: FailureMode = .none) {
        self.scriptedMessages = scriptedMessages
        self.mode = mode
        var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.incomingMessages = AsyncThrowingStream { c in streamContinuation = c }
        self.continuation = streamContinuation
    }

    func start() async throws {
        if claimStartFlag() == false {
            return  // already started
        }

        switch mode {
        case .startWithOAuth401(let reason):
            throw MCPError.authorizationFailed(reason)
        default:
            break
        }

        // Deliver scripted messages on a Task so `start()` returns promptly
        // while messages flow asynchronously — matches the real transport's
        // semantics where `start` opens the stream and returns.
        //
        // Strong-capture self so the counter increments are observable even
        // if the test only retains the AsyncThrowingStream and not the
        // transport itself. The deinit doesn't try to cancel the task —
        // tests close() explicitly.
        let mode = self.mode
        let scripted = self.scriptedMessages
        let cont = self.continuation
        let txn = self  // strong capture
        Task {
            defer {
                // Always close the stream cleanly on Task exit. The
                // transport-failure path calls `finish(throwing:)` first;
                // a subsequent `finish()` is a no-op per AsyncThrowingStream.
                cont.finish()
                _ = txn  // keep transport alive for the counter increments
            }
            for (index, message) in scripted.enumerated() {
                if Task.isCancelled { return }
                let stopAfterThis = txn.applyAndDeliver(
                    message: message,
                    index: index,
                    mode: mode,
                    continuation: cont
                )
                if stopAfterThis { return }
            }
        }
    }

    func send(_ payload: Data) async throws {
        sendCallCount.wrappingAdd(1, ordering: .relaxed)
        captureSend(payload)

        switch mode {
        case .oneShotSendAuth401(let reason):
            if claimFirstSend() {
                sendErrorsCount.wrappingAdd(1, ordering: .relaxed)
                throw MCPError.authorizationFailed(reason)
            }
        default:
            break
        }
        // Otherwise: send is a no-op. Real implementations would dispatch to
        // the wire; chaos tests are about the *response* side, so swallow it.
    }

    func close() async {
        if claimCloseFlag() {
            continuation.finish()
        }
    }

    // MARK: - Synchronous lock helpers (avoid NSLock.unlock in async ctx)

    /// Returns true on first call (caller wins the start), false otherwise.
    private func claimStartFlag() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if hasStarted { return false }
        hasStarted = true
        return true
    }

    /// Returns true on first call (caller is the first send), false otherwise.
    private func claimFirstSend() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if firstSendObserved { return false }
        firstSendObserved = true
        return true
    }

    /// Returns true if the caller transitioned from open → closed
    /// (i.e. should run close-side effects), false if already closed.
    private func claimCloseFlag() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if hasClosed { return false }
        hasClosed = true
        return true
    }

    private func captureSend(_ payload: Data) {
        captureLock.lock()
        defer { captureLock.unlock() }
        _capturedSends.append(payload)
    }

    // MARK: - Delivery

    /// Applies the active failure mode to a single scripted message.
    /// Returns `true` when the caller should stop the loop — either because
    /// the configured cap was reached or because the stream has already been
    /// finished with an error.
    private func applyAndDeliver(
        message: Data,
        index: Int,
        mode: FailureMode,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) -> Bool {
        switch mode {
        case .none, .startWithOAuth401, .oneShotSendAuth401:
            continuation.yield(message)
            messagesEmittedCount.wrappingAdd(1, ordering: .relaxed)
            return false

        case .closeAfter(let count):
            if index < count {
                continuation.yield(message)
                messagesEmittedCount.wrappingAdd(1, ordering: .relaxed)
            }
            return index + 1 >= count

        case .malformedAt(let badIndex, let replacement):
            if index == badIndex {
                continuation.yield(replacement)
            } else {
                continuation.yield(message)
            }
            messagesEmittedCount.wrappingAdd(1, ordering: .relaxed)
            return false

        case .transportFailureAt(let failIndex, let reasonMessage):
            if index < failIndex {
                continuation.yield(message)
                messagesEmittedCount.wrappingAdd(1, ordering: .relaxed)
                return false
            } else {
                continuation.finish(throwing: MCPError.transportFailure(reasonMessage))
                return true
            }
        }
    }
}

#endif

