import Foundation

enum MCPContentSanitizer {
    /// Wraps tool output text in an untrusted-content envelope so the model
    /// can distinguish server-provided data from system instructions.
    static func wrapForUntrustedSurface(
        _ text: String,
        serverDisplayName: String
    ) -> String {
        let escapedName = serverDisplayName
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let stripped = stripUnsafe(text)
        return "<tool_output server=\"\(escapedName)\" trust=\"untrusted\">\n\(stripped)\n</tool_output>"
    }

    /// Strips terminal escape sequences and control bytes that a malicious
    /// MCP server could splice into tool output. ANSI sequences are dropped
    /// before the envelope is added so a `\u{1B}\\` byte pair inside a
    /// crafted DCS / OSC string cannot prematurely close the wrapping
    /// `<tool_output>` element. The patterns matched here mirror the ECMA-48
    /// / ANSI X3.64 escape categories that have historically been used to
    /// hide prompt-injection content from sandboxed renderers:
    ///
    /// - **CSI (7-bit)**: `ESC [ … <final byte>`. The original implementation
    ///   covered the limited set of letters that come up in practice; the
    ///   pattern below widens the final-byte class to any letter, since 7-bit
    ///   CSI sequences with arbitrary terminators are well within terminal
    ///   spec.
    /// - **CSI (8-bit)**: a single `\u{9B}` byte followed by the same parameter
    ///   bytes / final letter. Some emulators accept this when the terminal is
    ///   in 8-bit mode.
    /// - **OSC**: `ESC ] … <BEL | ESC \>`. Used by xterm to set window titles
    ///   and hyperlinks; OSC 8 in particular has been used for prompt-
    ///   injection hyperlinks that hide the visible text from a human
    ///   reviewer.
    /// - **DCS**: `ESC P … ESC \`. Device-Control-String envelopes that wrap
    ///   binary terminal commands.
    /// - **SOS / PM / APC**: `ESC X | ESC ^ | ESC _ … ESC \`. Rarely seen in
    ///   the wild but cheap to strip and within the same string-terminator
    ///   family as DCS.
    ///
    /// All four string-terminated families use either `BEL` (`\u{07}`) or
    /// the two-byte `ESC \` (`\u{1B}\u{5C}`) terminator. The `[^\u{1B}]*`
    /// body class is deliberately greedy-but-not-cross-escape: it stops at
    /// the next `ESC` so a single malformed sequence cannot consume the
    /// remainder of the document.
    private static let escapeStripPatterns: [String] = [
        "\u{1B}\\[[0-9;?]*[a-zA-Z]",                    // CSI 7-bit
        "\u{9B}[0-9;?]*[a-zA-Z]",                       // CSI 8-bit
        "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)", // OSC (BEL or ST terminator)
        "\u{1B}P[^\u{1B}]*\u{1B}\\\\",                  // DCS
        "\u{1B}[X^_][^\u{1B}]*\u{1B}\\\\",              // SOS / PM / APC
    ]

    private static func stripUnsafe(_ text: String) -> String {
        // Strip every ANSI / DEC escape category before any envelope-escape
        // substitutions so a `\u{1B}\\` byte sequence inside a DCS/OSC body
        // cannot survive into the final envelope.
        var result = text
        for pattern in escapeStripPatterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        // Strip envelope-escape attempts.
        result = result
            .replacingOccurrences(of: "</tool_output>", with: "&lt;/tool_output&gt;")
            .replacingOccurrences(of: "<tool_output", with: "&lt;tool_output")
        // Strip control characters (keep newline, tab, carriage return).
        result = String(result.unicodeScalars.filter { scalar in
            if CharacterSet.controlCharacters.contains(scalar) {
                return scalar.value == 10 || scalar.value == 13 || scalar.value == 9
            }
            return true
        })
        return result
    }
}
