#if Skills
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
#endif
