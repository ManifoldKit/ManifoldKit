import XCTest
@testable import ManifoldSkills

/// Negative-path coverage for the inline YAML frontmatter parser.
///
/// Every assertion test ships a sabotage-evidence note (M1/M2/M3) per
/// `Tests/README.md` line 175+. Workers sabotage-verified locally before
/// pushing; remove the comment block if a future change makes it stale.
final class YAMLFrontmatterTests: XCTestCase {

    func test_parse_validFrontmatter_returnsFields() {
        let doc = """
        ---
        name: explain
        description: Explain a snippet
        aliases: [explain-this, walk-through]
        ---
        Body line 1
        Body line 2
        """
        guard let parsed = SkillFrontmatterParser.parse(doc) else {
            return XCTFail("Expected valid parse")
        }
        XCTAssertEqual(parsed.fields["name"], .string("explain"))
        XCTAssertEqual(parsed.fields["description"], .string("Explain a snippet"))
        XCTAssertEqual(parsed.fields["aliases"], .list(["explain-this", "walk-through"]))
        XCTAssertTrue(parsed.body.contains("Body line 1"))
        // Sabotage-evidence: M1 swap `description` → `descr` (breaks key
        // match); M2 drop the closing `---` (forces unterminated path);
        // M3 change `aliases: [a, b]` to bare scalar — list assertion fails.
    }

    func test_parse_missingRequiredName_returnsNil_atLoaderLayer() {
        // The parser itself is permissive — required-key enforcement lives
        // in `SkillLoader.loadSkill`. Here we just confirm the parser does
        // *not* invent a name when none is present.
        let doc = """
        ---
        description: no name here
        ---
        body
        """
        let parsed = SkillFrontmatterParser.parse(doc)
        XCTAssertNotNil(parsed)
        XCTAssertNil(parsed?.fields["name"])
        // Sabotage-evidence: M1 add `name: foo` line → assertion below fires;
        // M2 strip closing fence → parsed becomes nil and first assert fails;
        // M3 rename `description` → `descr` (still parses, still no `name`).
    }

    func test_parse_unterminatedFence_returnsNil() {
        let doc = """
        ---
        name: foo
        description: never closes
        body without closing fence
        """
        XCTAssertNil(SkillFrontmatterParser.parse(doc))
        // Sabotage-evidence: M1 append `\n---` to the doc — parse succeeds and
        // assertion fails; M2 remove opening `---` — still returns nil but
        // for a different reason (caller can't tell — fine); M3 add a `name:`
        // line — parse still nil because fence still missing.
    }

    func test_parse_unknownKey_silentlyIgnored() {
        let doc = """
        ---
        name: foo
        description: bar
        weird_extension: 42
        ---
        body
        """
        guard let parsed = SkillFrontmatterParser.parse(doc) else {
            return XCTFail("Expected valid parse")
        }
        XCTAssertEqual(parsed.fields["weird_extension"], .string("42"))
        XCTAssertEqual(parsed.fields["name"], .string("foo"))
        // Sabotage-evidence: M1 remove `description:` → parse still ok; M2
        // make the value `[unterminated` → parseKeyValue returns nil and the
        // whole parse returns nil; M3 typo `name:` → `nam:` — `name` key
        // assertion fails.
    }

    func test_parse_listFlowStyle_parses() {
        let doc = """
        ---
        name: x
        description: x
        aliases: [a, b, "c, with comma"]
        ---
        """
        guard let parsed = SkillFrontmatterParser.parse(doc) else {
            return XCTFail("Expected valid parse")
        }
        XCTAssertEqual(parsed.fields["aliases"], .list(["a", "b", "c, with comma"]))
        // Sabotage-evidence: M1 drop the closing `]` — list parse returns
        // nil and assertion fails; M2 change `"c, with comma"` to bare
        // `c, with comma` — splits into 4 items; M3 rename key — assertion
        // can't find `aliases` and fails.
    }

    func test_parse_listBlockStyle_parses() {
        let doc = """
        ---
        name: x
        description: x
        aliases:
          - eli5
          - simple
        ---
        """
        guard let parsed = SkillFrontmatterParser.parse(doc) else {
            return XCTFail("Expected valid parse")
        }
        XCTAssertEqual(parsed.fields["aliases"], .list(["eli5", "simple"]))
        // Sabotage-evidence: M1 reduce the indent on `- simple` to 1 space (vs.
        // 2 on `- eli5`) — inconsistent-indent path returns nil; M2 swap the
        // `- ` for `* ` (unsupported bullet) — list terminates after the key
        // and the value comes back as `.list([])`; M3 drop the trailing `---`
        // — fence detection fails and `parse` returns nil.
    }

    func test_parse_listBlockStyle_singleItem() {
        let doc = """
        ---
        name: x
        description: x
        aliases:
          - eli5
        ---
        """
        guard let parsed = SkillFrontmatterParser.parse(doc) else {
            return XCTFail("Expected valid parse")
        }
        XCTAssertEqual(parsed.fields["aliases"], .list(["eli5"]))
    }

    func test_parse_listBlockStyle_emptyAllowed() {
        let doc = """
        ---
        aliases:

        name: foo
        description: bar
        ---
        """
        guard let parsed = SkillFrontmatterParser.parse(doc) else {
            return XCTFail("Expected valid parse")
        }
        XCTAssertEqual(parsed.fields["aliases"], .list([]))
        XCTAssertEqual(parsed.fields["name"], .string("foo"))
        // Sabotage-evidence: M1 add `  - eli5` between `aliases:` and the
        // blank line — assertion now sees `.list(["eli5"])`; M2 rename
        // `aliases:` → `alias:` — key check fails; M3 remove the blank line
        // separator — `name:` is still detected as a top-level key and the
        // empty-list resolution still holds.
    }

    func test_parse_listBlockStyle_stopAtNextKey() {
        let doc = """
        ---
        aliases:
          - eli5
        name: foo
        description: bar
        ---
        """
        guard let parsed = SkillFrontmatterParser.parse(doc) else {
            return XCTFail("Expected valid parse")
        }
        XCTAssertEqual(parsed.fields["aliases"], .list(["eli5"]))
        XCTAssertEqual(parsed.fields["name"], .string("foo"))
        XCTAssertEqual(parsed.fields["description"], .string("bar"))
        // Sabotage-evidence: M1 indent `name: foo` with two spaces — it'd be
        // skipped at the outer loop and `name` key assertion fails; M2 swap
        // `- eli5` for `  eli5` (no dash) — list terminates empty and
        // aliases-assertion fails; M3 drop closing `---` — parse returns nil.
    }

    func test_parse_listBlockStyle_inconsistentIndent_rejected() {
        let doc = """
        ---
        name: foo
        description: bar
        aliases:
          - eli5
            - simple
        ---
        """
        // The existing parser returns nil for malformed flow lists; the block
        // path matches that behaviour rather than silently dropping the key.
        XCTAssertNil(SkillFrontmatterParser.parse(doc))
        // Sabotage-evidence: M1 normalise both items to two-space indent →
        // parse succeeds and the nil assert fails; M2 remove the second item
        // entirely → single-item list parses fine; M3 strip closing `---` →
        // still nil but for the fence reason (acceptable).
    }

    func test_parse_listBlockStyle_commentLinesSkipped() {
        let doc = """
        ---
        name: foo
        description: bar
        aliases:
          # leading comment
          - eli5
          # mid comment
          - simple
        ---
        """
        guard let parsed = SkillFrontmatterParser.parse(doc) else {
            return XCTFail("Expected valid parse")
        }
        XCTAssertEqual(parsed.fields["aliases"], .list(["eli5", "simple"]))
    }

    func test_parse_listBlockStyle_quotedItem_unquoted() {
        // Block items mirror the flow-list behaviour around matched quotes so
        // values with commas or leading whitespace round-trip cleanly.
        let doc = """
        ---
        name: x
        description: x
        aliases:
          - "with, comma"
          - 'single quoted'
        ---
        """
        guard let parsed = SkillFrontmatterParser.parse(doc) else {
            return XCTFail("Expected valid parse")
        }
        XCTAssertEqual(parsed.fields["aliases"], .list(["with, comma", "single quoted"]))
    }

    func test_parse_quotedString_unescapesQuotes() {
        let doc = """
        ---
        name: "quoted name"
        description: 'single quoted'
        ---
        """
        guard let parsed = SkillFrontmatterParser.parse(doc) else {
            return XCTFail("Expected valid parse")
        }
        XCTAssertEqual(parsed.fields["name"], .string("quoted name"))
        XCTAssertEqual(parsed.fields["description"], .string("single quoted"))
        // Sabotage-evidence: M1 drop the closing `"` on `name:` → unquote
        // returns nil and we fall back to the raw `"quoted name` string
        // (assertion fails); M2 swap to backticks (unsupported) → raw form
        // returned; M3 add escape sequences (unsupported by this parser) —
        // would surface as literal characters and the assertion fails.
    }
}
