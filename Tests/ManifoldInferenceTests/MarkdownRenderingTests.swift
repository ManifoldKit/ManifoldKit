import XCTest
@testable import ManifoldInference

/// Coverage for the headless markdown flattener that the fuzz harness uses to
/// populate `RunRecord.rendered`. The UI's `AssistantMarkdownView` and the
/// fuzzer share `MarkdownRendering.parseBlocks` directly; the
/// `renderToVisibleString` entry point is fuzz-only and approximates what the
/// user sees so detectors can spot UI-layer rendering bugs (#543).
///
/// These tests anchor the divergence guarantees the PR's doc comment claims:
/// "closing fences disappear, emphasis markers collapse, link targets are
/// hidden, partial fences fall back to plain markdown". Without them, drift
/// between the parser and the UI would land silently.
final class MarkdownRenderingTests: XCTestCase {

    // MARK: - parseBlocks

    func test_parseBlocks_emptyInputProducesNoBlocks() {
        XCTAssertEqual(MarkdownRendering.parseBlocks(from: ""), [])
    }

    func test_parseBlocks_proseOnlyBecomesSingleMarkdownBlock() {
        let blocks = MarkdownRendering.parseBlocks(from: "Hello, world.")
        XCTAssertEqual(blocks, [.markdown("Hello, world.")])
    }

    func test_parseBlocks_fencedCodeBlockSeparatesProseAndCode() {
        let source = "Before\n```swift\nlet x = 42\n```\nAfter"
        let blocks = MarkdownRendering.parseBlocks(from: source)
        XCTAssertEqual(blocks, [
            .markdown("Before\n"),
            .code(language: "swift", code: "let x = 42"),
            .markdown("After"),
        ])
    }

    func test_parseBlocks_partialFenceFallsBackToWholeSourceAsMarkdown() {
        // Streaming end mid-fence: the UI shows the whole thing as plain
        // markdown until the closing fence arrives. The flattener mirrors
        // that so detectors see what's on screen.
        let streaming = "intro\n```swift\nlet x = 42"
        let blocks = MarkdownRendering.parseBlocks(from: streaming)
        XCTAssertEqual(blocks, [.markdown(streaming)])
    }

    func test_parseBlocks_nestedFenceInsideOuterCodeBlockDoesNotCloseEarly() {
        // Outer fence is 4 backticks so a nested ``` doesn't terminate it.
        let source = "````\nexample:\n```\ninner\n```\n````\nafter"
        let blocks = MarkdownRendering.parseBlocks(from: source)
        XCTAssertEqual(blocks.count, 2)
        guard case .code(_, let code) = blocks[0] else {
            return XCTFail("expected code block first, got \(blocks[0])")
        }
        XCTAssertTrue(code.contains("```"), "inner fence should survive")
        XCTAssertTrue(code.contains("inner"))
    }

    // MARK: - renderToVisibleString

    func test_render_dropsEmphasisMarkers() {
        let out = MarkdownRendering.renderToVisibleString("This is **bold** and *italic*.")
        XCTAssertEqual(out, "This is bold and italic.")
    }

    func test_render_collapsesLinkSyntaxToLabel() {
        let out = MarkdownRendering.renderToVisibleString("See [docs](https://example.com) for more.")
        XCTAssertEqual(out, "See docs for more.")
    }

    func test_render_stripsInlineCodeBackticks() {
        let out = MarkdownRendering.renderToVisibleString("Call `foo()` to start.")
        XCTAssertEqual(out, "Call foo() to start.")
    }

    func test_render_stripsLeadingHeadingMarkers() {
        let out = MarkdownRendering.renderToVisibleString("# Title\n## Subtitle\nbody")
        XCTAssertEqual(out, "Title\nSubtitle\nbody")
    }

    func test_render_stripsBulletAndOrderedListMarkers() {
        let out = MarkdownRendering.renderToVisibleString("- one\n- two\n1. first\n2. second")
        XCTAssertEqual(out, "one\ntwo\nfirst\nsecond")
    }

    func test_render_keepsCodeBlockBodyDropsFences() {
        // Closing fences disappear: that's a load-bearing claim of the PR.
        let source = "intro\n```\nlet x = 42\n```\nafter"
        let out = MarkdownRendering.renderToVisibleString(source)
        XCTAssertFalse(out.contains("```"), "fence ticks must not survive into rendered string")
        XCTAssertTrue(out.contains("let x = 42"))
        XCTAssertTrue(out.contains("intro"))
        XCTAssertTrue(out.contains("after"))
    }

    func test_render_partialFenceFlattensThroughInlineStripping() {
        // Mid-stream truncation: salvage path treats the whole source as a
        // markdown block, then `stripMarkdownSyntax` runs over it. The pair
        // of opening backticks reads as inline code, so the fence ticks are
        // stripped and the language token + body survive. This is a
        // deliberate approximation: the UI's `AttributedString(markdown:)`
        // would render the partial fence differently, but the fuzz
        // flattener is documented as a glyph-level approximation, not a
        // pixel-perfect mirror.
        let streaming = "```swift\nlet x"
        let out = MarkdownRendering.renderToVisibleString(streaming)
        XCTAssertTrue(out.contains("let x"), "code body survives the salvage path")
        XCTAssertTrue(out.contains("swift"), "info-string survives as plain text")
    }

    func test_render_divergesFromRawForRealisticMessage() {
        // The whole point of the field: detectors that read `rendered` must
        // see different bytes than detectors that read `raw`. If this ever
        // collapses to identity the field is back to being decorative.
        let raw = "**Important**: see [docs](https://example.com).\n\n```\nx\n```"
        let rendered = MarkdownRendering.renderToVisibleString(raw)
        XCTAssertNotEqual(rendered, raw)
        XCTAssertFalse(rendered.contains("**"))
        XCTAssertFalse(rendered.contains("](https://"))
        XCTAssertFalse(rendered.contains("```"))
    }

    func test_render_emptyStringYieldsEmptyString() {
        XCTAssertEqual(MarkdownRendering.renderToVisibleString(""), "")
    }

    // MARK: - renderVisibleText (MessagePart bridge)

    func test_renderVisibleText_concatenatesOnlyTextParts() {
        let parts: [MessagePart] = [
            .text("Hello **world**."),
            .image(data: Data(), mimeType: "image/png"),
            .text("More `text`."),
        ]
        let out = MarkdownRendering.renderVisibleText(parts: parts)
        XCTAssertEqual(out, "Hello world.\nMore text.")
    }

    func test_renderVisibleText_emptyPartsListYieldsEmptyString() {
        XCTAssertEqual(MarkdownRendering.renderVisibleText(parts: []), "")
    }

    // MARK: - stripLeadingBlockMarker (precompiled-regex parity)

    /// Verifies that the precompiled-regex path produces byte-identical output
    /// to the previously inline-compiled patterns across all four marker types,
    /// including indented (nested) bullet lines whose leading whitespace the
    /// `^\s*[-*+]\s+` pattern consumes along with the marker. Any divergence in
    /// pattern, anchoring, or whitespace handling would surface here.
    func test_render_blockMarkerStrippingIsByteIdenticalAcrossAllMarkerTypes() {
        // heading (all levels), bullet variants, ordered, blockquote, nested
        // bullets with leading whitespace, and plain prose (no marker).
        let input = """
            # H1
            ## H2
            ### H3
            #### H4
            ##### H5
            ###### H6
            - bullet dash
            * bullet star
            + bullet plus
              - nested dash
              * nested star
            1. first
            12. twelfth
            > blockquote
            plain prose
            """
        let expected = """
            H1
            H2
            H3
            H4
            H5
            H6
            bullet dash
            bullet star
            bullet plus
            nested dash
            nested star
            first
            twelfth
            blockquote
            plain prose
            """
        // renderToVisibleString exercises the full inline-stripping path, which
        // calls stripLeadingBlockMarker for every line of every markdown block.
        let result = MarkdownRendering.renderToVisibleString(input)
        XCTAssertEqual(result, expected,
            "stripLeadingBlockMarker output must be byte-identical to expected across all marker types")
    }
}
