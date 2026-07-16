#if Server
@testable import ManifoldServer
import ManifoldInference
import ManifoldTestSupport
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import os
import XCTest

/// Coverage for issue #2265: `ManifoldServer` had no request idle/generation
/// timeout, so a stalled backend held a non-streaming request (and its
/// `generationGate` slot) open forever, and a stalled streaming generation
/// held the HTTP connection open with no terminal frame ever written. Also
/// covers the `maxGenerationOutputTokens` output-size cap (the request could
/// previously omit `max_tokens`/`max_completion_tokens` entirely and reach
/// `GenerationConfig` with no cap at all).
final class ServerGenerationTimeoutTests: XCTestCase {
    // MARK: - Non-streaming generation timeout

    /// A backend that never returns (and never observes cancellation) must
    /// still be cut off: the request fails with 504 and the backend's
    /// `stopGeneration()` is actually invoked — not just task abandonment.
    func testNonStreamingRequestTimesOutAndCancelsBackend() async throws {
        let backend = ServerTestBackendFactory.loadedMock()
        let adapter = FakeChatCompletionsAdapter()
        adapter.hangsForever = true

        let app = ServerApp(
            configuration: ServerConfiguration(generationTimeout: .milliseconds(50)),
            backendProvider: FakeServerBackendProvider(backend: backend),
            adapter: adapter
        ).makeApplication()

        let request = ChatCompletionRequest(
            model: "fake-model",
            messages: [ChatCompletionMessage(role: .user, content: "hi")]
        )
        let body = ByteBuffer(bytes: try JSONEncoder().encode(request))

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, body: body) { response in
                XCTAssertEqual(response.status, .gatewayTimeout)
                let text = String(buffer: response.body)
                XCTAssertTrue(text.contains("generationTimedOut") || text.contains("timeout"),
                               "error envelope should mention the timeout: \(text)")
            }
        }

        XCTAssertGreaterThanOrEqual(backend.stopCallCount, 1, "timeout must actually cancel the in-flight generation")
    }

    /// `generationTimeout: nil` disables the cap and restores the pre-#2265
    /// behavior — a slow-but-eventually-completing generation must still
    /// succeed.
    func testNonStreamingGenerationTimeoutDisabledWhenNil() async throws {
        let backend = ServerTestBackendFactory.loadedMock()
        let adapter = FakeChatCompletionsAdapter()

        let app = ServerApp(
            configuration: ServerConfiguration(generationTimeout: nil),
            backendProvider: FakeServerBackendProvider(backend: backend),
            adapter: adapter
        ).makeApplication()

        let request = ChatCompletionRequest(
            model: "fake-model",
            messages: [ChatCompletionMessage(role: .user, content: "hi")]
        )
        let body = ByteBuffer(bytes: try JSONEncoder().encode(request))

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, body: body) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
        XCTAssertEqual(backend.stopCallCount, 0)
    }

    // MARK: - Streaming idle timeout

    /// A stream that emits one chunk and then stalls forever must be cut off
    /// by the idle timeout: the response-body handler ends with a thrown
    /// `ServerError.generationTimedOut` (not a silently hung connection), and
    /// `stopGeneration()` fires.
    ///
    /// `HummingbirdTesting`'s in-process client fully drains a response
    /// before handing it back (see `SSECancellationTests`'s doc comment) —
    /// when the `ResponseBody` closure itself throws (as it now deliberately
    /// does after writing the terminal SSE frame, so the caller's existing
    /// metrics/`generationGate` error path runs), that surfaces as a thrown
    /// error from `client.execute` rather than a completed `Response` value,
    /// so this test asserts on the thrown error rather than response bytes.
    /// `testWriteSSEChunksIdleTimeoutWritesTerminalFrameBeforeThrowing`
    /// below drives `writeSSEChunks` directly to verify the terminal SSE
    /// frame is actually written to the wire before the throw.
    func testStreamingIdleTimeoutFiresAndSendsTerminalSSEFrame() async throws {
        let backend = ServerTestBackendFactory.loadedMock()
        let adapter = FakeChatCompletionsAdapter()
        adapter.hangsAfterFirstChunk = true

        let app = ServerApp(
            configuration: ServerConfiguration(streamingIdleTimeout: .milliseconds(80)),
            backendProvider: FakeServerBackendProvider(backend: backend),
            adapter: adapter
        ).makeApplication()

        var request = ChatCompletionRequest(
            model: "fake-model",
            messages: [ChatCompletionMessage(role: .user, content: "hi")]
        )
        request.stream = true
        let body = ByteBuffer(bytes: try JSONEncoder().encode(request))

        do {
            try await app.test(.router) { client in
                try await client.execute(uri: "/v1/chat/completions", method: .post, body: body) { _ in }
            }
            XCTFail("expected the idle timeout to end the stream with a thrown error")
        } catch {
            let description = String(describing: error)
            XCTAssertTrue(
                description.contains("idle timeout") || description.contains("timeout"),
                "expected a timeout-shaped error, got: \(description)"
            )
        }

        XCTAssertGreaterThanOrEqual(backend.stopCallCount, 1, "idle timeout must actually cancel the in-flight generation")
    }

    /// Drives `writeSSEChunks` directly (bypassing `HummingbirdTesting`'s
    /// full-drain-before-return semantics — see the previous test's doc
    /// comment) to prove the terminal SSE `generation_timeout` frame is
    /// actually written to the wire before the function throws, satisfying
    /// issue #2265's "client gets ... a terminal SSE event (streaming)"
    /// acceptance criterion at the unit level.
    func testWriteSSEChunksIdleTimeoutWritesTerminalFrameBeforeThrowing() async throws {
        let stopCallCount = OSAllocatedUnfairLock(initialState: 0)
        let chunks = AsyncThrowingStream<ChatCompletionChunk, Error> { _ in
            // Never yields, never finishes — a genuinely stalled source.
        }

        let recordingWriter = TimeoutRecordingResponseBodyWriter()
        var writer: any ResponseBodyWriter = recordingWriter

        let app = ServerApp()
        do {
            _ = try await app.writeSSEChunks(
                chunks,
                to: &writer,
                encoder: JSONEncoder(),
                idleTimeout: .milliseconds(30),
                onIdleTimeout: { stopCallCount.withLock { $0 += 1 } }
            ) { _ in 1 }
            XCTFail("expected writeSSEChunks to throw once the idle timeout fires")
        } catch let error as ServerError {
            guard case .generationTimedOut = error else {
                XCTFail("expected .generationTimedOut, got \(error)")
                return
            }
        }

        XCTAssertEqual(stopCallCount.withLock { $0 }, 1, "onIdleTimeout must fire exactly once")
        let writes = await recordingWriter.writes
        XCTAssertEqual(writes.count, 1, "exactly one terminal SSE frame must be written")
        let frameText = String(buffer: writes[0])
        XCTAssertTrue(frameText.hasPrefix("data: "), "must be a well-formed SSE data frame: \(frameText)")
        XCTAssertTrue(frameText.contains("generation_timeout"), "terminal frame must name the timeout: \(frameText)")
    }

    /// The idle timeout resets on every chunk: a stream that keeps emitting
    /// — even slower than the idle window between individual chunks summed
    /// over the whole response — must complete successfully, never killed by
    /// a wall-clock cap. This is the distinction #2268 drew for the fuzz
    /// harness's OpenAI exemption, applied to ManifoldServer's streaming path.
    func testStreamingIdleTimeoutResetsAndAllowsSlowProgressingStream() async throws {
        let backend = ServerTestBackendFactory.loadedMock()
        let adapter = FakeChatCompletionsAdapter(
            chunkedResponse: ChatCompletionResponse(model: "fake-model", content: "slow"),
            tokens: ["a", "b", "c", "d", "e"]
        )
        // Each chunk arrives 60ms apart; 5 chunks span ~300ms total — well
        // past a naive single-shot wall-clock cap of, say, 100ms — but the
        // idle timeout (100ms, reset every chunk) never sees more than 60ms
        // of silence, so the stream must complete uninterrupted.
        adapter.chunkPacing = .milliseconds(60)

        let app = ServerApp(
            configuration: ServerConfiguration(streamingIdleTimeout: .milliseconds(150)),
            backendProvider: FakeServerBackendProvider(backend: backend),
            adapter: adapter
        ).makeApplication()

        var request = ChatCompletionRequest(
            model: "fake-model",
            messages: [ChatCompletionMessage(role: .user, content: "hi")]
        )
        request.stream = true
        let body = ByteBuffer(bytes: try JSONEncoder().encode(request))

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, body: body) { response in
                XCTAssertEqual(response.status, .ok)
                let text = String(buffer: response.body)
                XCTAssertTrue(text.contains("[DONE]"), "stream must reach its normal terminal sentinel: \(text)")
                XCTAssertFalse(text.contains("generation_timeout"), "a slow-but-progressing stream must not be treated as timed out: \(text)")
            }
        }

        XCTAssertEqual(backend.stopCallCount, 0, "a healthy (if slow) stream must never trigger cancellation")
    }

    // MARK: - Output-size cap (maxGenerationOutputTokens)

    /// A request that specifies neither `max_tokens` nor
    /// `max_completion_tokens` must not reach the adapter with an unbounded
    /// `nil` — the server-configured ceiling is substituted.
    func testMaxGenerationOutputTokensSuppliedWhenRequestOmitsBoth() async throws {
        let adapter = FakeChatCompletionsAdapter()
        let app = ServerApp(
            configuration: ServerConfiguration(maxGenerationOutputTokens: 777),
            backendProvider: FakeServerBackendProvider(backend: ServerTestBackendFactory.loadedMock()),
            adapter: adapter
        ).makeApplication()

        let request = ChatCompletionRequest(
            model: "fake-model",
            messages: [ChatCompletionMessage(role: .user, content: "hi")]
        )
        let body = ByteBuffer(bytes: try JSONEncoder().encode(request))

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, body: body) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }

        XCTAssertEqual(adapter.requests.last?.maxCompletionTokens, 777)
    }

    /// A request that asks for more than the ceiling is clamped down to it,
    /// not honored verbatim.
    func testMaxGenerationOutputTokensClampsOversizedRequest() async throws {
        let adapter = FakeChatCompletionsAdapter()
        let app = ServerApp(
            configuration: ServerConfiguration(maxGenerationOutputTokens: 500),
            backendProvider: FakeServerBackendProvider(backend: ServerTestBackendFactory.loadedMock()),
            adapter: adapter
        ).makeApplication()

        var request = ChatCompletionRequest(
            model: "fake-model",
            messages: [ChatCompletionMessage(role: .user, content: "hi")]
        )
        request.maxTokens = 50_000
        let body = ByteBuffer(bytes: try JSONEncoder().encode(request))

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, body: body) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }

        XCTAssertEqual(adapter.requests.last?.maxCompletionTokens, 500)
    }

    /// `maxGenerationOutputTokens: nil` disables the ceiling entirely and
    /// restores pre-#2265 behavior — an unset request reaches the adapter
    /// with `maxCompletionTokens == nil` (unbounded), unchanged.
    func testMaxGenerationOutputTokensDisabledWhenNilLeavesRequestUnbounded() async throws {
        let adapter = FakeChatCompletionsAdapter()
        let app = ServerApp(
            configuration: ServerConfiguration(maxGenerationOutputTokens: nil),
            backendProvider: FakeServerBackendProvider(backend: ServerTestBackendFactory.loadedMock()),
            adapter: adapter
        ).makeApplication()

        let request = ChatCompletionRequest(
            model: "fake-model",
            messages: [ChatCompletionMessage(role: .user, content: "hi")]
        )
        let body = ByteBuffer(bytes: try JSONEncoder().encode(request))

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, body: body) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }

        XCTAssertNil(adapter.requests.last?.maxCompletionTokens)
        XCTAssertNil(adapter.requests.last?.maxTokens)
    }
}

/// Fake `ResponseBodyWriter` that records every write — mirrors
/// `SSEStreamWritingTests`'s private `RecordingResponseBodyWriter`, kept as
/// its own minimal copy here rather than shared since that type is `private`
/// to its file.
private actor TimeoutRecordingResponseBodyWriter: ResponseBodyWriter {
    private(set) var writes: [ByteBuffer] = []

    func write(_ buffer: ByteBuffer) async throws {
        writes.append(buffer)
    }

    func finish(_ trailingHeaders: HTTPFields?) async throws {}
}

#endif
