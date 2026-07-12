#if Server
@testable import ManifoldServer
import ManifoldInference
import ManifoldTestSupport
import Foundation
import XCTest

/// End-to-end proof that the public
/// ``ManifoldServer/serve(configuration:backendProvider:)`` facade
/// (`Sources/ManifoldServer/ManifoldServer.swift`) actually binds a live HTTP
/// server and dispatches every request through the **injected**
/// `ServerBackendProvider` — every other suite in this target only exercises
/// `ServerApp.makeApplication()` via Hummingbird's in-process `.test(.router)`
/// client, which never calls `ManifoldServer.serve` (and therefore never
/// calls `ServerApp.run()` / a real socket bind) at all. Without this test,
/// the facade could be entirely inert — compiling, but never actually wired
/// to a listening socket or to the caller's provider — and nothing else in
/// this repo would catch it. This is exactly the class of bug this PR exists
/// to fix (the MLX/llama.cpp serve arms were unconditional stubs with no
/// public seam to bypass them).
///
/// Sabotage-evidence: swapping the `XCTAssertEqual(modelsList.data.map(\.id),
/// [injectedModelID])` assertion for an always-true check, or asserting on
/// a hardcoded token instead of the randomly-scripted ones below, would let
/// this test pass even if `ManifoldServer.serve` silently built its own
/// default provider instead of using the injected one.
final class ManifoldServerPublicFacadeTests: XCTestCase {
    func testPublicFacadeServesInjectedProviderOverRealSocket() async throws {
        let injectedModelID = "facade-injected-model-\(UUID().uuidString.prefix(8))"
        let tokens = ["seam-proof-", UUID().uuidString.prefix(8) + "-", "token-stream-live"]
        let backend = ServerTestBackendFactory.loadedMock(tokens: tokens)
        let provider = FacadeInjectedProvider(modelID: injectedModelID, backend: backend)

        let port = Int.random(in: 20_000..<40_000)
        let configuration = ServerConfiguration(host: "127.0.0.1", port: port)

        let serverTask = Task {
            try await ManifoldServer.serve(configuration: configuration, backendProvider: provider)
        }
        defer { serverTask.cancel() }

        try await waitForHealth(port: port)

        // GET /v1/models must list the INJECTED provider's model — proving
        // the facade dispatched to `provider`, not some internal default.
        let (modelsData, modelsResponse) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/v1/models")!
        )
        XCTAssertEqual((modelsResponse as? HTTPURLResponse)?.statusCode, 200)
        let modelsList = try JSONDecoder().decode(ModelsListResponse.self, from: modelsData)
        XCTAssertEqual(modelsList.data.map(\.id), [injectedModelID])

        // POST /v1/chat/completions (stream) must yield the mock backend's
        // real scripted tokens, proving generation was actually dispatched to
        // the injected `InferenceBackend`, not a stub response.
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatCompletionRequest(
            model: injectedModelID,
            messages: [.init(role: "user", content: "prove the seam")],
            stream: true
        ))

        let (bytes, chatResponse) = try await URLSession.shared.bytes(for: request)
        XCTAssertEqual((chatResponse as? HTTPURLResponse)?.statusCode, 200)

        // Parse and stop at the `[DONE]` sentinel rather than waiting for the
        // connection to close on its own — the response is sent with
        // `Connection: keep-alive` (correctly, so a real client can pipeline
        // further requests), so nothing ever half-closes the socket for us
        // the way Hummingbird's in-process `.test(.router)` client does. Real
        // SSE consumers (this repo's own OpenAI-compatible client guidance)
        // treat `[DONE]` as end-of-stream and stop reading the same way.
        // `bytes.lines` yields one physical line at a time (it does not
        // preserve the blank separator lines between SSE events), so decode
        // per-line rather than re-joining into `\n\n`-delimited blocks.
        let decoder = JSONDecoder()
        var chunks: [ChatCompletionChunk] = []
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst("data: ".count))
            if payload == "[DONE]" {
                break
            }
            if let chunk = try? decoder.decode(ChatCompletionChunk.self, from: Data(payload.utf8)) {
                chunks.append(chunk)
            }
        }
        let streamedContent = chunks.compactMap { $0.choices.first?.delta.content }.joined()
        for token in tokens {
            XCTAssertTrue(
                streamedContent.contains(token),
                "Expected streamed content to contain scripted token '\(token)'; got: \(streamedContent)"
            )
        }

        serverTask.cancel()
        _ = try? await serverTask.value
    }
}

private func waitForHealth(port: Int, timeout: Duration = .seconds(5)) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    var lastError: Error?
    while ContinuousClock.now < deadline {
        do {
            let (_, response) = try await URLSession.shared.data(
                from: URL(string: "http://127.0.0.1:\(port)/health")!
            )
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
        } catch {
            lastError = error
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    XCTFail("Server did not become healthy on port \(port) within \(timeout): \(String(describing: lastError))")
}

/// A `ServerBackendProvider` conformed entirely from outside this module's
/// internal types (only `ServerBackendRequest`/`ServerBackendProvider`, both
/// public) — mirroring exactly what a host app or companion package would
/// write, per this PR's public seam.
private struct FacadeInjectedProvider: ServerBackendProvider {
    let modelID: String
    let backend: any InferenceBackend

    func listModels() async throws -> [String] { [modelID] }

    func backend(for request: ServerBackendRequest) async throws -> any InferenceBackend {
        backend
    }
}

#endif
