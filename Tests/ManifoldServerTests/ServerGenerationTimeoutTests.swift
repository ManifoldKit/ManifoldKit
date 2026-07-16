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
                XCTAssertTrue(text.contains("timeout"), "error envelope should mention the timeout: \(text)")
                XCTAssertTrue(text.contains("\"code\":\"generation_timeout\""), "error taxonomy must match the streaming path's code: \(text)")
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
    ///
    /// The idle-timeout/chunk-pacing ratio is deliberately generous (~6.7x,
    /// widened from an initial 150ms/60ms ≈ 2.5x that flaked on loaded CI
    /// runners — see #2279 review) — only the *gap* between two consecutive
    /// chunks needs to stay under the timeout for this test to pass, so the
    /// margin only has to absorb scheduling jitter on a single gap, not
    /// accumulate across the whole stream.
    func testStreamingIdleTimeoutResetsAndAllowsSlowProgressingStream() async throws {
        let backend = ServerTestBackendFactory.loadedMock()
        let adapter = FakeChatCompletionsAdapter(
            chunkedResponse: ChatCompletionResponse(model: "fake-model", content: "slow"),
            tokens: ["a", "b", "c", "d", "e"]
        )
        // Each chunk arrives 60ms apart; 5 chunks span ~300ms total — well
        // past a naive single-shot wall-clock cap of, say, 400ms — but the
        // idle timeout (400ms, reset every chunk) never sees more than 60ms
        // of silence, so the stream must complete uninterrupted.
        adapter.chunkPacing = .milliseconds(60)

        let app = ServerApp(
            configuration: ServerConfiguration(streamingIdleTimeout: .milliseconds(400)),
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

    /// Pins the clamp half of `boundedForOutputCap`: a request already
    /// *under* the ceiling must be honored verbatim, not further reduced.
    /// Without this, `min(requested ?? ceiling, ceiling)` could regress to
    /// just `ceiling` (always overriding the request) and every other test
    /// in this file would still pass — none of them assert a below-ceiling
    /// request is left alone. Verified by temporarily reverting the
    /// production code to `bounded.maxCompletionTokens = ceiling` and
    /// confirming this test fails (per-PR review requirement) before
    /// committing.
    func testMaxGenerationOutputTokensHonorsRequestBelowCeiling() async throws {
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
        request.maxTokens = 100
        let body = ByteBuffer(bytes: try JSONEncoder().encode(request))

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, body: body) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }

        XCTAssertEqual(adapter.requests.last?.maxCompletionTokens, 100, "a request already under the ceiling must be honored, not overridden")
    }

    // MARK: - max_tokens / max_completion_tokens validation

    /// `max_tokens: 0` (or negative) must be rejected with 400, matching
    /// OpenAI's own behavior — `min(0, ceiling) == 0` would otherwise flow
    /// through as a "successful" 200 response with an empty completion,
    /// which silently discards a malformed request instead of rejecting it.
    func testNonPositiveMaxTokensIsRejectedWith400() async throws {
        let adapter = FakeChatCompletionsAdapter()
        let app = ServerApp(
            backendProvider: FakeServerBackendProvider(backend: ServerTestBackendFactory.loadedMock()),
            adapter: adapter
        ).makeApplication()

        var request = ChatCompletionRequest(
            model: "fake-model",
            messages: [ChatCompletionMessage(role: .user, content: "hi")]
        )
        request.maxTokens = 0
        let body = ByteBuffer(bytes: try JSONEncoder().encode(request))

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, body: body) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
        XCTAssertTrue(adapter.requests.isEmpty, "a rejected request must never reach the adapter")

        var negativeRequest = ChatCompletionRequest(
            model: "fake-model",
            messages: [ChatCompletionMessage(role: .user, content: "hi")]
        )
        negativeRequest.maxCompletionTokens = -1
        let negativeBody = ByteBuffer(bytes: try JSONEncoder().encode(negativeRequest))
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, body: negativeBody) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
    }

    // MARK: - finish_reason truthfulness under the output cap (#2265 review finding 2)

    /// A non-streaming response cut off by the server's output-token
    /// ceiling must report `finish_reason: "length"`, not `"stop"` —
    /// `ChatCompletionEventMapper`'s `Accumulator.finishReason` never
    /// reports `.length` on its own (it only distinguishes `.toolCalls` vs
    /// `.stop`), so with the cap default-on, every client that omits
    /// `max_tokens` and gets cut off at the default ceiling would otherwise
    /// be told the model stopped naturally.
    func testNonStreamingFinishReasonIsLengthWhenOutputCapTruncates() async throws {
        // "one two three four five" is 5 whitespace-split tokens — at or
        // past a ceiling of 3, `correctedForOutputCapTruncation`'s fallback
        // token-estimate must classify this as cap-truncated.
        let adapter = FakeChatCompletionsAdapter(
            response: ChatCompletionResponse(model: "fake-model", content: "one two three four five")
        )
        let app = ServerApp(
            configuration: ServerConfiguration(maxGenerationOutputTokens: 3),
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
                let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: Data(buffer: response.body))
                XCTAssertEqual(decoded.choices.first?.finishReason, .length)
            }
        }
    }

    /// A non-streaming response that finishes comfortably under the ceiling
    /// must keep reporting `finish_reason: "stop"` — the correction only
    /// fires when truncation is actually likely.
    func testNonStreamingFinishReasonStaysStopWhenUnderCap() async throws {
        let adapter = FakeChatCompletionsAdapter(
            response: ChatCompletionResponse(model: "fake-model", content: "hi there")
        )
        let app = ServerApp(
            configuration: ServerConfiguration(maxGenerationOutputTokens: 500),
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
                let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: Data(buffer: response.body))
                XCTAssertEqual(decoded.choices.first?.finishReason, .stop)
            }
        }
    }

    /// Streaming counterpart: the terminal chunk's `finish_reason` must flip
    /// to `"length"` when the running token estimate reaches the ceiling.
    func testStreamingFinishReasonIsLengthWhenOutputCapTruncates() async throws {
        let adapter = FakeChatCompletionsAdapter(
            chunkedResponse: ChatCompletionResponse(model: "fake-model", content: "truncated"),
            tokens: ["one", "two", "three", "four", "five"]
        )

        let app = ServerApp(
            configuration: ServerConfiguration(maxGenerationOutputTokens: 3),
            backendProvider: FakeServerBackendProvider(backend: ServerTestBackendFactory.loadedMock()),
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
                let text = String(buffer: response.body)
                XCTAssertTrue(text.contains("\"finish_reason\":\"length\""), "terminal chunk must report length, not stop: \(text)")
                XCTAssertFalse(text.contains("\"finish_reason\":\"stop\""), "the truncated finish reason must not also appear as stop: \(text)")
            }
        }
    }

    /// Streaming counterpart of the "stays stop" case: comfortably under the
    /// ceiling, the terminal chunk keeps `finish_reason: "stop"`.
    func testStreamingFinishReasonStaysStopWhenUnderCap() async throws {
        let adapter = FakeChatCompletionsAdapter(
            chunkedResponse: ChatCompletionResponse(model: "fake-model", content: "hi"),
            tokens: ["hi"]
        )

        let app = ServerApp(
            configuration: ServerConfiguration(maxGenerationOutputTokens: 500),
            backendProvider: FakeServerBackendProvider(backend: ServerTestBackendFactory.loadedMock()),
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
                let text = String(buffer: response.body)
                XCTAssertTrue(text.contains("\"finish_reason\":\"stop\""), "must stay stop when under the cap: \(text)")
                XCTAssertFalse(text.contains("\"finish_reason\":\"length\""), "must not be misreported as length: \(text)")
            }
        }
    }

    // MARK: - parallelSlots > 1 gates real cancellation (#2265 review finding 1)

    /// `InferenceBackend.stopGeneration()`'s contract is backend-wide, not
    /// per-request, and `TraitAwareServerBackendProvider` hands out a single
    /// cached backend per model — so under `parallelSlots > 1`, cancelling
    /// on a timeout could kill an unrelated sibling request's healthy
    /// generation sharing that same backend. This pins that `stopGeneration()`
    /// must NOT be called when `parallelSlots > 1`, even though the request
    /// still times out. Without this test, `canCancelInFlightGenerationOnTimeout`
    /// could regress to always-true (e.g. someone "simplifying" the
    /// condition) and silently reintroduce the cross-request-cancellation
    /// hazard.
    func testNonStreamingTimeoutDoesNotCancelBackendWhenParallelSlotsExceedsOne() async throws {
        let backend = ServerTestBackendFactory.loadedMock()
        let adapter = FakeChatCompletionsAdapter()
        adapter.hangsForever = true

        let app = ServerApp(
            configuration: ServerConfiguration(parallelSlots: 4, generationTimeout: .milliseconds(50)),
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
                XCTAssertEqual(response.status, .gatewayTimeout, "the request must still time out")
            }
        }

        XCTAssertEqual(backend.stopCallCount, 0, "must NOT cancel the shared backend when other requests could be using it concurrently")
    }

    /// Streaming counterpart of the parallel-slots gate.
    func testStreamingIdleTimeoutDoesNotCancelBackendWhenParallelSlotsExceedsOne() async throws {
        let backend = ServerTestBackendFactory.loadedMock()
        let adapter = FakeChatCompletionsAdapter()
        adapter.hangsAfterFirstChunk = true

        let app = ServerApp(
            configuration: ServerConfiguration(parallelSlots: 4, streamingIdleTimeout: .milliseconds(80)),
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
            XCTFail("expected the idle timeout to still end the stream")
        } catch {
            // Expected — the request still times out, it just must not
            // touch the shared backend. Asserted below.
        }

        XCTAssertEqual(backend.stopCallCount, 0, "must NOT cancel the shared backend when other requests could be using it concurrently")
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
