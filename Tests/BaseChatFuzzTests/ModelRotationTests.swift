#if Fuzz
import XCTest
import BaseChatInference
import BaseChatTestSupport
@testable import BaseChatFuzz

/// Covers `RotatingFuzzFactory` (the #501 driver for `--model all`): verifies
/// round-robin ordering, that multi-factory setups hit every child at least
/// once, and that rotation is deterministic across invocations.
///
/// The CLI-side integration (pin-vs-rotate branching in
/// `FuzzChatCLI.makeOllamaFactory`) is exercised manually per the acceptance
/// criterion — it requires a running Ollama daemon with ≥2 installed models,
/// which is unavailable to the CI environment.
final class ModelRotationTests: XCTestCase {

    // MARK: - Fixture

    /// Deterministic stand-in for a real `FuzzBackendFactory`. Each
    /// `makeHandle()` call returns a handle whose `modelId` matches the tag
    /// passed at init, which lets the tests inspect the rotation order by
    /// reading `handle.modelId`.
    struct TagFactory: FuzzBackendFactory {
        let tag: String
        func makeHandle() async throws -> FuzzRunner.BackendHandle {
            FuzzRunner.BackendHandle(
                backend: MockInferenceBackend(),
                modelId: tag,
                modelURL: URL(string: "stub:\(tag)")!,
                backendName: "stub",
                templateMarkers: nil
            )
        }
    }

    // MARK: - Tests

    /// Six calls across two child factories must yield [A, B, A, B, A, B].
    /// Sabotage check: pin the `% children.count` to always return 0 and the
    /// tail assertions flip — confirms the test actually sees the rotation
    /// (rather than passing because the first element happens to match).
    func test_rotation_pinsAtFixedSeed() async throws {
        let factory = RotatingFuzzFactory(children: [
            TagFactory(tag: "A"),
            TagFactory(tag: "B"),
        ])

        var observed: [String] = []
        for _ in 0..<6 {
            let handle = try await factory.makeHandle()
            observed.append(handle.modelId)
        }

        XCTAssertEqual(observed, ["A", "B", "A", "B", "A", "B"],
                       "rotation must round-robin in declaration order")
    }

    /// With three children and 2×count = 6 iterations, every child must be
    /// hit at least once. Mirrors the `--model all` acceptance test against a
    /// machine with multiple installed Ollama models.
    func test_modelAll_usesAllInstalled() async throws {
        let tags = ["alpha", "bravo", "charlie"]
        let factory = RotatingFuzzFactory(children: tags.map { TagFactory(tag: $0) })

        var counts: [String: Int] = [:]
        for _ in 0..<(tags.count * 2) {
            let handle = try await factory.makeHandle()
            counts[handle.modelId, default: 0] += 1
        }

        for tag in tags {
            XCTAssertGreaterThanOrEqual(counts[tag] ?? 0, 1,
                                        "every child factory must be hit at least once across 2×count iterations — missing: \(tag)")
        }
    }

    /// Pinning to a single child — the shape CLI uses for `--model <substr>`
    /// — must always return that one factory. Rotation becomes a no-op, which
    /// is the expected pre-#501 behaviour preservation.
    func test_modelHint_disablesRotation() async throws {
        // A single-element `RotatingFuzzFactory` models the CLI path where
        // `--model <substr>` resolves to one `OllamaFuzzFactory` and bypasses
        // the rotation wrapper entirely. Here we express that invariant
        // directly: with only one child, rotation must always hit it.
        let factory = RotatingFuzzFactory(children: [TagFactory(tag: "only")])

        for _ in 0..<4 {
            let handle = try await factory.makeHandle()
            XCTAssertEqual(handle.modelId, "only",
                           "pinning to a single child factory must keep `--model <substr>`-style behaviour intact")
        }
    }

    /// Two fresh `RotatingFuzzFactory` instances with the same ordered child
    /// list must produce the same rotation sequence. This is the contract
    /// `--replay` (#490) relies on: the UTF-8-sorted model list in the CLI
    /// keeps the index-to-model mapping stable across invocations.
    func test_rotation_isReproducibleAcrossInstances() async throws {
        let tags = ["a", "b", "c"]
        func take(_ n: Int) async throws -> [String] {
            let factory = RotatingFuzzFactory(children: tags.map { TagFactory(tag: $0) })
            var out: [String] = []
            for _ in 0..<n {
                out.append(try await factory.makeHandle().modelId)
            }
            return out
        }

        let first = try await take(9)
        let second = try await take(9)
        XCTAssertEqual(first, second, "rotation order must be a pure function of the child-factory list")
        XCTAssertEqual(first, ["a", "b", "c", "a", "b", "c", "a", "b", "c"])
    }
}
#endif
