import XCTest
@testable import ManifoldModelCatalog

/// Verifies ``ModelInfo/chatTemplateSHA256`` — the chat-template integrity digest
/// (Piece 1 of #1932). The hash is a verification signal only; it must never
/// influence which template drives rendering.
final class ModelInfoChatTemplateHashTests: XCTestCase {

    private func makeModel(chatTemplateRaw: String?) -> ModelInfo {
        ModelInfo(
            name: "Test",
            fileName: "test.gguf",
            url: URL(fileURLWithPath: "/virtual/test.gguf"),
            fileSize: 0,
            modelType: .gguf,
            chatTemplateRaw: chatTemplateRaw
        )
    }

    /// The digest is the lowercase-hex SHA-256 of the template's UTF-8 bytes.
    /// `2cf24dba…` is the canonical SHA-256 of the ASCII string "hello",
    /// independently verifiable via `printf 'hello' | shasum -a 256`.
    func test_chatTemplateSHA256_matchesKnownVector() {
        let model = makeModel(chatTemplateRaw: "hello")

        XCTAssertEqual(
            model.chatTemplateSHA256,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
    }

    /// A digest is 64 lowercase hex characters and stable across reads.
    func test_chatTemplateSHA256_isStableLowercaseHex() throws {
        let template = "{% for m in messages %}{{ m.role }}: {{ m.content }}{% endfor %}"
        let model = makeModel(chatTemplateRaw: template)

        let first = model.chatTemplateSHA256
        let second = model.chatTemplateSHA256

        let digest = try XCTUnwrap(first)
        XCTAssertEqual(first, second, "Digest must be deterministic for the same template")
        XCTAssertEqual(digest.count, 64)
        XCTAssertEqual(digest, digest.lowercased(), "Digest must be lowercase hex")
        XCTAssertTrue(digest.allSatisfy(\.isHexDigit))
    }

    /// Distinct templates produce distinct digests (collision sanity).
    func test_chatTemplateSHA256_differsForDifferentTemplates() {
        let a = makeModel(chatTemplateRaw: "template-A")
        let b = makeModel(chatTemplateRaw: "template-B")

        XCTAssertNotNil(a.chatTemplateSHA256)
        XCTAssertNotEqual(a.chatTemplateSHA256, b.chatTemplateSHA256)
    }

    /// No template → no digest.
    func test_chatTemplateSHA256_nilWhenNoTemplate() {
        let model = makeModel(chatTemplateRaw: nil)

        XCTAssertNil(model.chatTemplateSHA256)
    }
}
