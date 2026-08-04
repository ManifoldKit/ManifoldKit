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
                  !inputText.contains(fragment),                           // exact echo
                  !Self.isNearMissEcho(of: fragment, presentIn: inputText) // near-miss echo
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

    /// True when `fragment` (present in the model's output) is a near-miss
    /// echo of a delimiter that was already present in `inputText` — quoted
    /// back verbatim, or "repaired"/mirrored into its matching open/close
    /// counterpart WITHIN THE SAME bracket family. Real observed shapes:
    /// `[/INST]`→`[INST]`, `<|im_start|>`→`<|im_end|>`,
    /// `<start_of_turn>`→`<end_of_turn>`. Exact-substring echoes are already
    /// handled by the `inputText.contains` check at the call site; this
    /// guard only needs to catch the remaining near-miss forms. Conservative
    /// in the direction of suppressing: a fragment whose core identifier
    /// doesn't match ANY delimiter actually present in the input still fires
    /// (the false-negative guard).
    static func isNearMissEcho(of fragment: String, presentIn inputText: String) -> Bool {
        let targetCore = coreIdentifier(fragment)
        for candidate in templateFragments where inputText.contains(candidate) {
            if coreIdentifier(candidate) == targetCore { return true }
        }
        return false
    }

    /// Reduces a delimiter to a `"<bracket style>:<core>"` identifier so
    /// paired delimiters from the SAME family — `im_start`/`im_end`,
    /// `start_of_turn`/`end_of_turn`, `begin_of_text`/`end_of_text`,
    /// `start_header_id`/`end_header_id`, `INST`/`/INST` — reduce to the same
    /// identifier, while delimiters from DIFFERENT families never do, even
    /// when their content looks similar once punctuation is stripped.
    ///
    /// The bracket style is load-bearing, not cosmetic: Gemma 1/2/3's
    /// `<end_of_turn>` and Gemma 4's `<|end_of_turn>` are deliberately
    /// distinct delimiters from different template generations (see the
    /// `templateFragments` doc comment) — collapsing them here would
    /// suppress a genuine Gemma-4 leak whenever a mutator happened to inject
    /// the Gemma-1/2/3 form into the prompt. An earlier version of this
    /// function stripped `<`, `>`, `|` indiscriminately and merged the two;
    /// the one real false positive that shape ever caught (record
    /// `6c9a7fd6dc32`) traced to the since-fixed `TemplateTokenInjectMutator`
    /// splicing a token into the middle of another (Defect 1), not to a
    /// backend legitimately reformatting `<x>` as `<|x|>` — so there was no
    /// real echo shape left to justify the collapse.
    static func coreIdentifier(_ fragment: String) -> String {
        var s = fragment
        var style = "plain"
        if s.hasPrefix("<|") {
            style = "pipe"
            s = String(s.dropFirst(2))
            if s.hasSuffix("|>") {
                s = String(s.dropLast(2))
            } else if s.hasSuffix(">") {
                s = String(s.dropLast())
            }
        } else if s.hasPrefix("<") {
            style = "angle"
            s = String(s.dropFirst())
            if s.hasSuffix(">") {
                s = String(s.dropLast())
            }
        } else if s.hasPrefix("[") {
            style = "bracket"
            s = String(s.dropFirst())
            if s.hasSuffix("]") {
                s = String(s.dropLast())
            }
        }
        s = s.replacingOccurrences(of: "/", with: "")
        if s.hasPrefix("start_") {
            s = String(s.dropFirst("start_".count))
        } else if s.hasPrefix("end_") {
            s = String(s.dropFirst("end_".count))
        } else if s.hasPrefix("begin_") {
            s = String(s.dropFirst("begin_".count))
        } else if s.hasSuffix("_start") {
            s = String(s.dropLast("_start".count))
        } else if s.hasSuffix("_end") {
            s = String(s.dropLast("_end".count))
        }
        return "\(style):\(s)"
    }

    /// Invisible/format Unicode scalars that `UnicodeInjectMutator` splices
    /// into corpus input as tokenizer-edge probes, plus the two common
    /// zero-width characters it doesn't already cover (ZWSP, ZWNJ). Stripping
    /// these from both the model's echo and the original input before the
    /// containment check keeps the echo-guard aligned regardless of which
    /// side a backend's own normalization happens to touch.
    /// Filtering must operate on unicode SCALARS, not `Character`: Swift
    /// merges ZWJ/ZWNJ (Extend-class scalars) into the preceding grapheme
    /// cluster, so `"m\u{200D}"` is ONE `Character` and a `Character`-level
    /// set lookup against a standalone ZWJ never matches — the exact
    /// characters this guard exists to strip would survive it.
    static let invisibleScalars: Set<Unicode.Scalar> = {
        var scalars = Set(UnicodeInjectMutator.payloads.flatMap { $0.unicodeScalars })
        scalars.formUnion(["\u{200B}", "\u{200C}"]) // ZERO WIDTH SPACE, ZERO WIDTH NON-JOINER
        return scalars
    }()

    static func stripInvisibleCharacters(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { !invisibleScalars.contains($0) }))
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
