#if AppIntents
import XCTest
import ManifoldInference
@testable import ManifoldAppIntents

#if canImport(AppIntents)
import AppIntents

// MARK: - Fixtures

/// Non-streaming intent — used to verify the default `executeStreaming`
/// wrapper yields exactly one `.completed` event with the same body as the
/// single-shot `execute(arguments:)` would return.
@available(iOS 26, macOS 26, *)
struct StreamingEchoIntent: AppIntent, Decodable {

    static let title: LocalizedStringResource = "Echo"

    @Parameter(title: "Value")
    var value: String

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.value = try c.decode(String.self, forKey: .value)
    }

    private enum CodingKeys: String, CodingKey { case value }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: value)
    }
}

/// Two-checkpoint progress intent. Reports two `.progress` events with known
/// messages and fractions, then returns. Streams should emit
/// `[.progress, .progress, .completed]` in order.
@available(iOS 26, macOS 26, *)
struct ProgressIntent: ProgressReportingAppIntent, Decodable {

    static let title: LocalizedStringResource = "Progress"

    @Parameter(title: "Label")
    var label: String

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.label = try c.decode(String.self, forKey: .label)
    }

    private enum CodingKeys: String, CodingKey { case label }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // Pull the task-local reporter. nil-tolerant: if the executor didn't
        // install one (e.g. legacy single-shot dispatch) the calls are no-ops.
        if let reporter = IntentProgressReporter.current {
            await reporter.report(message: "step-1 \(label)", fraction: 0.5)
            await reporter.report(message: "step-2 \(label)", fraction: 1.0)
        }
        return .result(value: label)
    }
}

/// Nil-fraction variant — verifies optional fraction round-trips through
/// reporter → drain → stream without being coerced to a default value.
@available(iOS 26, macOS 26, *)
struct NilFractionIntent: ProgressReportingAppIntent, Decodable {

    static let title: LocalizedStringResource = "NilFraction"

    @Parameter(title: "Tag")
    var tag: String

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.tag = try c.decode(String.self, forKey: .tag)
    }

    private enum CodingKeys: String, CodingKey { case tag }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        if let reporter = IntentProgressReporter.current {
            await reporter.report(message: "indeterminate \(tag)", fraction: nil)
        }
        return .result(value: tag)
    }
}

/// Slow-cancellation intent — sleeps long enough that the outer task can
/// cancel mid-flight; `perform()` checks cancellation between sleeps.
@available(iOS 26, macOS 26, *)
struct SlowProgressIntent: ProgressReportingAppIntent, Decodable {

    static let title: LocalizedStringResource = "Slow"

    @Parameter(title: "Token")
    var token: String

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.token = try c.decode(String.self, forKey: .token)
    }

    private enum CodingKeys: String, CodingKey { case token }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        if let reporter = IntentProgressReporter.current {
            await reporter.report(message: "starting", fraction: 0.0)
        }
        // Long enough that the test will cancel before completion. Loop with
        // short sleeps so the cancellation observation is prompt.
        for _ in 0..<200 {
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            try Task.checkCancellation()
        }
        return .result(value: token)
    }
}

// MARK: - Tests

@available(iOS 26, macOS 26, *)
final class AppIntentStreamingTests: XCTestCase {

    // MARK: default-impl coverage

    func testDefaultStreamingYieldsOnlyCompletedEvent() async throws {
        // Non-streaming intent goes through the protocol-extension default,
        // which must wrap the single-shot `execute` into one `.completed`.
        let executor = AppIntentToolExecutor(StreamingEchoIntent.self)
        let args = JSONSchemaValue.object(["value": .string("ping")])

        var events: [ToolExecutionEvent] = []
        for try await event in executor.executeStreaming(arguments: args) {
            events.append(event)
        }

        XCTAssertEqual(events.count, 1, "non-streaming intent must yield exactly one event")
        guard case .completed(let result) = events[0] else {
            return XCTFail("only event must be .completed, got \(events[0])")
        }
        XCTAssertNil(result.errorKind)
        XCTAssertTrue(result.content.contains("ping"))

        // Sabotage check (manual): asserting events.count == 2 here fails as expected.
    }

    // MARK: progress-reporting intent

    func testProgressReportingIntentEmitsProgressThenCompleted() async throws {
        let executor = AppIntentToolExecutor(ProgressIntent.self)
        let args = JSONSchemaValue.object(["label": .string("hello")])

        var events: [ToolExecutionEvent] = []
        for try await event in executor.executeStreaming(arguments: args) {
            events.append(event)
        }

        XCTAssertEqual(events.count, 3, "expected [.progress, .progress, .completed], got \(events)")

        guard case .progress(let m1, let f1) = events[0] else {
            return XCTFail("first event must be .progress, got \(events[0])")
        }
        XCTAssertEqual(m1, "step-1 hello")
        XCTAssertEqual(f1, 0.5)

        guard case .progress(let m2, let f2) = events[1] else {
            return XCTFail("second event must be .progress, got \(events[1])")
        }
        XCTAssertEqual(m2, "step-2 hello")
        XCTAssertEqual(f2, 1.0)

        guard case .completed(let result) = events[2] else {
            return XCTFail("terminal event must be .completed, got \(events[2])")
        }
        XCTAssertNil(result.errorKind)
        XCTAssertTrue(result.content.contains("hello"))
    }

    // MARK: cancellation

    /// Documented cancellation semantics: when the **collector task** is
    /// cancelled, the stream terminates promptly without orphaning the work
    /// task — `onTermination` cancels both `workTask` and the reporter drain.
    /// The collector may observe any prefix of progress events plus an
    /// optional terminal `.completed`; the contract guarantees the iterator
    /// returns within a bounded time and the underlying work cooperates with
    /// cancellation (so resources aren't leaked).
    ///
    /// We pick "stream finishes; no orphaned task" over "always synthesise a
    /// terminal .completed(.cancelled)" because once the consumer has stopped
    /// reading, yielding a terminal event has no recipient and only races
    /// with `onTermination`. Producers that need to surface `.cancelled` to
    /// the model do so via the single-shot path (`execute(arguments:)`),
    /// which is what `ToolRegistry.dispatch` calls today.
    func testCancellationTerminatesStreamWithoutHanging() async throws {
        let executor = AppIntentToolExecutor(SlowProgressIntent.self)
        let args = JSONSchemaValue.object(["token": .string("x")])

        let collector = Task<[ToolExecutionEvent], Error> {
            var events: [ToolExecutionEvent] = []
            for try await event in executor.executeStreaming(arguments: args) {
                events.append(event)
            }
            return events
        }

        // Give perform() a moment to emit the initial progress event and
        // enter its sleep loop, then cancel.
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        collector.cancel()

        // Guard the test against a hang: race the collector against a
        // bounded timeout. If cancellation didn't propagate, this fails.
        let bounded = Task<Void, Error> {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = try? await collector.value
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 2_000_000_000) // 2s ceiling
                    throw CancellationError()
                }
                // Take whichever finishes first.
                try await group.next()
                group.cancelAll()
            }
        }

        do {
            try await bounded.value
        } catch {
            XCTFail("cancelled stream did not terminate within 2s: \(error)")
        }
    }

    /// Sanity check: producer-side completion of the slow intent (no
    /// cancellation, just wait for it) emits the initial `.progress` chunk
    /// before any terminal event. Pairs with the cancellation test above by
    /// proving the slow intent's progress channel is wired correctly.
    func testSlowIntentEmitsInitialProgress() async throws {
        // Override the sleep loop to be short — we just need to confirm the
        // event order. Re-use NilFractionIntent style by adding a tiny
        // wrapper inline here would balloon the fixture surface; instead we
        // assert against the first event of SlowProgressIntent and cancel
        // the collector once we've seen it.
        let executor = AppIntentToolExecutor(SlowProgressIntent.self)
        let args = JSONSchemaValue.object(["token": .string("y")])

        var stream = executor.executeStreaming(arguments: args).makeAsyncIterator()
        let first = try await stream.next()
        guard case .progress(let message, let fraction) = first else {
            return XCTFail("first event must be .progress, got \(String(describing: first))")
        }
        XCTAssertEqual(message, "starting")
        XCTAssertEqual(fraction, 0.0)
        // Drop the iterator so onTermination cancels the underlying tasks.
    }

    // MARK: nil fraction round-trip

    func testProgressEventRoundTripsNilFraction() async throws {
        let executor = AppIntentToolExecutor(NilFractionIntent.self)
        let args = JSONSchemaValue.object(["tag": .string("indet")])

        var events: [ToolExecutionEvent] = []
        for try await event in executor.executeStreaming(arguments: args) {
            events.append(event)
        }

        XCTAssertEqual(events.count, 2, "expected [.progress, .completed], got \(events)")

        guard case .progress(let message, let fraction) = events[0] else {
            return XCTFail("first event must be .progress, got \(events[0])")
        }
        XCTAssertEqual(message, "indeterminate indet")
        XCTAssertNil(fraction, "nil fraction must round-trip as nil, not 0.0")
    }
}

#endif // canImport(AppIntents)
#endif
