import XCTest
@testable import ManifoldInference

/// Tests for ``ToolOutputPolicy`` enforcement at the ``ToolRegistry`` dispatch
/// boundary.
///
/// Coverage:
/// - rejection (the default action) replaces oversize content with an
///   `.invalidArguments` error and embeds the byte counts in the message
/// - truncation trims at a UTF-8 boundary and appends the suffix; total
///   byte count stays at-or-below `maxBytes`
/// - allow passes oversize content through unchanged
/// - exact-boundary content passes through unchanged
/// - multi-byte codepoints (CJK, emoji) never split mid-scalar
/// - already-errored results bypass the action switch and are simply trimmed
@MainActor
final class ToolOutputPolicyTests: XCTestCase {

    // MARK: Fixtures

    /// Executor that returns a caller-supplied content string verbatim.
    private struct FixedContentExecutor: ToolExecutor {
        let definition: ToolDefinition
        let content: String
        let kind: ToolResult.ErrorKind?

        init(name: String = "echo", content: String, kind: ToolResult.ErrorKind? = nil) {
            self.definition = ToolDefinition(name: name, description: "echo", parameters: .object([:]))
            self.content = content
            self.kind = kind
        }

        func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
            ToolResult(callId: "", content: content, errorKind: kind)
        }
    }

    private func makeCall(name: String = "echo") -> ToolCall {
        ToolCall(id: "call-1", toolName: name, arguments: "{}")
    }

    // MARK: - rejectWithError

    func test_oversizeContent_isRejected_withInvalidArgumentsKind_byDefault() async {
        let registry = ToolRegistry()
        registry.outputPolicy = ToolOutputPolicy(maxBytes: 16, onOversize: .rejectWithError)
        let payload = String(repeating: "a", count: 64)
        registry.register(FixedContentExecutor(content: payload))

        let result = await registry.dispatch(makeCall())

        XCTAssertEqual(result.errorKind, .invalidArguments)
        XCTAssertTrue(result.content.contains("output exceeds maxBytes"))
        XCTAssertTrue(result.content.contains("64"))
        XCTAssertTrue(result.content.contains("16"))
        XCTAssertEqual(result.callId, "call-1")
    }

    // MARK: - truncate

    func test_oversizeContent_isTruncatedAndSuffixed_underTruncatePolicy() async {
        let registry = ToolRegistry()
        let suffix = "...[t]"
        registry.outputPolicy = ToolOutputPolicy(
            maxBytes: 32,
            onOversize: .truncate(suffix: suffix)
        )
        let payload = String(repeating: "a", count: 200)
        registry.register(FixedContentExecutor(content: payload))

        let result = await registry.dispatch(makeCall())

        XCTAssertNil(result.errorKind)
        XCTAssertLessThanOrEqual(result.content.utf8.count, 32)
        XCTAssertTrue(result.content.hasSuffix(suffix))
        // Body bytes = maxBytes - suffix bytes = 32 - 6 = 26 'a's followed by suffix.
        XCTAssertEqual(result.content, String(repeating: "a", count: 26) + suffix)
    }

    func test_truncatePolicy_respectsMultiByteUTF8Boundary_emoji() async {
        let registry = ToolRegistry()
        // Each rocket emoji is 4 UTF-8 bytes. With maxBytes = 10 and a 0-byte
        // suffix budget (suffix = ""), two whole emojis (8 bytes) must fit;
        // the third would push us to 12 bytes — drop it.
        let suffix = ""
        registry.outputPolicy = ToolOutputPolicy(
            maxBytes: 10,
            onOversize: .truncate(suffix: suffix)
        )
        let payload = String(repeating: "🚀", count: 5)
        registry.register(FixedContentExecutor(content: payload))

        let result = await registry.dispatch(makeCall())

        XCTAssertNil(result.errorKind)
        XCTAssertLessThanOrEqual(result.content.utf8.count, 10)
        // Must round down to a whole codepoint count — never slice mid-emoji.
        XCTAssertEqual(result.content, "🚀🚀")
    }

    func test_truncatePolicy_respectsMultiByteUTF8Boundary_cjk() async {
        let registry = ToolRegistry()
        // CJK characters are 3 UTF-8 bytes each. With maxBytes = 8 and an
        // empty suffix, two characters (6 bytes) fit, the third would
        // overflow.
        registry.outputPolicy = ToolOutputPolicy(
            maxBytes: 8,
            onOversize: .truncate(suffix: "")
        )
        registry.register(FixedContentExecutor(content: "你好世界"))

        let result = await registry.dispatch(makeCall())

        XCTAssertNil(result.errorKind)
        XCTAssertLessThanOrEqual(result.content.utf8.count, 8)
        XCTAssertEqual(result.content, "你好")
    }

    // MARK: - allow

    func test_allowPolicy_passesOversizeContentThrough() async {
        let registry = ToolRegistry()
        registry.outputPolicy = ToolOutputPolicy(maxBytes: 8, onOversize: .allow)
        let payload = String(repeating: "z", count: 200)
        registry.register(FixedContentExecutor(content: payload))

        let result = await registry.dispatch(makeCall())

        XCTAssertNil(result.errorKind)
        XCTAssertEqual(result.content, payload)
    }

    // MARK: - exact boundary

    func test_contentExactlyAtMaxBytes_passesThroughUnchanged() async {
        let registry = ToolRegistry()
        registry.outputPolicy = ToolOutputPolicy(maxBytes: 32, onOversize: .rejectWithError)
        let payload = String(repeating: "x", count: 32)
        registry.register(FixedContentExecutor(content: payload))

        let result = await registry.dispatch(makeCall())

        XCTAssertNil(result.errorKind)
        XCTAssertEqual(result.content, payload)
        XCTAssertEqual(result.content.utf8.count, 32)
    }

    // MARK: - errored results bypass action switch

    func test_alreadyErroredResult_isTruncated_notReclassified() async {
        let registry = ToolRegistry()
        registry.outputPolicy = ToolOutputPolicy(maxBytes: 16, onOversize: .rejectWithError)
        let big = String(repeating: "e", count: 200)
        registry.register(FixedContentExecutor(content: big, kind: .permanent))

        let result = await registry.dispatch(makeCall())

        // The original errorKind is preserved; the policy doesn't reclassify
        // an existing error as .invalidArguments.
        XCTAssertEqual(result.errorKind, .permanent)
        XCTAssertLessThanOrEqual(result.content.utf8.count, 16)
        XCTAssertEqual(result.content, String(repeating: "e", count: 16))
    }

    // MARK: - default policy is permissive enough for typical results

    func test_defaultPolicy_passesSmallSuccessfulResultUnchanged() async {
        let registry = ToolRegistry()
        // No outputPolicy override — exercise the type's default.
        registry.register(FixedContentExecutor(content: "{\"answer\":42}"))

        let result = await registry.dispatch(makeCall())

        XCTAssertNil(result.errorKind)
        XCTAssertEqual(result.content, "{\"answer\":42}")
    }

    // MARK: - negative maxBytes is clamped to 0

    func test_negativeMaxBytes_isClampedToZero_atInit() {
        // Negative values would otherwise make every successful result oversize
        // and produce confusing "exceeds maxBytes (5 > -1)" diagnostics.
        let policy = ToolOutputPolicy(maxBytes: -1, onOversize: .rejectWithError)
        XCTAssertEqual(policy.maxBytes, 0)
    }

    func test_negativeMaxBytes_isClampedToZero_onSetterMutation() {
        var policy = ToolOutputPolicy(maxBytes: 1024)
        policy.maxBytes = -100
        XCTAssertEqual(policy.maxBytes, 0)
    }

    // MARK: - spillToFile

    func test_spillToFile_writesToDisk_andReturnsTemplatedPointer() async throws {
        let tempDir = makeTempSpillDirectory()
        ToolSpillReaper.setDefaultDirectoryOverride(tempDir)
        defer {
            ToolSpillReaper.setDefaultDirectoryOverride(nil)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let registry = ToolRegistry()
        let payload = String(repeating: "S", count: 4_096)
        registry.outputPolicy = ToolOutputPolicy(
            maxBytes: 64,
            onOversize: .spillToFile(threshold: 64) { bytes, url in
                "SPILL[\(bytes)]@\(url.path)"
            }
        )
        registry.register(FixedContentExecutor(content: payload))

        let result = await registry.dispatch(makeCall())

        XCTAssertNil(result.errorKind)
        XCTAssertTrue(result.content.hasPrefix("SPILL[\(payload.utf8.count)]@"),
                      "got: \(result.content)")

        let atIndex = try XCTUnwrap(result.content.firstIndex(of: "@"))
        let path = String(result.content[result.content.index(after: atIndex)...])
        XCTAssertFalse(path.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "expected spill file at \(path)")
        XCTAssertTrue(path.contains("tool-spill-"))
        XCTAssertTrue(path.hasSuffix(".txt"))

        let written = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(written, payload)
    }

    func test_spillToFile_belowThreshold_fallsBackToTruncate() async throws {
        let tempDir = makeTempSpillDirectory()
        ToolSpillReaper.setDefaultDirectoryOverride(tempDir)
        defer {
            ToolSpillReaper.setDefaultDirectoryOverride(nil)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let registry = ToolRegistry()
        // maxBytes < threshold: result is oversize per maxBytes but smaller
        // than threshold, so we truncate rather than spill.
        registry.outputPolicy = ToolOutputPolicy(
            maxBytes: 32,
            onOversize: .spillToFile(threshold: 4_096) { _, _ in "SHOULD_NOT_FIRE" }
        )
        let payload = String(repeating: "p", count: 200)
        registry.register(FixedContentExecutor(content: payload))

        let result = await registry.dispatch(makeCall())

        XCTAssertNil(result.errorKind)
        XCTAssertFalse(result.content.contains("SHOULD_NOT_FIRE"))
        XCTAssertLessThanOrEqual(result.content.utf8.count, 32)
        XCTAssertTrue(result.content.hasSuffix("... [truncated]"))
    }

    private func makeTempSpillDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolSpillTests-\(UUID().uuidString)", isDirectory: true)
    }
}
