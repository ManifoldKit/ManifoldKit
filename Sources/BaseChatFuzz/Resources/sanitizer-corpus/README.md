# Sanitizer Fuzz Corpus

Seed inputs for `MCPContentSanitizer.stripUnsafe(_:)`. Each `.txt` file is one
input we expect the sanitizer to strip cleanly, leaving no `\u{1B}` (ESC) or
`\u{9B}` (8-bit CSI) bytes in the output and no premature closing of the
`<tool_output>` envelope.

## Variants covered

| File | Escape family | Threat |
|------|---------------|--------|
| `csi-7bit-sgr.txt` | CSI (7-bit) | ANSI colour codes used to obscure prompt-injected text. |
| `csi-8bit.txt` | CSI (8-bit, `\u{9B}` lead) | Some emulators decode this in 8-bit mode; previously not stripped. |
| `osc-bel.txt` | OSC, BEL-terminated | xterm window-title / OSC 8 hyperlink used to hide visible text. |
| `osc-st.txt` | OSC, `ESC \\` ST-terminated | Same as above but with the two-byte ST. |
| `dcs.txt` | DCS | Device-Control-String envelope wrapping arbitrary bytes. |
| `sos-pm-apc.txt` | SOS / PM / APC | Less common but same string-terminator family. |
| `mixed-csi-osc.txt` | Combined CSI + OSC | Realistic shape from a hostile MCP tool response. |
| `null-byte.txt` | Embedded `\u{00}` | Control byte the sanitizer must strip without truncating. |

## Updating

When adding a new escape family or finding a regression, append a new file
here with a one-line description of the threat in the table above. The
unit tests under `BaseChatMCPTests/MCPContentSanitizerCorpusTests.swift`
walk this directory at runtime and assert each input strips cleanly.
