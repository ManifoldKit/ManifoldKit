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
        let inputText = r.prompt.messages.map(\.text).joined()

        var findings: [Finding] = []
        var seen: Set<String> = []
        for fragment in Self.templateFragments {
            guard !seen.contains(fragment),
                  scannable.contains(fragment),
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
