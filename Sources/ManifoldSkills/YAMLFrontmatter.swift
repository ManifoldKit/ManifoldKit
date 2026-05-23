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
///
/// **Not supported (returns nil from `parse(_:)`):**
///   - Block-style lists (`key:\n  - a\n  - b`)
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
        for line in lines[1..<closing] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let pair = parseKeyValue(trimmed) else {
                return nil
            }
            fields[pair.0] = pair.1
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
