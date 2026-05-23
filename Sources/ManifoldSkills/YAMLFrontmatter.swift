import Foundation

/// Minimal YAML frontmatter parser for `SKILL.md` files.
///
/// Why inline (no dependency): the SKILL.md frontmatter shape is constrained
/// (string scalars, single-quoted strings, simple flow-style lists). Pulling
/// in a full YAML library would inflate the build graph for ~30 lines of
/// parsing.
///
/// **Supported shapes:**
///   - `key: value`                — plain string scalar
///   - `key: "value"` / `'value'`  — quoted scalar (handles inner colons)
///   - `key: [a, b, c]`            — flow-style list
///   - `key:\n  - a\n  - b`        — block-style list (indent must be
///                                   consistent within the list; terminates at
///                                   next top-level key or end-of-frontmatter)
///
/// **Not supported (returns nil from `parse(_:)`):**
///   - Nested mappings
///   - Multi-line scalars (`>`, `|`)
///
/// Errors are surfaced as `nil` from the top-level parse — no `try?`, no
/// silent swallow. Callers log a warning and skip the file.
internal struct SkillFrontmatter: Sendable, Equatable {
    let fields: [String: SkillFrontmatterValue]
    let body: String
}

internal enum SkillFrontmatterValue: Sendable, Equatable {
    case string(String)
    case list([String])
}

internal enum SkillFrontmatterParser {

    /// Splits a `SKILL.md` document into frontmatter fields + body, or returns
    /// `nil` if the document has no terminated `---` fence pair.
    ///
    /// Returns `nil` for: missing opening fence, missing closing fence,
    /// or malformed `key: value` lines inside the fence.
    static func parse(_ contents: String) -> SkillFrontmatter? {
        // Normalise CRLF so Windows-authored SKILL.md files don't trip the
        // fence detector (rare but cheap).
        let normalised = contents.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalised.components(separatedBy: "\n")

        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return nil
        }

        var fence: Int?
        for index in 1..<lines.count where lines[index].trimmingCharacters(in: .whitespaces) == "---" {
            fence = index
            break
        }
        guard let closing = fence else { return nil }

        var fields: [String: SkillFrontmatterValue] = [:]
        var index = 1
        while index < closing {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip blank lines + comment-only lines. Indented `- ` items that
            // appear without an immediately-preceding `key:` opener are stray
            // garbage (an unterminated block list from a removed key); the
            // outer loop ignores them rather than failing the whole document.
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
                continue
            }
            // Only top-level keys (no leading whitespace) are recognised at
            // this layer. Indented lines that aren't part of an active block
            // list are skipped — block-list collection happens inside
            // `parseKeyValue`'s caller below.
            if line.first == " " || line.first == "\t" {
                index += 1
                continue
            }
            guard let pair = parseKeyValue(trimmed) else {
                return nil
            }
            // A bare `key:` with no inline value is a block-list opener.
            // Look ahead for `<indent>- value` lines; absence of any items is
            // not an error — the key just resolves to an empty list. Mixed or
            // inconsistent indents inside the block fail the whole document.
            if case .string("") = pair.1 {
                let (block, consumed) = collectBlockList(lines: lines, start: index + 1, closing: closing)
                switch block {
                case .invalid:
                    return nil
                case .items(let values):
                    fields[pair.0] = .list(values)
                    index += consumed
                }
            } else {
                fields[pair.0] = pair.1
            }
            index += 1
        }

        let body: String
        if closing + 1 < lines.count {
            body = lines[(closing + 1)...].joined(separator: "\n")
        } else {
            body = ""
        }
        return SkillFrontmatter(fields: fields, body: body)
    }

    /// Parses a single `key: value` line into a typed value.
    ///
    /// Returns `nil` on shape errors (no colon, empty key, unterminated quote,
    /// unterminated list).
    private static func parseKeyValue(_ line: String) -> (String, SkillFrontmatterValue)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        let rawValue = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        if rawValue.isEmpty {
            return (key, .string(""))
        }
        if rawValue.hasPrefix("[") {
            return parseFlowList(rawValue).map { (key, .list($0)) }
        }
        if let unquoted = unquote(rawValue) {
            return (key, .string(unquoted))
        }
        return (key, .string(rawValue))
    }

    /// Strips matched single or double quotes; returns `nil` if the value is
    /// unquoted (caller falls back to raw text). Unterminated quotes are a
    /// hard error and bubble back as a nil from `parseKeyValue`.
    private static func unquote(_ value: String) -> String? {
        guard let first = value.first, first == "\"" || first == "'" else { return nil }
        guard value.count >= 2, value.last == first else { return nil }
        return String(value.dropFirst().dropLast())
    }

    /// Outcome of a block-list lookahead. `invalid` collapses the whole
    /// frontmatter parse (mixed indents); `items` covers both the empty-list
    /// case (`aliases:\n` followed immediately by a top-level key) and the
    /// populated case.
    private enum BlockListResult {
        case invalid
        case items([String])
    }

    /// Reads `<indent>- value` lines starting at `start` until the first line
    /// that is not part of the list (top-level key, end-of-frontmatter, or a
    /// differently-indented `- ` item which is treated as inconsistent).
    ///
    /// Returns the items collected plus the number of lines consumed past
    /// `start`. Blank lines and comment lines (`# …`) are skipped without
    /// terminating the list, matching YAML semantics.
    private static func collectBlockList(lines: [String], start: Int, closing: Int) -> (BlockListResult, Int) {
        var items: [String] = []
        var indent: Int?
        var consumed = 0
        var cursor = start
        while cursor < closing {
            let line = lines[cursor]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Blank lines + comments inside a block list do not terminate it.
            // (Top-level vs. indented makes no difference for blanks; an
            // indented `# comment` line still doesn't end the list.)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                cursor += 1
                consumed += 1
                continue
            }

            let leadingSpaces = line.prefix { $0 == " " }.count
            // A non-indented line ends the list (next top-level key, or any
            // other non-list content).
            if leadingSpaces == 0 {
                break
            }

            // Indented content that isn't `- ` ends the list — we don't try to
            // parse nested mappings.
            guard trimmed.hasPrefix("- ") || trimmed == "-" else {
                break
            }

            if let expected = indent {
                if leadingSpaces != expected {
                    return (.invalid, consumed)
                }
            } else {
                indent = leadingSpaces
            }

            let rawItem = String(trimmed.dropFirst(trimmed == "-" ? 1 : 2))
                .trimmingCharacters(in: .whitespaces)
            // Strip matched quotes so `- "with, comma"` round-trips like the
            // flow-list path.
            let item = unquote(rawItem) ?? rawItem
            items.append(item)
            cursor += 1
            consumed += 1
        }
        return (.items(items), consumed)
    }

    /// Parses YAML flow-style `[a, b, "c, d"]`. Returns `nil` on unterminated
    /// brackets or quote pairs — never a partial list.
    private static func parseFlowList(_ value: String) -> [String]? {
        guard value.hasPrefix("[") else { return nil }
        guard value.hasSuffix("]") else { return nil }
        let inner = String(value.dropFirst().dropLast())
        if inner.trimmingCharacters(in: .whitespaces).isEmpty { return [] }

        var items: [String] = []
        var current = ""
        var quote: Character?
        for char in inner {
            if let active = quote {
                if char == active {
                    quote = nil
                } else {
                    current.append(char)
                }
                continue
            }
            if char == "\"" || char == "'" {
                quote = char
                continue
            }
            if char == "," {
                items.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(char)
        }
        if quote != nil { return nil }
        items.append(current.trimmingCharacters(in: .whitespaces))
        // Filter out empty trailing items (e.g. `[a, b, ]`) but reject lists
        // that are entirely empty strings (those indicate a malformed source).
        let cleaned = items.filter { !$0.isEmpty }
        return cleaned
    }
}
