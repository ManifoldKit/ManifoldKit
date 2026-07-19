#if Server
import XCTest
import Foundation
import ManifoldContract
import ManifoldInference
@testable import ManifoldServer

/// Regression coverage for #2312 — the concurrent cross-client output leak.
///
/// Under `manifold-server --parallel > 1`, `TraitAwareServerBackendProvider`
/// hands **one** cached backend instance to every concurrent request. Before
/// the fix, `ChatCompletionsAdapter` installed each request's history on that
/// shared *instance state* in a step separate from `generate(…)`, so request
/// B's install could overwrite request A's before A consumed it — returning one
/// client's answer to another.
///
/// The fix threads history on the `generate(…)` call stack via
/// `hints.history`. These tests fire many concurrent requests through the real
/// `DefaultChatCompletionsAdapter` against a **single shared backend** whose
/// response echoes the history it was handed, and assert every response matches
/// its own request.
///
/// **Sabotage proof (verified during development, #2312):** reverting
/// `ChatCompletionsAdapter.generate(for:using:)` to install history on shared
/// backend instance state — or pointing `EchoHistoryBackend.generate` at a
/// stored `self.lastHistory` set in a separate step — makes these tests fail
/// with cross-talk (a response carrying another request's marker), because the
/// `await Task.yield()` inside `generate` guarantees the concurrent requests
/// interleave on the shared instance.
final class ConcurrentRequestHistoryIsolationTests: XCTestCase {

    /// A shared backend whose streamed response is the last user turn of the
    /// history it received **on this call's `hints.history`** — the only honest
    /// way to detect cross-request history bleed. Reads history from the
    /// per-call parameter (never instance state) and yields mid-generate to
    /// force concurrent calls to interleave.
    final class EchoHistoryBackend: InferenceBackend, @unchecked Sendable {
        let isModelLoaded = true
        private let generatingLock = NSLock()
        private var _isGenerating = false
        var isGenerating: Bool { generatingLock.withLock { _isGenerating } }

        var capabilities: BackendCapabilities {
            BackendCapabilities(
                supportedParameters: [.temperature, .topP],
                maxContextTokens: 8192,
                requiresPromptTemplate: false,
                supportsSystemPrompt: true,
                supportsToolCalling: false,
                supportsStructuredOutput: false,
                cancellationStyle: .cooperative,
                supportsTokenCounting: false,
                supportsStreaming: true,
                isRemote: true
            )
        }

        func loadModel(from url: URL, plan: ModelLoadPlan) async throws {}

        func generate(
            prompt: String,
            systemPrompt: String?,
            config: GenerationConfig,
            hints: GenerationRuntimeHints
        ) throws -> GenerationStream {
            // Capture the per-call history on the stack — NOT into instance
            // state. This is the whole point of #2312.
            let echoed = hints.history.last(where: { $0.role == "user" })?.textContent ?? ""
            let raw = AsyncThrowingStream<GenerationEvent, Error> { continuation in
                Task {
                    // Widen the interleaving window so a shared-state regression
                    // would reliably surface as cross-talk.
                    await Task.yield()
                    continuation.yield(.token(echoed))
                    continuation.finish()
                }
            }
            return GenerationStream(raw)
        }

        func stopGeneration() {}
        func unloadModel() {}
    }

    private static func request(marker: String) -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: "echo-model",
            messages: [
                ChatCompletionMessage(role: "system", content: "You echo."),
                ChatCompletionMessage(role: "user", content: "first-\(marker)"),
                ChatCompletionMessage(role: "assistant", content: "ack-\(marker)"),
                ChatCompletionMessage(role: "user", content: marker),
            ]
        )
    }

    /// N concurrent non-streaming requests, each with a distinct marker, all
    /// served by one shared backend instance. Every response must echo its own
    /// marker.
    func test_concurrentRequests_eachResponseMatchesItsOwnHistory() async throws {
        let adapter = DefaultChatCompletionsAdapter()
        let backend = EchoHistoryBackend()
        let count = 24

        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for i in 0..<count {
                group.addTask {
                    let marker = "req-\(i)-ZULU"
                    let response = try await adapter.response(
                        for: Self.request(marker: marker),
                        using: backend
                    )
                    return (i, response.content)
                }
            }
            var seen = 0
            for try await (i, content) in group {
                seen += 1
                XCTAssertEqual(
                    content,
                    "req-\(i)-ZULU",
                    "Request \(i) received a response that does not match its own history — cross-client leak (#2312)."
                )
            }
            XCTAssertEqual(seen, count, "Every request must produce exactly one response.")
        }
    }

    /// Same isolation guarantee across repeated rounds, to shake out any
    /// interleaving the single-round test happened not to hit.
    func test_concurrentRequests_isolationHoldsAcrossRounds() async throws {
        let adapter = DefaultChatCompletionsAdapter()
        let backend = EchoHistoryBackend()

        for round in 0..<8 {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<12 {
                    group.addTask {
                        let marker = "r\(round)-c\(i)-ZULU"
                        let response = try await adapter.response(
                            for: Self.request(marker: marker),
                            using: backend
                        )
                        XCTAssertEqual(
                            response.content,
                            marker,
                            "Round \(round) request \(i) received another request's answer (#2312)."
                        )
                    }
                }
                try await group.waitForAll()
            }
        }
    }
}
#endif
