import Foundation

/// Closes a possibly-truncated JSON string so a partial streaming buffer parses.
///
/// As structured output streams in token by token, the accumulated buffer is
/// almost always mid-document: an unterminated string, a trailing `:` or `,`, a
/// half-written number, or unbalanced `{`/`[`. ``close(_:)`` walks the buffer
/// once, tracking string/escape state and the open-container stack, then appends
/// the minimal suffix that makes it valid JSON — dropping any dangling partial
/// token first.
///
/// This is the core of partial/snapshot typed streaming (#1917): the closed
/// string is parsed into ``PartialSnapshot/fields`` so SwiftUI can render the
/// object as it fills. It is deliberately *not* used to decode the final typed
/// value — that always comes from the raw, complete buffer — so a synthetically
/// closed string never produces a misleading `decoded` value.
enum LenientJSONCloser {

    /// Returns a parseable JSON string for `partial`, or `nil` when not even a
    /// best-effort close yields something parseable (e.g. empty input, or a
    /// buffer that has not yet reached an opening `{`/`[`).
    ///
    /// Handles:
    /// - open string → close the quote;
    /// - trailing `:` (key with no value) → drop the key and its quote;
    /// - trailing `,` → drop it;
    /// - mid-number / mid-literal (`true`/`false`/`null` prefix) → drop the
    ///   partial token;
    /// - unbalanced `{`/`[` → close in LIFO order.
    static func close(_ partial: String) -> String? {
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstOpen = trimmed.firstIndex(where: { $0 == "{" || $0 == "[" }) else {
            // Nothing structural yet — a bare partial scalar isn't a useful
            // snapshot. Let the caller treat it as "no fields yet".
            return nil
        }

        // Scan from the first opener so leading prose/fence text is ignored.
        let scanRegion = String(trimmed[firstOpen...])

        var stack: [Character] = []        // open containers, '{' or '['
        var inString = false
        var escaped = false
        // Index (into `chars`) just past the last byte we want to keep. We may
        // rewind it to drop a dangling partial token.
        let chars = Array(scanRegion)
        var keepCount = chars.count

        // Track where the current top-level-ish value token started so we can
        // drop a half-written number/literal. We only need the last value-start
        // outside of strings; reset on structural punctuation.
        var lastValueStart: Int? = nil
        // True once we've seen a ':' or container-open or ',' and are awaiting a
        // value (so a trailing partial scalar there is droppable).
        var awaitingValue = false

        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                i += 1
                continue
            }
            switch c {
            case "\"":
                inString = true
                lastValueStart = i
                awaitingValue = false
            case "{":
                stack.append("{")
                lastValueStart = nil
                awaitingValue = false
            case "[":
                stack.append("[")
                lastValueStart = nil
                awaitingValue = true
            case "}", "]":
                if !stack.isEmpty { stack.removeLast() }
                lastValueStart = nil
                awaitingValue = false
            case ":":
                lastValueStart = nil
                awaitingValue = true
            case ",":
                lastValueStart = nil
                awaitingValue = true
            case " ", "\t", "\n", "\r":
                break
            default:
                // Start of a number / literal value token.
                if lastValueStart == nil { lastValueStart = i }
            }
            i += 1
        }

        var result = ""

        if inString {
            // Unterminated string: close the quote. If a backslash was pending,
            // drop it first so we don't emit a dangling escape.
            if escaped {
                keepCount = chars.count - 1
            }
            result = String(chars[0..<keepCount]) + "\""
        } else {
            // If we're sitting on a half-written number/literal that isn't a
            // complete value, drop it. A value token is "complete enough" only
            // if it parses as a JSON scalar on its own.
            if let start = lastValueStart, start < chars.count {
                let tokenText = String(chars[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !tokenText.isEmpty && !isCompleteScalar(tokenText) {
                    keepCount = start
                }
            }
            var kept = String(chars[0..<keepCount])
            // Drop trailing structural punctuation that can't be followed by a
            // close: a dangling key-colon or comma.
            kept = dropTrailingDanglingPunctuation(kept)
            result = kept
        }

        // Close any still-open containers in LIFO order.
        for opener in stack.reversed() {
            result.append(opener == "{" ? "}" : "]")
        }

        _ = awaitingValue  // documented intent; punctuation drop covers the cases
        return result
    }

    /// Removes a trailing `:` (with its key) or `,` left dangling by a partial
    /// buffer, so the close suffix produces valid JSON.
    private static func dropTrailingDanglingPunctuation(_ s: String) -> String {
        var chars = Array(s)
        // Strip trailing whitespace first.
        while let last = chars.last, last == " " || last == "\n" || last == "\t" || last == "\r" {
            chars.removeLast()
        }
        guard let last = chars.last else { return String(chars) }
        if last == "," {
            chars.removeLast()
        } else if last == ":" {
            // Drop the colon, then the preceding string key (its quotes too) so
            // we don't leave a key with no value.
            chars.removeLast()
            while let c = chars.last, c == " " || c == "\n" || c == "\t" || c == "\r" {
                chars.removeLast()
            }
            // Remove the quoted key.
            if chars.last == "\"" {
                chars.removeLast()
                var escaped = false
                while let c = chars.last {
                    chars.removeLast()
                    if escaped {
                        escaped = false
                    } else if c == "\\" {
                        escaped = true
                    } else if c == "\"" {
                        break
                    }
                }
            }
            // Drop a now-dangling comma left before the removed key.
            while let c = chars.last, c == " " || c == "\n" || c == "\t" || c == "\r" {
                chars.removeLast()
            }
            if chars.last == "," { chars.removeLast() }
        }
        return String(chars)
    }

    /// Whether `token` is a complete JSON scalar (number, `true`/`false`/`null`).
    /// A bare prefix like `4` or `tr` mid-stream returns the same way `4` does —
    /// so we only treat it as complete when it parses as a standalone scalar.
    private static func isCompleteScalar(_ token: String) -> Bool {
        if token == "true" || token == "false" || token == "null" { return true }
        // A number is "complete" only if it's a fully-formed numeric literal and
        // not obviously mid-token (no trailing '.', 'e', '+', '-', 'E').
        if let last = token.last, ".eE+-".contains(last) { return false }
        guard let data = token.data(using: .utf8) else { return false }
        // JSONSerialization with .fragmentsAllowed accepts a bare scalar.
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return true
        } catch {
            return false
        }
    }
}

/// Detects completed elements of a top-level JSON array from a streaming token
/// feed and yields each element's exact text.
///
/// Drives ``InferenceService/streamEach(_:to:config:)``: the model emits a JSON
/// array, and this extractor — fed each token via ``consume(_:)`` — returns the
/// substring of every element the moment its matching close lands. Tracks the
/// top-level `[`, then per-element brace/bracket depth, string state, and
/// escapes so commas/brackets inside strings or nested objects don't split an
/// element early.
struct TopLevelArrayElementExtractor {
    private var buffer: [Character] = []
    private var sawArrayOpen = false
    private var depth = 0          // depth INSIDE the array (nested containers)
    private var inString = false
    private var escaped = false
    private var elementStart: Int? = nil

    /// Feeds a token fragment and returns the text of any elements completed by
    /// it. Usually empty; non-empty when one or more closing delimiters arrive.
    mutating func consume(_ fragment: String) -> [String] {
        var completed: [String] = []
        for c in fragment {
            buffer.append(c)
            let idx = buffer.count - 1

            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                continue
            }

            switch c {
            case "\"":
                inString = true
                if sawArrayOpen && depth == 0 && elementStart == nil {
                    elementStart = idx
                }
            case "[":
                if !sawArrayOpen {
                    sawArrayOpen = true
                } else {
                    if depth == 0 && elementStart == nil { elementStart = idx }
                    depth += 1
                }
            case "{":
                if sawArrayOpen {
                    if depth == 0 && elementStart == nil { elementStart = idx }
                    depth += 1
                }
            case "}":
                if sawArrayOpen && depth > 0 { depth -= 1 }
            case "]":
                if sawArrayOpen {
                    if depth > 0 {
                        depth -= 1
                    } else {
                        // Closing the top-level array — flush any element in
                        // progress (a trailing scalar without a comma).
                        if let start = elementStart {
                            let text = String(buffer[start..<idx])
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !text.isEmpty { completed.append(text) }
                            elementStart = nil
                        }
                        sawArrayOpen = false
                    }
                }
            case ",":
                if sawArrayOpen && depth == 0 {
                    if let start = elementStart {
                        let text = String(buffer[start..<idx])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { completed.append(text) }
                    }
                    elementStart = nil
                }
            default:
                // Start of a scalar element (number / literal).
                if sawArrayOpen && depth == 0 && elementStart == nil
                    && c != " " && c != "\n" && c != "\t" && c != "\r" {
                    elementStart = idx
                }
            }
        }
        return completed
    }
}
