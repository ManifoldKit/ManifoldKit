#if MCP
import XCTest
@testable import BaseChatMCP

/// Walks the sanitizer fuzz corpus shipped at
/// `Sources/BaseChatFuzz/Resources/sanitizer-corpus/` and asserts every
/// seed strips cleanly:
///
/// - No `\u{1B}` (7-bit ESC) byte survives.
/// - No `\u{9B}` (8-bit CSI lead) byte survives.
/// - The wrapping `<tool_output>` envelope is intact (no premature closure).
///
/// Each escape category gets its own seed file. See the corpus README
/// for the complete list. Adding a regression-driven seed: drop a new
/// `.txt` file into the corpus directory; this test picks it up
/// automatically next run.
final class MCPContentSanitizerCorpusTests: XCTestCase {

    /// Locates the corpus directory by walking up from this test file
    /// until the BaseChatFuzz Resources path appears.
    private static func locateCorpusDirectory(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir
                .appendingPathComponent("Sources")
                .appendingPathComponent("BaseChatFuzz")
                .appendingPathComponent("Resources")
                .appendingPathComponent("sanitizer-corpus")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "MCPContentSanitizerCorpusTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate sanitizer-corpus directory"
        ])
    }

    func test_corpus_strippedClean() throws {
        let corpusDir = try Self.locateCorpusDirectory()
        let entries = try FileManager.default.contentsOfDirectory(
            at: corpusDir,
            includingPropertiesForKeys: nil
        )
        let textSeeds = entries.filter { $0.pathExtension == "txt" }
        XCTAssertFalse(textSeeds.isEmpty, "Corpus directory has no .txt seeds")

        for seedURL in textSeeds {
            let bytes = try Data(contentsOf: seedURL)
            // Some seeds embed bytes that aren't valid UTF-8 (the 8-bit CSI
            // case writes the proper UTF-8 encoding of U+009B as 0xC2 0x9B,
            // but we keep the fallback for future seeds that may carry raw
            // 0x9B bytes for completeness).
            let input = String(data: bytes, encoding: .utf8)
                ?? String(data: bytes, encoding: .isoLatin1)
                ?? ""
            XCTAssertFalse(input.isEmpty, "Seed \(seedURL.lastPathComponent) decoded to empty string")

            let result = MCPContentSanitizer.wrapForUntrustedSurface(input, serverDisplayName: "Test")

            // Envelope shape stays intact.
            XCTAssertTrue(
                result.hasPrefix("<tool_output server=\"Test\" trust=\"untrusted\">"),
                "Seed \(seedURL.lastPathComponent): envelope prefix corrupted"
            )
            XCTAssertTrue(
                result.hasSuffix("</tool_output>"),
                "Seed \(seedURL.lastPathComponent): envelope suffix corrupted"
            )

            // Inside the envelope, no ESC or 8-bit CSI byte should survive.
            // We trim the wrapper before checking so the final `</tool_output>`
            // doesn't trip a substring search for `>`.
            let body = result
                .replacingOccurrences(of: "<tool_output server=\"Test\" trust=\"untrusted\">\n", with: "")
                .replacingOccurrences(of: "\n</tool_output>", with: "")

            XCTAssertFalse(
                body.unicodeScalars.contains(where: { $0.value == 0x1B }),
                "Seed \(seedURL.lastPathComponent): ESC byte (U+001B) survived sanitization"
            )
            XCTAssertFalse(
                body.unicodeScalars.contains(where: { $0.value == 0x9B }),
                "Seed \(seedURL.lastPathComponent): 8-bit CSI byte (U+009B) survived sanitization"
            )
            XCTAssertFalse(
                body.unicodeScalars.contains(where: { $0.value == 0x07 }),
                "Seed \(seedURL.lastPathComponent): BEL byte (U+0007) survived sanitization"
            )
            // Null byte is a control character — stripUnsafe drops it via
            // the controlCharacters filter.
            XCTAssertFalse(
                body.unicodeScalars.contains(where: { $0.value == 0x00 }),
                "Seed \(seedURL.lastPathComponent): NUL byte (U+0000) survived sanitization"
            )

            // No premature envelope closure mid-body.
            XCTAssertEqual(
                result.components(separatedBy: "</tool_output>").count,
                2,
                "Seed \(seedURL.lastPathComponent): envelope was closed more than once"
            )
        }
    }
}
#endif
