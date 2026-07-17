#if Server
@testable import ManifoldServer
import ManifoldInference
import Foundation
import Hummingbird
import HummingbirdCore
import HTTPTypes
import NIOCore
import XCTest

/// Regression guard for #2269: `ServerApp.writeSSEChunks` must stream each
/// token's SSE frame to the wire as it arrives, never buffering the whole
/// response and flushing it once at the end. Incremental per-token delivery
/// is `ManifoldServer`'s whole differentiator over a batching server, so a
/// future change that re-buffers the SSE loop must fail this test.
///
/// Drives `writeSSEChunks` directly with a fake `ResponseBodyWriter` and a
/// fake token stream that pauses between tokens — the in-process
/// `HummingbirdTesting` client fully drains the connection before handing
/// back a response, so it can't observe write-by-write timing (see
/// `SSECancellationTests`'s doc comment); calling the extracted function
/// directly sidesteps that.
///
/// Sabotage-evidence: replace the per-chunk `try await writer.write(buffer)`
/// call with buffering every frame into one `ByteBuffer` and writing it after
/// the loop — `testFirstFrameArrivesBeforeLastTokenIsProduced` fails because
/// the first recorded write timestamp would land after the token-producer
/// finishes instead of before it.
final class SSEStreamWritingTests: XCTestCase {
    /// `idleTimeout: nil` — the legacy simple for-loop branch in
    /// `writeSSEChunks`. Direct callers/tests that omit the parameter
    /// exercise this path, but it is NOT what a real `ServerApp` ever runs:
    /// `ServerConfiguration.streamingIdleTimeout` defaults to 60s (non-nil),
    /// so live traffic always takes the `ServerIdleTimeoutPuller`-backed
    /// branch below instead. See `testFirstFrameArrivesBeforeLastTokenIsProducedWithIdleTimeoutSet`.
    func testFirstFrameArrivesBeforeLastTokenIsProduced() async throws {
        try await assertIncrementalDelivery(idleTimeout: nil)
    }

    /// Same invariant as above, but with a non-nil `idleTimeout` — the
    /// branch every real `ServerApp` request actually takes, since
    /// `ServerConfiguration.streamingIdleTimeout` defaults on (#2265 review
    /// finding 6: without this, the #2269 incremental-flush guard only
    /// covered a dead branch once the idle timeout shipped default-on).
    /// `idleTimeout` here (5s) is far longer than the whole test (3 × 200ms
    /// token gaps ≈ 600ms), so it never fires — this test is purely about
    /// delivery timing, not the timeout itself.
    func testFirstFrameArrivesBeforeLastTokenIsProducedWithIdleTimeoutSet() async throws {
        try await assertIncrementalDelivery(idleTimeout: .seconds(5))
    }

    /// Sabotage-evidence: replace the per-chunk `try await writer.write(buffer)`
    /// call with buffering every frame into one `ByteBuffer` and writing it after
    /// the loop — both tests above fail because the first recorded write
    /// timestamp would land after the token-producer finishes instead of
    /// before it.
    private func assertIncrementalDelivery(idleTimeout: Duration?) async throws {
        let tokenGap = Duration.milliseconds(200)
        let tokenCount = 3

        let recordingWriter = RecordingResponseBodyWriter()
        var writer: any ResponseBodyWriter = recordingWriter

        let lastTokenProducedAt = ManagedAtomic<ContinuousClock.Instant?>(nil)
        let chunks = AsyncThrowingStream<ChatCompletionChunk, Error> { continuation in
            let task = Task {
                for i in 0..<tokenCount {
                    try await Task.sleep(for: tokenGap)
                    continuation.yield(ChatCompletionChunk(
                        id: "chatcmpl-pace",
                        created: 0,
                        model: "pace-model",
                        choices: [ChatCompletionChunkChoice(index: 0, delta: ChatCompletionDelta(content: "tok\(i)"))]
                    ))
                    if i == tokenCount - 1 {
                        await lastTokenProducedAt.set(.now)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }

        let app = ServerApp()
        _ = try await app.writeSSEChunks(
            chunks,
            to: &writer,
            encoder: JSONEncoder(),
            idleTimeout: idleTimeout
        ) { _ in 1 }

        let writes = await recordingWriter.writes
        // tokenCount data frames + the [DONE] sentinel.
        XCTAssertEqual(writes.count, tokenCount + 1)

        let firstFrameWrittenAt = writes[0].timestamp
        let lastTokenAt = await lastTokenProducedAt.value
        XCTAssertNotNil(lastTokenAt, "producer must have emitted its last token")

        XCTAssertLessThan(
            firstFrameWrittenAt,
            lastTokenAt!,
            "first SSE frame must reach the writer before the source stream finishes producing tokens — " +
            "streaming must stay incremental, never buffer-then-flush-at-end"
        )

        // Every write is spaced out rather than arriving in one final burst —
        // confirms the loop flushes per-token, not just "first one is early".
        for index in 1..<writes.count {
            XCTAssertGreaterThan(
                writes[index].timestamp,
                writes[index - 1].timestamp,
                "writes must be interleaved with token production, not coalesced at the end"
            )
        }
    }
}

// MARK: - Test doubles

/// Actor-backed timestamp box, since `ContinuousClock.Instant` capture across
/// concurrent tasks needs a safe hand-off (mirrors the pattern already used
/// by `ConcurrencyRecorder` in `ManifoldServerSmokeTests`).
private actor ManagedAtomic<Value: Sendable> {
    private var storage: Value

    init(_ initial: Value) {
        self.storage = initial
    }

    var value: Value { storage }

    func set(_ newValue: Value) {
        storage = newValue
    }
}

/// Fake `ResponseBodyWriter` that timestamps every write instead of sending
/// bytes anywhere — lets the test assert write-by-write timing.
private actor RecordingResponseBodyWriter: ResponseBodyWriter {
    struct RecordedWrite {
        let buffer: ByteBuffer
        let timestamp: ContinuousClock.Instant
    }

    private(set) var writes: [RecordedWrite] = []

    func write(_ buffer: ByteBuffer) async throws {
        writes.append(RecordedWrite(buffer: buffer, timestamp: .now))
    }

    func finish(_ trailingHeaders: HTTPFields?) async throws {}
}

#endif
