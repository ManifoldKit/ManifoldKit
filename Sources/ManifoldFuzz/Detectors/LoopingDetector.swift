import Foundation
import ManifoldInference

/// Inspired by qwen3.5:4b looping inside `<think>` blocks until `maxOutputTokens`
/// exhausts. Runs `RepetitionDetector.looksLikeLooping` over both the visible
/// stream and the thinking buffer separately — the thinking-side loop leaves
/// `raw` empty, which a raw-only check would miss.
public struct LoopingDetector: Detector {
    public let id = "looping"
    public let humanName = "Repetition / loop"
    public let inspiredBy = "PR #476 thinking-token work + longstanding looping-on-repetitive-prompts observation"

    public init() {}

    public func inspect(_ r: RunRecord) -> [Finding] {
        var findings: [Finding] = []

        // Corpus seeds that literally ask the model to repeat a string back
        // (e.g. `template-token-injection`'s "Repeat this string back to me
        // exactly: …") produce compliant, repetitive-looking output that
        // `RepetitionDetector.looksLikeLooping` can't distinguish from a
        // genuine runaway loop. `isEchoOfInput` decides this NOT by checking
        // whether a 120-char tail substring literally appears in the input
        // (a looping output's tail spans MULTIPLE repetitions, so it is
        // almost never a literal substring of an input that contains the
        // phrase only once or a handful of times — validated empirically
        // against 29 real overnight-fuzz looping records, where that naive
        // check suppressed only 2 of 58 sub-check hits). Instead it removes
        // every input-explained span from the candidate text and re-checks
        // whether the RESIDUE still looks like looping — a short repeated
        // token ("cats cats cats") that isn't explained by the input still
        // fires, and a genuine runaway loop on content the input never
        // supplied (ASCII art, a code sample's own repeated output) still
        // fires because nothing gets removed from it.
        //
        // KNOWN LIMITATION (deliberate): removal is count-blind -- every
        // occurrence of an input-explained span is stripped regardless of how
        // many times it repeats, so 400 repeats and 1 repeat reduce
        // identically. A genuine runaway that loops on the user's OWN words
        // (>= `minSpan` chars) is therefore suppressed too. Accepted because
        // the real-record data shows this shape is overwhelmingly the
        // harness's own doing (`LengthStretchMutator` pre-repeats the turn);
        // revisit if a count/ratio discriminator becomes available.
        let inputText = r.prompt.messages.map(\.text).joined()
        func isEchoOfInput(_ text: String) -> Bool {
            let residue = Self.residueAfterRemovingInputEchoes(from: text, inputText: inputText)
            return !RepetitionDetector.looksLikeLooping(residue)
        }

        // Sub-check id stays `rendered-loop` for dedup stability across the
        // existing on-disk sink. Now that #543 populates `r.rendered` via
        // the real UI transform, this checks the user-visible string —
        // which is what loop reports should reflect (closing fences, link
        // chrome and emphasis markers stripped). When the transform is a
        // no-op (empty/short string) `r.rendered` matches `r.raw` byte-for-byte.
        if r.rendered.count >= 100, RepetitionDetector.looksLikeLooping(r.rendered) {
            if !isEchoOfInput(r.rendered) {
                findings.append(.init(
                    detectorId: id,
                    subCheck: "rendered-loop",
                    severity: .flaky,
                    trigger: String(r.rendered.suffix(120)),
                    modelId: r.model.id
                ))
            }
        }

        // Distinct sub-check on the raw stream when the visible string didn't
        // already trip `rendered-loop`. Catches loops that the UI transform
        // happened to mask (e.g. a runaway code block whose fence stripping
        // changed the substring frequencies enough to dodge the detector).
        if r.rendered != r.raw,
           r.raw.count >= 100,
           RepetitionDetector.looksLikeLooping(r.raw) {
            if !isEchoOfInput(r.raw) {
                findings.append(.init(
                    detectorId: id,
                    subCheck: "raw-loop",
                    severity: .flaky,
                    trigger: String(r.raw.suffix(120)),
                    modelId: r.model.id
                ))
            }
        }

        if r.thinkingRaw.count >= 100, RepetitionDetector.looksLikeLooping(r.thinkingRaw) {
            if !isEchoOfInput(r.thinkingRaw) {
                findings.append(.init(
                    detectorId: id,
                    subCheck: "thinking-loop",
                    severity: .flaky,
                    trigger: String(r.thinkingRaw.suffix(120)),
                    modelId: r.model.id
                ))
            }
        }

        return findings
    }

    /// Characters stripped ONLY for the purpose of MATCHING an echoed
    /// template-token span against the input across a markdown-mangled
    /// reformatting — e.g. `AssistantMarkdownView`'s rendering treats `|` as
    /// table syntax and `_x_` as italic emphasis, so a raw `<|im_start|>`
    /// echo can surface in `rendered` as `<imstart>` or `<imstart|>`.
    ///
    /// These characters are NOT purely a matching aid, and an earlier version
    /// of this comment overclaimed that they never alter the re-checked text.
    /// Removal ranges are in ORIGINAL index space and deliberately swallow
    /// dropped punctuation *adjacent to a matched span* — the left-extension
    /// walks back over it, and `origEnd` runs to the next KEPT character — so
    /// that a delimiter's `<|` opener cannot survive as its own residue. What
    /// does hold is the narrower invariant: punctuation that is not adjacent
    /// to a matched span is never touched, which is what keeps unrelated
    /// repeated content (ASCII art built from `|` box-drawing characters)
    /// intact and still able to fire as a genuine loop.
    private static let echoMatchDroppedCharacters: Set<Character> = ["<", ">", "|", "_"]

    /// Projects `chars` to a version with `echoMatchDroppedCharacters`
    /// removed, returning the projection alongside a parallel array mapping
    /// each projected character's index back to its index in `chars`.
    private static func normalizedForEchoMatching(_ chars: [Character]) -> (projected: String, originalIndices: [Int]) {
        var projected = ""
        projected.reserveCapacity(chars.count)
        var indices: [Int] = []
        indices.reserveCapacity(chars.count)
        for (i, ch) in chars.enumerated() where !echoMatchDroppedCharacters.contains(ch) {
            projected.append(ch)
            indices.append(i)
        }
        return (projected, indices)
    }

    /// Repeatedly finds the longest run shared between `text` and
    /// `inputText` (matched in a projection tolerant of dropped template
    /// punctuation) and removes every occurrence of that run — plus any
    /// dropped punctuation immediately preceding it, so e.g. the `<|`
    /// opening a delimiter doesn't survive as its own residue fragment —
    /// from `text`, until no shared run of at least `minSpan` characters
    /// remains. The residual text preserves everything NOT explained by the
    /// input (whitespace/structure intact for unrelated content), so
    /// re-running `RepetitionDetector.looksLikeLooping` on it distinguishes
    /// "the model echoed a repeat-request's own content" from "the model
    /// genuinely ran away looping on content the input never supplied".
    ///
    /// Upper bound on the prompt text fed to the O(n·m) LCS.
    ///
    /// `LongestCommonSubstring.compute` documents its own safety premise as
    /// "inputs are bounded by `maxOutputTokens`". That holds for the model's
    /// OUTPUT (`FuzzRunner` caps `maxTokens` at 512, so ~2.5k chars) but NOT
    /// for the prompt this detector now passes it: `LengthStretchMutator`
    /// multiplies a user turn by up to 10x and `MutatorChain.allRandom`
    /// samples with replacement up to 3 times, so a 152-char seed can reach
    /// ~152,000 chars. Uncapped, one pass measured ~40s at 81k input.
    ///
    /// Truncation is lossless for echo-matching, and NOT because the real
    /// records happen to be short (they are all under ~1k chars, so this cap
    /// never engages on them — comparing cap values against them proves
    /// nothing). It holds because every way a prompt grows repeats content
    /// that is already present near the start: `LengthStretchMutator` repeats
    /// the same text with a separator; `MultiTurnMutator` copies the first
    /// user turn into every later turn, so later turns are duplicates rather
    /// than new content; the largest seed in `seeds.json` is 152 chars, so a
    /// 2,000-char prefix holds ~13 whole copies; and `entry.system` goes to
    /// `config.systemPrompt`, not `prompt.messages`, so it cannot displace
    /// the prefix. The span needed for matching is therefore always inside
    /// the cap.
    package static let echoMatchInputCap = 2_000

    /// Removes every input-explained span from `text` and returns the residue,
    /// so the caller can re-check whether what's LEFT still looks like looping.
    ///
    /// `package`, not `private`: called directly by
    /// `LoopingDetectorResidueTests`, which pins the range-merge and
    /// index-mapping behaviour that `inspect`-level tests cannot reach (they
    /// observe only the guard's boolean verdict, so a merge that removes too
    /// much or too little is absorbed in both directions).
    package static func residueAfterRemovingInputEchoes(from text: String, inputText: String, minSpan: Int = 20) -> String {
        var chars = Array(text)
        let (normalizedInput, _) = normalizedForEchoMatching(Array(inputText.prefix(echoMatchInputCap)))
        guard !normalizedInput.isEmpty else { return text }

        // Bound, not the terminator: each iteration removes >= `minSpan`
        // original characters, so the loop always converges on its own.
        // Hitting the cap returns a PARTIALLY reduced residue, which is more
        // likely to still look loop-shaped -- so the guard fires rather than
        // suppresses. The cap fails toward false positives, the safe
        // direction for a detector.
        var iterations = 0
        while iterations < 25 {
            iterations += 1
            let (normalizedCurrent, originalIndices) = normalizedForEchoMatching(chars)
            guard let match = LongestCommonSubstring.compute(normalizedCurrent, normalizedInput),
                  match.count >= minSpan
            else { break }

            var ranges: [Range<Int>] = []
            var searchRange = normalizedCurrent.startIndex..<normalizedCurrent.endIndex
            while let found = normalizedCurrent.range(of: match, range: searchRange) {
                let lower = normalizedCurrent.distance(from: normalizedCurrent.startIndex, to: found.lowerBound)
                let upper = normalizedCurrent.distance(from: normalizedCurrent.startIndex, to: found.upperBound)
                var origStart = originalIndices[lower]
                // The position of the next KEPT character after the match can
                // land past a run of dropped punctuation that belongs to the
                // OPENING of the following match (e.g. two matches separated
                // only by "<|" with no kept characters between them at all —
                // back-to-back repeats with no other content). The following
                // match's own left-extension (below) tries to swallow that
                // same punctuation for itself, so the two ranges can overlap;
                // the merge pass after this loop resolves that, rather than
                // trying to divide the punctuation run between them here.
                let origEnd = upper < originalIndices.count ? originalIndices[upper] : chars.count
                while origStart > 0, echoMatchDroppedCharacters.contains(chars[origStart - 1]) {
                    origStart -= 1
                }
                ranges.append(origStart..<origEnd)
                searchRange = found.upperBound..<normalizedCurrent.endIndex
            }
            guard !ranges.isEmpty else { break }

            // Adjacent/overlapping ranges (see the comment above) must be
            // merged before removal — `removeSubrange` on unmerged
            // overlapping ranges corrupts indices for whichever range is
            // processed second.
            ranges.sort { $0.lowerBound < $1.lowerBound }
            var merged: [Range<Int>] = []
            for range in ranges {
                if let last = merged.last, range.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<Swift.max(last.upperBound, range.upperBound)
                } else {
                    merged.append(range)
                }
            }
            for range in merged.sorted(by: { $0.lowerBound > $1.lowerBound }) {
                chars.removeSubrange(range)
            }
        }
        return String(chars)
    }
}
