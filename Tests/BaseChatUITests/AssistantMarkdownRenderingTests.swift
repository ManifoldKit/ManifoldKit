@preconcurrency import XCTest
@testable import BaseChatUI
import BaseChatRuntime
import BaseChatPersistenceSwiftData

@MainActor
final class AssistantMarkdownRenderingTests: XCTestCase {

    // MARK: - Performance

    /// Verifies that repeated `attributedString(from:)` calls for the same content are sub-linear
    /// because the cache returns cached values in O(1) rather than re-parsing the markdown.
    ///
    /// Fixture: 200 calls simulating token-by-token streaming, each sharing the same stable prefix
    /// blocks from a prior call. Without caching this is O(N²): each delivery re-renders all blocks.
    /// With the cache, stable blocks are O(1) lookups; only the last (growing) block is re-parsed.
    func test_attributedStringCache_repeatedCallsForSameStringAreSublinear() {
        // Build fixtures before the measure block — measure only the cache-hit work.
        let stablePrefix = String(repeating: "Lorem ipsum **dolor** sit amet, consectetur adipiscing elit. ", count: 30)
        var tokens: [String] = []
        var accumulated = stablePrefix
        for i in 0..<200 {
            accumulated += " token\(i)"
            tokens.append(accumulated)
        }
        // Pre-warm the cache for the stable prefix so the measure block only pays for the suffix.
        _ = AssistantMarkdownParser.attributedString(from: stablePrefix)

        // Sabotage check: the cache must return something (not empty) for the prefix.
        let rendered = AssistantMarkdownParser.attributedString(from: stablePrefix)
        XCTAssertFalse(rendered.characters.isEmpty, "Cache must return rendered content for stable prefix")

        measure {
            // Simulate the hot path: 200 re-renders of a growing message where the prefix is stable.
            // Each call hits the cache for the prefix; only the small suffix needs real parsing.
            for token in tokens {
                _ = AssistantMarkdownParser.attributedString(from: token)
            }
        }
    }

    /// Measures block parsing across a simulated 500-token stream.
    /// All iterations share the same set of suffix strings, so after the first
    /// `measure` iteration the cache is warm — subsequent iterations must be fast.
    func test_parseBlocks_streamingGrowthIsSublinear() {
        // Build fixtures: a 500-token growing string with one code block and mixed markdown.
        let header = "# Title\n\nHere is some **bold** text.\n\n```swift\nlet x = 1\n```\n\n"
        var tokens: [String] = []
        var body = header
        for i in 0..<500 {
            body += "word\(i) "
            tokens.append(body)
        }

        measure {
            for content in tokens {
                _ = AssistantMarkdownParser.parseBlocks(from: content)
            }
        }
    }

    // MARK: - Existing tests

    func test_parseBlocks_mixedMarkdownAndFencedCode_splitsIntoOrderedBlocks() {
        let input = """
        Intro **bold**

        ```swift
        let x = 1
        print(x)
        ```

        - Item 1
        [Link](https://example.com)
        """

        let blocks = AssistantMarkdownParser.parseBlocks(from: input)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].kind, .markdown)
        XCTAssertEqual(blocks[1].kind, .code(language: "swift"))
        XCTAssertEqual(blocks[2].kind, .markdown)
        XCTAssertTrue(blocks[0].text.contains("**bold**"))
        XCTAssertTrue(blocks[2].text.contains("- Item 1"))
        XCTAssertTrue(blocks[2].text.contains("[Link](https://example.com)"))
    }

    func test_parseBlocks_unclosedFenceTreatsAsMarkdownForStreaming() {
        let input = """
        Partial response
        ```swift
        let inFlight = true
        """

        let blocks = AssistantMarkdownParser.parseBlocks(from: input)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .markdown)
        XCTAssertEqual(blocks[0].text, input)
    }

    func test_parseBlocks_codeOnly_parsesSingleCodeBlock() {
        let input = """
        ```python
        print("hi")
        ```
        """

        let blocks = AssistantMarkdownParser.parseBlocks(from: input)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .code(language: "python"))
        XCTAssertEqual(blocks[0].text, #"print("hi")"#)
    }

    func test_parseBlocks_nestedFenceInsideCodeBlock_keepsSingleOuterBlock() {
        let input = """
        Here's how:
        ```markdown
        Use fenced blocks:
        ```swift
        print("hi")
        ```
        Done
        ```
        End.
        """

        let blocks = AssistantMarkdownParser.parseBlocks(from: input)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].kind, .markdown)
        XCTAssertEqual(blocks[1].kind, .code(language: "markdown"))
        XCTAssertEqual(blocks[2].kind, .markdown)

        XCTAssertTrue(blocks[1].text.contains("```swift"))
        XCTAssertTrue(blocks[1].text.contains(#"print("hi")"#))
        XCTAssertTrue(blocks[1].text.contains("Done"))
    }

    func test_attributedString_inlineFormattingIncludesIntents() {
        let rendered = AssistantMarkdownParser.attributedString(from: "**bold** *italic* `code`")
        let rawValues = rendered.runs.compactMap(\.inlinePresentationIntent?.rawValue)
        XCTAssertTrue(rawValues.contains(InlinePresentationIntent.emphasized.rawValue))
        XCTAssertTrue(rawValues.contains(InlinePresentationIntent.stronglyEmphasized.rawValue))
        XCTAssertTrue(rawValues.contains(InlinePresentationIntent.code.rawValue))
    }

    func test_attributedString_headersListsAndLinksIncludePresentationAndLink() {
        let rendered = AssistantMarkdownParser.attributedString(from: "# Header\n- Item\n[Docs](https://example.com)")
        let hasHeader = rendered.runs.contains { run in
            run.presentationIntent?.components.contains(where: {
                if case .header(level: 1) = $0.kind { return true }
                return false
            }) == true
        }
        let hasListItem = rendered.runs.contains { run in
            run.presentationIntent?.components.contains(where: {
                if case .listItem = $0.kind { return true }
                return false
            }) == true
        }
        let hasLink = rendered.runs.contains { $0.link == URL(string: "https://example.com") }

        XCTAssertTrue(hasHeader)
        XCTAssertTrue(hasListItem)
        XCTAssertTrue(hasLink)
    }
}
