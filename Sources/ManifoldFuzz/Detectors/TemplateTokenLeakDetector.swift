import Foundation

/// Inspired by c9cac45 — Phi-4 detected as ChatML. When template
/// auto-detection picks the wrong family, raw chat-template delimiters
/// (ChatML `<|im_start|>`, Llama `[INST]`, Gemma `<start_of_turn>`, etc.)
/// leak into the visible output instead of being consumed by the tokenizer.
///
/// Ships at `.flaky` severity — promotion to `.confirmed` requires the
/// calibration corpus + FP/TP gating planned in W2.C phase 2.
public struct TemplateTokenLeakDetector: Detector {
    public let id = "template-token-leak"
    public let humanName = "Chat-template token leak"
    public let inspiredBy = "c9cac45 — Phi-4 detected as ChatML"

    /// Literal delimiters representative of popular chat templates. Substring
    /// match is sufficient; these strings are long enough to avoid natural-
    /// language collisions outside of deliberate discussion of tokenizers.
    static let templateFragments: [String] = [
        "<|im_start|>",
        "<|im_end|>",
        "<|eot_id|>",
        "<|begin_of_text|>",
        "<|end_of_text|>",
        "<|start_header_id|>",
        "<|end_header_id|>",
        "<start_of_turn>",
        "<end_of_turn>",
        // Gemma 4 uses a distinct `<|…>`-delimited turn family (NOT Gemma 1/2/3's
        // `<…>` form), so the two entries above do not cover it. A Gemma-4 GGUF that
        // is mis-detected as another family leaks these into visible output — the
        // exact c9cac45-class regression this detector exists to catch. `<|turn>` is
        // the role-turn opener (and the prefix of the `<|turn>think` reasoning turn),
        // `<|end_of_turn>` the terminal delimiter (the most common leak when the close
        // token isn't treated as EOS), and the `<|tool…>` trio the native tool-call
        // channel. See PromptTemplate.gemma4 / ThinkingMarkers.gemma4.
        "<|turn>",
        "<|end_of_turn>",
        "<|tool>",
        "<|tool_call>",
        "<|tool_response>",
        "[INST]",
        "[/INST]",
    ]

    public init() {}

    public func inspect(_ r: RunRecord) -> [Finding] {
        // Adversarial guard: Markdown code fences or inline-code backticks
        // are legitimate ways to discuss template tokens (documentation,
        // tokenizer tutorials). Strip fenced blocks and inline-code spans
        // before scanning so prose about `<|im_start|>` doesn't fire.
        let scannable = Self.stripCodeSpans(r.raw)

        // Collect the full text of every input message so we can distinguish
        // "backend spontaneously generated a template token" (real bug) from
        // "backend echoed a token that was already in the user's prompt"
        // (expected for Foundation's no-template pass-through and for seeds /
        // mutators that deliberately inject template tokens like
        // TemplateTokenInjectMutator).
        //
        // `UnicodeInjectMutator` deliberately splices invisible/format
        // characters (RTL override, ZWJ, BOM, …) into the input to probe
        // tokenizer edges. Some backends echo the input back with those
        // characters silently dropped by their own normalization, which
        // desyncs the raw containment check below: `inputText.contains`
        // sees the obfuscated fragment, `scannable.contains` sees the
        // de-obfuscated one, and the echo-guard fails to recognize them as
        // the same fragment — producing a false "spontaneous leak" finding.
        // Strip the same invisible-character set from both sides before
        // comparing so an echoed-and-de-obfuscated fragment still matches.
        let inputText = Self.stripInvisibleCharacters(r.prompt.messages.map(\.text).joined())
        let normalizedScannable = Self.stripInvisibleCharacters(scannable)

        var findings: [Finding] = []
        var seen: Set<String> = []
        for fragment in Self.templateFragments {
            guard !seen.contains(fragment),
                  normalizedScannable.contains(fragment),
                  !inputText.contains(fragment)   // skip echoed-input fragments
            else { continue }
            seen.insert(fragment)
            findings.append(.init(
                detectorId: id,
                subCheck: "template-fragment",
                severity: .flaky,
                trigger: fragment,
                modelId: r.model.id
            ))
        }
        return findings
    }

    /// Invisible/format Unicode scalars that `UnicodeInjectMutator` splices
    /// into corpus input as tokenizer-edge probes, plus the two common
    /// zero-width characters it doesn't already cover (ZWSP, ZWNJ). Stripping
    /// these from both the model's echo and the original input before the
    /// containment check keeps the echo-guard aligned regardless of which
    /// side a backend's own normalization happens to touch.
    static let invisibleCharacters: Set<Character> = {
        var chars = Set(UnicodeInjectMutator.payloads)
        chars.formUnion(["\u{200B}", "\u{200C}"]) // ZERO WIDTH SPACE, ZERO WIDTH NON-JOINER
        return chars
    }()

    static func stripInvisibleCharacters(_ s: String) -> String {
        String(s.filter { !invisibleCharacters.contains($0) })
    }

    /// Removes triple-backtick fenced blocks and single-backtick spans so
    /// literal template delimiters discussed as documentation do not trip
    /// the detector. Best-effort — an unterminated fence drops everything
    /// after it, which is the conservative choice for a false-positive
    /// guard.
    static func stripCodeSpans(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var inFence = false
        var inInline = false
        var i = s.startIndex
        while i < s.endIndex {
            // Triple-backtick fence toggle.
            if !inInline, s[i...].hasPrefix("```") {
                inFence.toggle()
                i = s.index(i, offsetBy: 3)
                continue
            }
            // Inline-code backtick toggle (only when not inside a fence).
            if !inFence, s[i] == "`" {
                inInline.toggle()
                i = s.index(after: i)
                continue
            }
            if !inFence, !inInline {
                out.append(s[i])
            }
            i = s.index(after: i)
        }
        return out
    }
}
