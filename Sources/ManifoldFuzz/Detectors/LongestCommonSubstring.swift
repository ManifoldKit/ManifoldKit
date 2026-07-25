import Foundation

/// Longest common contiguous substring — the "did text X leak verbatim into
/// text Y" gate shared by every session detector that needs to rule out
/// incidental shared words/phrases instead of a naive
/// substring/token-membership check.
///
/// `TurnBoundaryKVStateDetector` (turn-to-turn residue) and
/// `CancellationRaceDetector` (turn-1-tail-to-turn-2 residue) both compare
/// two independently-generated strings and only care about a genuinely long
/// verbatim run — this was duplicated verbatim between the two before being
/// pulled out here (AGENTS.md's standing review question: does this diff
/// add surface that already exists at another layer?).
///
/// ## Vocabulary freeze (1.0)
///
/// This enum has zero cases — it's the caseless-enum-as-namespace idiom,
/// holding only static members, not a vocabulary any consumer switches
/// over. There is nothing to grow without becoming a different kind of
/// type (a case would make it constructible), so it's frozen by
/// construction rather than by policy decision.
public enum LongestCommonSubstring {
    /// Default minimum length (Character count) both detectors gate on.
    /// Chosen to clear common filler phrases ("the answer is ") while still
    /// catching a genuine leaked/residue run. Kept as one shared number so
    /// the two call sites can't silently drift apart.
    ///
    /// Note this bounds the *shortest detectable leak*, not a "how similar
    /// are these two strings" score: the longest common substring can never
    /// exceed the length of the smaller leaked run itself, so a real leak
    /// shorter than this threshold is invisible regardless of how long the
    /// two compared strings are. 24 was chosen empirically against the
    /// known adversarial phrases in this repo's fixtures, not derived from
    /// a model of real leak lengths.
    ///
    /// `public`, not `package`: Swift requires a default-argument
    /// expression to be at least as visible as the initializer using it,
    /// and both detectors' `public init`s default to this value. The enum
    /// itself is `public` for the same reason; `compute` below stays at
    /// module-default (`internal`) access — it's only ever called from
    /// method bodies in this module, which don't need public visibility
    /// regardless of who constructs the detector.
    public static let defaultMinChars = 24

    /// Classic O(n·m) DP on Character arrays. Inputs are small (per-turn raw
    /// strings are bounded by the configured `maxOutputTokens` → roughly
    /// 64–512 tokens), so an O(n·m) table is safe.
    static func compute(_ a: String, _ b: String) -> String? {
        let ac = Array(a)
        let bc = Array(b)
        let n = ac.count
        let m = bc.count
        if n == 0 || m == 0 { return nil }
        var prevRow = [Int](repeating: 0, count: m + 1)
        var currRow = [Int](repeating: 0, count: m + 1)
        var best = 0
        var bestEnd = 0 // exclusive end index in `ac`
        for i in 1...n {
            for j in 1...m {
                if ac[i - 1] == bc[j - 1] {
                    currRow[j] = prevRow[j - 1] + 1
                    if currRow[j] > best {
                        best = currRow[j]
                        bestEnd = i
                    }
                } else {
                    currRow[j] = 0
                }
            }
            swap(&prevRow, &currRow)
            for k in 0..<currRow.count { currRow[k] = 0 }
        }
        if best == 0 { return nil }
        let start = bestEnd - best
        return String(ac[start..<bestEnd])
    }
}
