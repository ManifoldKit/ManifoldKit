@preconcurrency import XCTest
import Foundation
@testable import ManifoldInference
import ManifoldTestSupport

// MARK: - ScriptedGenerationBackendTests

/// Unit tests for ``ScriptedGenerationBackend``.
///
/// These tests drive the backend directly without ``ConversationRuntime`` so
/// they cover only the backend's own scripting mechanics. Integration coverage
/// against the runtime lives in ``ScriptedBackendRuntimeTests``.
@MainActor
final class ScriptedGenerationBackendTests: XCTestCase {

    // MARK: - Drain helper

    /// Collects all events from a ``GenerationStream`` into an array.
    /// The helper propagates any error thrown by the stream.
    private func drain(_ stream: GenerationStream) async throws -> [GenerationEvent] {
        var collected: [GenerationEvent] = []
        for try await event in stream.events {
            collected.append(event)
        }
        return collected
    }

    // MARK: - Tests

    /// Tokens emitted by `.tokens(_:)` arrive in the scripted order.
    func test_tokens_emittedInOrder() async throws {
        let backend = ScriptedGenerationBackend(turns: [
            .tokens(["a", "b", "c"])
        ])

        let stream = try backend.generate(
            prompt: "hi", systemPrompt: nil, config: GenerationConfig()
        )
        let events = try await drain(stream)

        XCTAssertEqual(events, [.token("a"), .token("b"), .token("c")])
    }

    /// A `.kvCacheReuse` event arrives before the token events when using the
    /// `.kvCacheReuse(reuseCount:then:)` factory.
    func test_kvCacheReuse_emittedBeforeTokens() async throws {
        let backend = ScriptedGenerationBackend(turns: [
            .kvCacheReuse(reuseCount: 128, then: ["hi"])
        ])

        let stream = try backend.generate(
            prompt: "go", systemPrompt: nil, config: GenerationConfig()
        )
        let events = try await drain(stream)

        XCTAssertEqual(events.count, 2, "expected kvCacheReuse + token")
        XCTAssertEqual(events[0], .kvCacheReuse(promptTokensReused: 128))
        XCTAssertEqual(events[1], .token("hi"))
    }

    /// A `.diagnosticThrottle` event arrives before the token events when using
    /// the `.throttle(reason:then:)` factory.
    func test_throttle_emittedBeforeTokens() async throws {
        let backend = ScriptedGenerationBackend(turns: [
            .throttle(reason: "burst-limit", then: ["x"])
        ])

        let stream = try backend.generate(
            prompt: "go", systemPrompt: nil, config: GenerationConfig()
        )
        let events = try await drain(stream)

        XCTAssertEqual(events.count, 2, "expected diagnosticThrottle + token")
        XCTAssertEqual(events[0], .diagnosticThrottle(reason: "burst-limit"))
        XCTAssertEqual(events[1], .token("x"))
    }

    /// When using `.failMidStream(_:afterTokens:tokens:)`, the stream yields
    /// exactly `afterTokens` tokens then throws — remaining tokens are not emitted.
    func test_failMidStream_throwsAfterTokens() async throws {
        let testError = NSError(domain: "test", code: 42)
        let backend = ScriptedGenerationBackend(turns: [
            .failMidStream(testError, afterTokens: 2, tokens: ["a", "b", "c"])
        ])

        let stream = try backend.generate(
            prompt: "go", systemPrompt: nil, config: GenerationConfig()
        )

        var collected: [GenerationEvent] = []
        var caughtError: Error?
        do {
            for try await event in stream.events {
                collected.append(event)
            }
        } catch {
            caughtError = error
        }

        XCTAssertEqual(collected, [.token("a"), .token("b")],
                       "exactly 2 tokens before the throw")
        let nsError = try XCTUnwrap(caughtError as? NSError)
        XCTAssertEqual(nsError.code, 42)
    }

    /// Calling `generate` beyond the script length produces an empty stream
    /// that finishes normally.
    func test_exhaustedScript_returnsEmptyStream() async throws {
        let backend = ScriptedGenerationBackend(turns: [
            .tokens(["only-turn"])
        ])

        // Consume the only scripted turn.
        _ = try await drain(try backend.generate(
            prompt: "first", systemPrompt: nil, config: GenerationConfig()
        ))

        // Second call — no turns left.
        let stream = try backend.generate(
            prompt: "second", systemPrompt: nil, config: GenerationConfig()
        )
        let events = try await drain(stream)

        XCTAssertTrue(events.isEmpty, "exhausted script must produce an empty stream")
    }

    /// Each `generate` call increments `generateCallCount` by exactly one.
    func test_generateCallCount_incrementsEachCall() async throws {
        let backend = ScriptedGenerationBackend(turns: [
            .tokens(["t1"]),
            .tokens(["t2"]),
            .tokens(["t3"]),
        ])

        _ = try await drain(try backend.generate(
            prompt: "1", systemPrompt: nil, config: GenerationConfig()
        ))
        _ = try await drain(try backend.generate(
            prompt: "2", systemPrompt: nil, config: GenerationConfig()
        ))
        _ = try await drain(try backend.generate(
            prompt: "3", systemPrompt: nil, config: GenerationConfig()
        ))

        XCTAssertEqual(backend.generateCallCount, 3)
    }

    /// After `reset()`, the next `generate` call replays from the first turn.
    func test_reset_restartsFromFirstTurn() async throws {
        let backend = ScriptedGenerationBackend(turns: [
            .tokens(["first"]),
            .tokens(["second"]),
        ])

        let pass1turn1 = try await drain(try backend.generate(
            prompt: "a", systemPrompt: nil, config: GenerationConfig()
        ))
        let pass1turn2 = try await drain(try backend.generate(
            prompt: "b", systemPrompt: nil, config: GenerationConfig()
        ))

        backend.reset()

        let pass2turn1 = try await drain(try backend.generate(
            prompt: "c", systemPrompt: nil, config: GenerationConfig()
        ))
        let pass2turn2 = try await drain(try backend.generate(
            prompt: "d", systemPrompt: nil, config: GenerationConfig()
        ))

        XCTAssertEqual(pass1turn1, pass2turn1, "reset must replay turn 1 identically")
        XCTAssertEqual(pass1turn2, pass2turn2, "reset must replay turn 2 identically")
    }
}
