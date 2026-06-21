import Foundation

/// Pure-Foundation markdown block parser shared by `ManifoldUI`'s
/// `AssistantMarkdownParser` and the fuzz harness.
///
/// `ManifoldUI` adds `AttributedString` rendering on top of these blocks for
/// the live SwiftUI message bubble; the fuzz harness needs a *headless*
/// approximation of the same transform so `RunRecord.rendered` reflects what
/// the user actually sees (code-fence handling, partial-fence salvage,
/// streaming edge cases) rather than a byte-for-byte copy of `raw`.
///
/// The parser is intentionally kept deterministic and free of SwiftUI / Combine
/// imports so it builds on every supported target — see issue #543.
public enum MarkdownRendering {

    /// One block produced by ``parseBlocks(from:)``. The UI builds a SwiftUI
    /// view per block; the fuzzer flattens the array back into a string.
    public enum Block: Equatable, Sendable {
        /// Plain prose / inline-formatted markdown (anything that isn't a
        /// fenced code block).
        case markdown(String)
        /// A fenced code block. `language` is the optional info-string after
        /// the opening fence (`` ```swift ``); `code` is the inner content
        /// with the wrapping fences stripped.
        case code(language: String?, code: String)
    }

    /// Splits `source` into prose / fenced-code blocks. Mirrors the behaviour
    /// of `AssistantMarkdownParser.parseBlocks` in `ManifoldUI`:
    ///
    /// - Recognises fences of three or more backticks with arbitrary leading
    ///   whitespace.
    /// - Tracks nested ` ```language ` openings so example fences embedded
    ///   inside an outer code block don't terminate it prematurely.
    /// - Salvages a stream that ends mid-fence by returning the entire input
    ///   as a single markdown block — what the UI renders during streaming
    ///   when the closing fence hasn't arrived yet.
    public static func parseBlocks(from source: String) -> [Block] {
        guard !source.isEmpty else { return [] }
        var blocks: [Block] = []
        var markdownBuffer = ""
        var codeBuffer = ""
        var isInCodeBlock = false
        var codeLanguage: String?
        var openingFenceLength = 0
        var nestedFenceDepth = 0

        let lines = source.components(separatedBy: "\n")
        for (lineIndex, line) in lines.enumerated() {
            let hadTrailingNewline = lineIndex < lines.count - 1

            if !isInCodeBlock {
                if let fence = parseFenceLine(line) {
                    if !markdownBuffer.isEmpty {
                        blocks.append(.markdown(markdownBuffer))
                        markdownBuffer = ""
                    }
                    isInCodeBlock = true
                    openingFenceLength = fence.ticks
                    codeLanguage = fence.rest.isEmpty ? nil : fence.rest
                    nestedFenceDepth = 0
                } else {
                    append(line: line, hadTrailingNewline: hadTrailingNewline, to: &markdownBuffer)
                }
                continue
            }

            if let fence = parseFenceLine(line), fence.ticks >= openingFenceLength {
                if fence.rest.isEmpty {
                    if nestedFenceDepth == 0 {
                        let code = codeBuffer.trimmingCharacters(in: .newlines)
                        blocks.append(.code(language: codeLanguage, code: code))
                        codeBuffer = ""
                        isInCodeBlock = false
                        openingFenceLength = 0
                        codeLanguage = nil
                        continue
                    }
                    nestedFenceDepth -= 1
                } else {
                    nestedFenceDepth += 1
                }
            }

            append(line: line, hadTrailingNewline: hadTrailingNewline, to: &codeBuffer)
        }

        // Streaming can end mid-fence; mirror the UI's "show the whole source
        // as plain markdown" salvage path so the fuzz `rendered` matches.
        if isInCodeBlock {
            return [.markdown(source)]
        }

        if !markdownBuffer.isEmpty {
            blocks.append(.markdown(markdownBuffer))
        }

        return blocks.isEmpty ? [.markdown(source)] : blocks
    }

    /// Headless approximation of what `AssistantMarkdownView` displays.
    ///
    /// For each parsed ``Block``:
    /// - ``Block/code(language:code:)`` is emitted as the inner code content
    ///   only — the user-visible string in `AssistantCodeBlockView` is the
    ///   code body; the language label is rendered separately as caption
    ///   chrome and is **not** part of the message text.
    /// - ``Block/markdown(_:)`` is emitted via ``stripMarkdownSyntax(_:)``
    ///   which removes the lightweight inline syntax (`*`, `_`, `` ` ``,
    ///   link `[text](url)` collapse) so the result is comparable to the
    ///   characters a user can select out of the bubble.
    ///
    /// This is **not** a full CommonMark renderer — it's the minimum viable
    /// flattening that lets fuzz detectors notice when a UI transform breaks
    /// (mid-stream cancellation, partial fences, mis-terminated tables, etc.).
    public static func renderToVisibleString(_ source: String) -> String {
        let blocks = parseBlocks(from: source)
        var out = ""
        for (i, block) in blocks.enumerated() {
            switch block {
            case .markdown(let text):
                out += stripMarkdownSyntax(text)
            case .code(_, let code):
                out += code
            }
            // Block separator: SwiftUI lays them out in a VStack with spacing,
            // which a user reads as a paragraph break. Approximate with a
            // single newline; the final block doesn't need a trailing one.
            if i < blocks.count - 1 {
                if !out.hasSuffix("\n") { out += "\n" }
            }
        }
        return out
    }

    /// Flattens a list of ``MessagePart`` values to the user-visible string.
    /// Only ``MessagePart/text(_:)`` parts contribute — images, tool calls,
    /// thinking blocks render as separate UI affordances, not inline text.
    public static func renderVisibleText(parts: [MessagePart]) -> String {
        var pieces: [String] = []
        for part in parts {
            if case .text(let text) = part {
                pieces.append(renderToVisibleString(text))
            }
        }
        return pieces.joined(separator: "\n")
    }

    // MARK: - Internals (also consumed by AssistantMarkdownParser)

    /// Returns the tick count and trailing info-string for a fence line, or
    /// `nil` if the line isn't a fence. Public-package surface so the
    /// `ManifoldUI` parser can delegate without re-implementing.
    public static func parseFenceLine(_ line: String) -> (ticks: Int, rest: String)? {
        let trimmedLeading = line.trimmingCharacters(in: .whitespaces)
        guard trimmedLeading.first == "`" else { return nil }

        var tickCount = 0
        var index = trimmedLeading.startIndex
        while index < trimmedLeading.endIndex, trimmedLeading[index] == "`" {
            tickCount += 1
            index = trimmedLeading.index(after: index)
        }
        guard tickCount >= 3 else { return nil }

        let rest = String(trimmedLeading[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (ticks: tickCount, rest: rest)
    }

    private static func append(line: String, hadTrailingNewline: Bool, to target: inout String) {
        target += line
        if hadTrailingNewline {
            target += "\n"
        }
    }

    /// Strips the inline markdown syntax that `AttributedString(markdown:)`
    /// would otherwise hide from the rendered glyphs. Deliberately small —
    /// the goal is "what characters does the user see", not full CommonMark.
    ///
    /// - Drops surrounding `*`, `**`, `_`, `__` emphasis markers.
    /// - Collapses `[label](url)` to `label` (link target is hidden chrome).
    /// - Drops single-backtick inline code wrappers, keeping the inner text.
    /// - Strips leading list/heading markers (`#`, `- `, `* `, `1. `) since
    ///   the UI renders them as glyphs / indentation rather than literal
    ///   characters in the selection.
    public static func stripMarkdownSyntax(_ source: String) -> String {
        // Scan once, character by character. Regex would be tidier but pulls
        // Foundation's Regex engine in unnecessarily.
        var out = ""
        let scalars = Array(source)
        var i = 0
        let n = scalars.count

        while i < n {
            let c = scalars[i]

            // Inline code: `…`
            if c == "`" {
                if let close = nextIndex(of: "`", in: scalars, after: i) {
                    out.append(contentsOf: scalars[(i + 1)..<close])
                    i = close + 1
                    continue
                }
            }

            // Link: [label](url) → label
            if c == "[" {
                if let closeBracket = nextIndex(of: "]", in: scalars, after: i),
                   closeBracket + 1 < n,
                   scalars[closeBracket + 1] == "(",
                   let closeParen = nextIndex(of: ")", in: scalars, after: closeBracket + 1) {
                    out.append(contentsOf: scalars[(i + 1)..<closeBracket])
                    i = closeParen + 1
                    continue
                }
            }

            // Emphasis markers — drop the marker, keep the inside text.
            // We only drop runs of 1–3 `*` or `_` here; nested content is
            // walked normally on the next loop iteration.
            if c == "*" || c == "_" {
                var run = 1
                while i + run < n && scalars[i + run] == c && run < 3 { run += 1 }
                i += run
                continue
            }

            out.append(c)
            i += 1
        }

        // Strip leading list/heading markers line-by-line.
        let stripped = out.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            stripLeadingBlockMarker(String(line))
        }.joined(separator: "\n")

        return stripped
    }

    private static func nextIndex(of target: Character, in scalars: [Character], after start: Int) -> Int? {
        var j = start + 1
        while j < scalars.count {
            if scalars[j] == target { return j }
            j += 1
        }
        return nil
    }

    // Manual single-pass scanner for `stripLeadingBlockMarker`. The previous
    // implementation compiled up to four NSRegularExpression objects on every
    // call (up to 4×N per render); this walks the line's characters once with
    // no regex compilation and no force-unwraps. Behavior is identical to the
    // anchored patterns it replaces:
    //   heading    ^#{1,6}\s+      bullet  ^\s*[-*+]\s+
    //   ordered    ^\s*\d+\.\s+    quote   ^>\s+
    // (`\s+` is greedy, so each branch also consumes the run of whitespace that
    // followed the marker — matching the regex match length exactly.)
    private static func stripLeadingBlockMarker(_ line: String) -> String {
        let chars = Array(line)
        let n = chars.count

        func dropWhitespace(from start: Int) -> String {
            var i = start
            while i < n, chars[i].isWhitespace { i += 1 }
            return String(chars[i...])
        }

        // Heading: 1–6 leading "#" immediately followed by whitespace.
        var h = 0
        while h < n, chars[h] == "#" { h += 1 }
        if h >= 1, h <= 6, h < n, chars[h].isWhitespace {
            return dropWhitespace(from: h)
        }

        // Bullet: optional leading whitespace, one of -*+, then whitespace.
        var b = 0
        while b < n, chars[b].isWhitespace { b += 1 }
        if b < n, chars[b] == "-" || chars[b] == "*" || chars[b] == "+",
           b + 1 < n, chars[b + 1].isWhitespace {
            return dropWhitespace(from: b + 1)
        }

        // Ordered list: optional leading whitespace, digits, ".", then whitespace.
        var o = 0
        while o < n, chars[o].isWhitespace { o += 1 }
        var d = o
        while d < n, chars[d] >= "0", chars[d] <= "9" { d += 1 }
        if d > o, d < n, chars[d] == ".", d + 1 < n, chars[d + 1].isWhitespace {
            return dropWhitespace(from: d + 1)
        }

        // Blockquote: ">" at the absolute start, then whitespace.
        if n >= 2, chars[0] == ">", chars[1].isWhitespace {
            return dropWhitespace(from: 1)
        }

        return line
    }
}
