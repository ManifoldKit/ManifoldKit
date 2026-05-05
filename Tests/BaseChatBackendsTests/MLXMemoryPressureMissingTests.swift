#if MLX && Llama
import XCTest
@testable import BaseChatBackends

/// Code-level regression guard for the MLX/Llama memory-pressure-handler
/// asymmetry called out by audit claim #1's neighbour finding:
///
/// - `LlamaBackend` registers a `MemoryPressureHandler` (#415, see
///   `LlamaBackend.swift`'s `private let memoryPressure = MemoryPressureHandler()`).
/// - `MLXBackend` does not register one as of this writing.
///
/// These tests read the two source files as plain strings and assert the
/// substring presence/absence directly. Reflection won't work — the field
/// would be `private` and Swift's `Mirror` doesn't expose private storage
/// across module boundaries — and `Mirror`-based checks would also miss the
/// case where the handler is registered without a matching stored field.
///
/// Why two tests rather than one: when the eventual MLX handler PR lands it
/// only flips the MLX assertion. Keeping Llama as a positive guard means the
/// audit asymmetry stays observable in the test output instead of dissolving
/// into a single negation.
final class MLXMemoryPressureMissingTests: XCTestCase {

    /// Resolves the path to a sibling Swift source file under
    /// `Sources/BaseChatBackends/`. `#filePath` points at this test file;
    /// going up to the package root and then back down is the most robust
    /// way to find the production source from a test target.
    private func sourcePath(for fileName: String) -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRoot = testFileURL
            .deletingLastPathComponent()  // Tests/BaseChatBackendsTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
        return packageRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("BaseChatBackends")
            .appendingPathComponent(fileName)
            .path
    }

    private func readSource(_ fileName: String) throws -> String {
        let path = sourcePath(for: fileName)
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    // FIXME: When MLX gains a memory-pressure handler, flip this assertion.
    // Confirms audit asymmetry: LlamaBackend has it (#415), MLX does not.
    func test_mlxBackend_hasNoMemoryPressureHandlerYet() throws {
        let source = try readSource("MLXBackend.swift")
        XCTAssertFalse(
            source.contains("MemoryPressureHandler"),
            "MLXBackend.swift unexpectedly contains 'MemoryPressureHandler' — if the handler was added, flip this assertion to XCTAssertTrue and remove the FIXME above."
        )
    }

    /// Positive guard: if the handler stops being wired up in
    /// `LlamaBackend`, the asymmetry the audit relies on no longer exists,
    /// and the eventual fix-up issue must be re-scoped.
    func test_llamaBackend_hasMemoryPressureHandler() throws {
        let source = try readSource("LlamaBackend.swift")
        XCTAssertTrue(
            source.contains("MemoryPressureHandler"),
            "LlamaBackend.swift no longer references 'MemoryPressureHandler' — the audit asymmetry has dissolved; revisit the perf-audit plan."
        )
    }
}
#endif
