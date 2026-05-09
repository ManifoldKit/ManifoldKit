#if Fuzz
import XCTest
@testable import ManifoldFuzz
import ManifoldInference

// MARK: - Shared fixture helper

/// Builds a `RunRecord` with sensible defaults for contract fixtures. Kept
/// private to the contract tests — `DetectorTests` has its own copy tuned for
/// sub-check-by-sub-check unit assertions. Contract fixtures exercise the
/// detector as a whole, so we keep fixture construction visually adjacent to
/// each contract type.
private enum ContractRecord {
    static func make(
        rendered: String = "",
        raw: String = "",
        thinkingRaw: String = "",
        thinkingParts: [String] = [],
        thinkingCompleteCount: Int = 0,
        phase: String = "done",
        totalMs: Double = 0,
        firstTokenMs: Double? = nil,
        error: String? = nil,
        markers: RunRecord.MarkerSnapshot? = .init(open: "<think>", close: "</think>"),
        userPrompt: String = "what is two plus two?",
        stopReason: String? = "naturalStop",
        memoryBefore: UInt64? = nil,
        memoryPeak: UInt64? = nil
    ) -> RunRecord {
        RunRecord(
            runId: "contract-fixture",
            ts: "2026-04-19T00:00:00Z",
            harness: .init(
                fuzzVersion: "0.0.0-test",
                packageGitRev: "deadbeef",
                packageGitDirty: false,
                swiftVersion: "6.1",
                osBuild: "test",
                thermalState: "nominal"
            ),
            model: .init(
                backend: "mock",
                id: "contract-model",
                url: "mem://contract",
                fileSHA256: nil,
                tokenizerHash: nil
            ),
            config: .init(
                seed: 0,
                temperature: 0.0,
                topP: 1.0,
                maxTokens: nil,
                systemPrompt: nil
            ),
            prompt: .init(
                corpusId: "contract",
                mutators: [],
                messages: [.init(role: "user", text: userPrompt)]
            ),
            events: [],
            // `rendered` is deprecated (always a duplicate of `raw` in
            // production). Mirror the two so contract fixtures that set only
            // `rendered:` still exercise detectors that now read `raw`.
            raw: raw.isEmpty ? rendered : raw,
            rendered: rendered.isEmpty ? raw : rendered,
            thinkingRaw: thinkingRaw,
            thinkingParts: thinkingParts,
            thinkingCompleteCount: thinkingCompleteCount,
            templateMarkers: markers,
            memory: .init(beforeBytes: memoryBefore, peakBytes: memoryPeak, afterBytes: nil),
            timing: .init(firstTokenMs: firstTokenMs, totalMs: totalMs, tokensPerSec: nil),
            phase: phase,
            error: error,
            stopReason: stopReason
        )
    }
}

// MARK: - Shared contract assertions

/// Pure assertion helpers invoked from each detector-specific `XCTestCase`.
/// XCTest doesn't cleanly support generic test classes, so we don't try — each
/// contract conformer gets its own concrete test case that delegates here.
enum DetectorContractAsserter {
    static func assertPositive<C: DetectorContract>(
        _ contract: C.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let findings = C.detector.inspect(C.positiveFixture)
        XCTAssertFalse(
            findings.isEmpty,
            "\(C.self) positive fixture must produce at least one finding for detector \(C.detector.id)",
            file: file,
            line: line
        )
    }

    static func assertNegative<C: DetectorContract>(
        _ contract: C.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let findings = C.detector.inspect(C.negativeFixture)
        XCTAssertTrue(
            findings.isEmpty,
            "\(C.self) negative fixture must produce no findings, got: \(findings.map { "\($0.subCheck):\($0.trigger)" })",
            file: file,
            line: line
        )
    }

    /// Boundary fixtures sit on the detector's threshold. Inspecting ten times
    /// in a row must return byte-identical findings — if a detector is
    /// non-deterministic at its boundary, the fuzzer's dedup hash will churn
    /// and the signal-to-noise ratio in the sink collapses.
    static func assertBoundary<C: DetectorContract>(
        _ contract: C.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let first = C.detector.inspect(C.boundaryFixture)
        let firstFingerprints = first.map { "\($0.subCheck)|\($0.trigger)" }.sorted()
        for i in 1..<10 {
            let next = C.detector.inspect(C.boundaryFixture)
            let nextFingerprints = next.map { "\($0.subCheck)|\($0.trigger)" }.sorted()
            XCTAssertEqual(
                firstFingerprints,
                nextFingerprints,
                "\(C.self) boundary fixture produced different findings on run \(i) vs run 0",
                file: file,
                line: line
            )
        }
    }

    static func assertAdversarial<C: DetectorContract>(
        _ contract: C.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let findings = C.detector.inspect(C.adversarialFixture)
        XCTAssertTrue(
            findings.isEmpty,
            "\(C.self) adversarial fixture must not fire, got: \(findings.map { "\($0.subCheck):\($0.trigger)" })",
            file: file,
            line: line
        )
    }
}

// MARK: - ThinkingClassificationDetector contract

enum ThinkingClassificationContract: DetectorContract {
    static var detector: any Detector { ThinkingClassificationDetector() }

    /// Positive: literal `<think>` markers leak into the rendered string —
    /// `visible-text-leak` sub-check must fire.
    static var positiveFixture: RunRecord {
        ContractRecord.make(
            rendered: "Sure! <think>let me think about this</think> the answer is 4.",
            raw: "Sure! <think>let me think about this</think> the answer is 4.",
            thinkingRaw: "let me think about this",
            thinkingParts: ["let me think about this"],
            thinkingCompleteCount: 1
        )
    }

    /// Negative: the backend stripped markers from the stream and surfaced
    /// thinking tokens via structured events. `raw` carries only the
    /// user-visible answer, `thinkingRaw` captures reasoning, and the complete
    /// event balances. Pre-#499 this fixture relied on `rendered` diverging
    /// from `raw` to avoid `visible-text-leak`; detectors now read `raw`
    /// directly, so the fixture must keep markers out of `raw` itself.
    static var negativeFixture: RunRecord {
        ContractRecord.make(
            raw: "The answer is 4.",
            thinkingRaw: "two plus two",
            thinkingParts: ["two plus two"],
            thinkingCompleteCount: 1
        )
    }

    /// Boundary: thinking content with exactly one complete event and a normal
    /// phase=done. The `unbalanced-thinking-events` check sits right at the
    /// edge of firing when `thinkingCompleteCount == 0` — we pick the
    /// just-balanced shape so the detector deterministically returns zero
    /// findings every time.
    static var boundaryFixture: RunRecord {
        ContractRecord.make(
            rendered: "ok",
            raw: "<think>quick</think>ok",
            thinkingRaw: "quick",
            thinkingParts: ["quick"],
            thinkingCompleteCount: 1,
            phase: "done",
            stopReason: "naturalStop"
        )
    }

    /// Adversarial: the output contains Markdown code-fenced pseudo-tags
    /// (`<thinking>` / `<reasoning>`) that superficially resemble reasoning
    /// markers, plus the user's prompt itself talks about template tokens.
    /// A naive "does rendered mention thinky-looking strings" heuristic would
    /// false-positive here; the detector's correct behaviour is to compare
    /// only against the configured `<think>`/`</think>` marker pair and stay
    /// silent because no literal marker appears.
    static var adversarialFixture: RunRecord {
        let fenced = """
        In most chat templates, a reasoning block is delimited by a pair of tags.
        For example, some backends use `<thinking>` and `</thinking>`; others use
        `<reasoning>` and `</reasoning>`. The exact spelling is model-specific.
        """
        return ContractRecord.make(
            rendered: fenced,
            raw: fenced,
            thinkingRaw: "",
            thinkingParts: [],
            thinkingCompleteCount: 0,
            userPrompt: "Which tags delimit reasoning blocks in chat templates?"
        )
    }
}

final class ThinkingClassificationContractTests: XCTestCase {
    func test_positive() {
        DetectorContractAsserter.assertPositive(ThinkingClassificationContract.self)
    }
    func test_negative() {
        DetectorContractAsserter.assertNegative(ThinkingClassificationContract.self)
    }
    func test_boundary() {
        DetectorContractAsserter.assertBoundary(ThinkingClassificationContract.self)
    }
    func test_adversarial() {
        DetectorContractAsserter.assertAdversarial(ThinkingClassificationContract.self)
    }
}

// MARK: - LoopingDetector contract

enum LoopingContract: DetectorContract {
    static var detector: any Detector { LoopingDetector() }

    /// Positive: `"repeat this phrase. "` x 30 — a clear 3x/2x loop on the
    /// rendered stream. `RepetitionDetector.looksLikeLooping` trips on this.
    static var positiveFixture: RunRecord {
        let looped = String(repeating: "repeat this phrase. ", count: 30)
        return ContractRecord.make(rendered: looped)
    }

    /// Negative: varied English prose with no repeated units.
    static var negativeFixture: RunRecord {
        let prose = """
        A curious fox padded through the damp undergrowth as dawn crept over \
        the ridge. Somewhere beyond the treeline, a stream muttered to itself. \
        The kettle on the kitchen stove began its slow, persuasive whistle while \
        a distant train dragged its long shadow across the valley floor.
        """
        return ContractRecord.make(rendered: prose)
    }

    /// Boundary: the shortest rendered string that still trips both the 100
    /// character floor and `looksLikeLooping`'s 50-char 2x detection. We pick
    /// a 50-character unit repeated twice (100 chars total) — the minimum
    /// size the detector accepts.
    static var boundaryFixture: RunRecord {
        let unit = "the quick brown fox jumps over the lazy dogs today" // 50 chars
        precondition(unit.count == 50, "boundary unit must stay at 50 chars")
        let looped = unit + unit
        return ContractRecord.make(rendered: looped)
    }

    /// Adversarial: a genuine Markdown bullet list where each bullet is
    /// similar-looking (starts with `- `, short verb-noun) but no two bullets
    /// are literal repeats of each other. A naive substring-compare loop
    /// detector would fire here; `looksLikeLooping` should not.
    static var adversarialFixture: RunRecord {
        let bullets = """
        Here are the steps:
        - Install the package.
        - Configure the backend.
        - Load a model.
        - Send a prompt.
        - Stream the response.
        - Render the output.
        - Cancel on user stop.
        - Persist the transcript.
        - Export the history.
        - Clean up resources.
        """
        return ContractRecord.make(rendered: bullets)
    }
}

final class LoopingContractTests: XCTestCase {
    func test_positive() {
        DetectorContractAsserter.assertPositive(LoopingContract.self)
    }
    func test_negative() {
        DetectorContractAsserter.assertNegative(LoopingContract.self)
    }
    func test_boundary() {
        DetectorContractAsserter.assertBoundary(LoopingContract.self)
    }
    func test_adversarial() {
        DetectorContractAsserter.assertAdversarial(LoopingContract.self)
    }
}

// MARK: - EmptyOutputAfterWorkDetector contract

enum EmptyOutputAfterWorkContract: DetectorContract {
    static var detector: any Detector { EmptyOutputAfterWorkDetector() }

    /// Positive: 10s elapsed, phase=done, no visible content, no thinking.
    /// The canonical "backend swallowed the stream" shape.
    static var positiveFixture: RunRecord {
        ContractRecord.make(
            rendered: "",
            raw: "",
            thinkingRaw: "",
            phase: "done",
            totalMs: 10_000
        )
    }

    /// Negative: 10s elapsed but the model produced an answer — nothing to
    /// flag. The detector also sees no `error`, phase=done, stopReason=natural.
    static var negativeFixture: RunRecord {
        ContractRecord.make(
            rendered: "Yes — here is the answer you asked for.",
            raw: "Yes — here is the answer you asked for.",
            thinkingRaw: "",
            phase: "done",
            totalMs: 10_000
        )
    }

    /// Boundary: exactly at the 8,000 ms threshold. The guard is
    /// `totalMs >= workThresholdMs`, so 8_000.0 MUST fire; determinism means
    /// ten inspections return identical findings.
    static var boundaryFixture: RunRecord {
        ContractRecord.make(
            rendered: "",
            raw: "",
            thinkingRaw: "",
            phase: "done",
            totalMs: 8_000
        )
    }

    /// Adversarial: legitimate instant-refusal case — the model replied with
    /// an empty string very fast (<1s). This is common with strict safety
    /// filters that produce `""` for disallowed prompts. A naive "empty
    /// output" detector would fire; this one gates on `>=8s elapsed` for
    /// exactly this reason.
    static var adversarialFixture: RunRecord {
        ContractRecord.make(
            rendered: "",
            raw: "",
            thinkingRaw: "",
            phase: "done",
            totalMs: 150,
            userPrompt: "please describe a forbidden topic"
        )
    }
}

final class EmptyOutputAfterWorkContractTests: XCTestCase {
    func test_positive() {
        DetectorContractAsserter.assertPositive(EmptyOutputAfterWorkContract.self)
    }
    func test_negative() {
        DetectorContractAsserter.assertNegative(EmptyOutputAfterWorkContract.self)
    }
    func test_boundary() {
        DetectorContractAsserter.assertBoundary(EmptyOutputAfterWorkContract.self)
    }
    func test_adversarial() {
        DetectorContractAsserter.assertAdversarial(EmptyOutputAfterWorkContract.self)
    }
}

// MARK: - TemplateTokenLeakDetector contract

enum TemplateTokenLeakContract: DetectorContract {
    static var detector: any Detector { TemplateTokenLeakDetector() }

    /// Positive: ChatML `<|im_start|>` delimiter leaks into raw output —
    /// the canonical Phi-4-detected-as-ChatML shape.
    static var positiveFixture: RunRecord {
        let leaked = "<|im_start|>assistant\nThe answer is 4.<|im_end|>"
        return ContractRecord.make(rendered: leaked, raw: leaked)
    }

    /// Negative: plain prose with no template fragments anywhere.
    static var negativeFixture: RunRecord {
        let prose = "The answer is four. Two and two make four in standard arithmetic."
        return ContractRecord.make(rendered: prose, raw: prose)
    }

    /// Boundary: a single delimiter (`[INST]`) at the very start of the
    /// raw stream. Tests the regex-anchor behaviour — any substring match
    /// must fire, regardless of position. Ten inspections must yield the
    /// same finding.
    static var boundaryFixture: RunRecord {
        let leak = "[INST] You are a helpful assistant. [/INST] ok"
        return ContractRecord.make(rendered: leak, raw: leak)
    }

    /// Adversarial: a Markdown code block quoting the literal `<|im_start|>`
    /// token. This is legitimate documentation prose — a naive substring
    /// scanner would false-positive. The detector strips fenced and
    /// inline-code spans before scanning.
    static var adversarialFixture: RunRecord {
        let doc = """
        ChatML uses the `<|im_start|>` and `<|im_end|>` tokens to delimit
        turns. Here is an example:

        ```
        <|im_start|>user
        hello
        <|im_end|>
        ```

        Most tokenizers consume these silently.
        """
        return ContractRecord.make(
            rendered: doc,
            raw: doc,
            userPrompt: "explain chatml delimiters"
        )
    }
}

final class TemplateTokenLeakContractTests: XCTestCase {
    func test_positive() {
        DetectorContractAsserter.assertPositive(TemplateTokenLeakContract.self)
    }
    func test_negative() {
        DetectorContractAsserter.assertNegative(TemplateTokenLeakContract.self)
    }
    func test_boundary() {
        DetectorContractAsserter.assertBoundary(TemplateTokenLeakContract.self)
    }
    func test_adversarial() {
        DetectorContractAsserter.assertAdversarial(TemplateTokenLeakContract.self)
    }
}

// MARK: - MemoryGrowthDetector contract

enum MemoryGrowthContract: DetectorContract {
    static var detector: any Detector { MemoryGrowthDetector() }

    /// Positive: backend surfaced a memory-related error. The growth-budget
    /// branch is disabled today; the error-string path is what fires.
    static var positiveFixture: RunRecord {
        ContractRecord.make(
            rendered: "",
            raw: "",
            phase: "error",
            error: "Metal allocation failed: out of memory",
            stopReason: "error"
        )
    }

    /// Negative: normal completion, no error.
    static var negativeFixture: RunRecord {
        ContractRecord.make(
            rendered: "The answer is 4.",
            raw: "The answer is 4.",
            totalMs: 500
        )
    }

    /// Boundary: an error whose text contains a memory needle in its exact
    /// lowercased form. Ten inspections must produce the same fingerprint.
    static var boundaryFixture: RunRecord {
        ContractRecord.make(
            rendered: "",
            raw: "",
            phase: "error",
            error: "jetsam killed process",
            stopReason: "error"
        )
    }

    /// Adversarial: a non-memory error that happens to mention bytes — the
    /// detector must NOT fire on token-count or byte-limit discussions.
    static var adversarialFixture: RunRecord {
        ContractRecord.make(
            rendered: "",
            raw: "",
            phase: "error",
            error: "invalid UTF-8 byte sequence at offset 42",
            stopReason: "error"
        )
    }
}

final class MemoryGrowthContractTests: XCTestCase {
    func test_positive() {
        DetectorContractAsserter.assertPositive(MemoryGrowthContract.self)
    }
    func test_negative() {
        DetectorContractAsserter.assertNegative(MemoryGrowthContract.self)
    }
    func test_boundary() {
        DetectorContractAsserter.assertBoundary(MemoryGrowthContract.self)
    }
    func test_adversarial() {
        DetectorContractAsserter.assertAdversarial(MemoryGrowthContract.self)
    }
}

// MARK: - KVCollisionDetector contract

enum KVCollisionContract: DetectorContract {
    static var detector: any Detector { KVCollisionDetector() }

    /// Positive: the canonical llama.cpp post-stop decode failure — error
    /// text matches AND the record records a stop.
    static var positiveFixture: RunRecord {
        ContractRecord.make(
            rendered: "",
            raw: "",
            phase: "stopped",
            error: "Decode failed during generation",
            stopReason: "userStop"
        )
    }

    /// Negative: ordinary successful completion — no error at all.
    static var negativeFixture: RunRecord {
        ContractRecord.make(
            rendered: "The answer is 4.",
            raw: "The answer is 4.",
            totalMs: 500
        )
    }

    /// Boundary: the error text matches exactly AND stopReason is `error`
    /// (not `userStop`). The detector accepts either indicator, so this
    /// must fire; determinism means ten inspections produce the same hit.
    static var boundaryFixture: RunRecord {
        ContractRecord.make(
            rendered: "",
            raw: "",
            phase: "error",
            error: "Decode failed during generation",
            stopReason: "error"
        )
    }

    /// Adversarial: the model's output itself *renders* the phrase "decode
    /// failed during generation" as natural-language text (e.g., an agent
    /// explaining errors to a user). The `error` field stays nil, so the
    /// detector must not fire.
    static var adversarialFixture: RunRecord {
        let echo = "A common llama.cpp error reads: \"Decode failed during generation\". It typically indicates a KV-cache mismatch."
        return ContractRecord.make(
            rendered: echo,
            raw: echo,
            phase: "done",
            stopReason: "naturalStop"
        )
    }
}

final class KVCollisionContractTests: XCTestCase {
    func test_positive() {
        DetectorContractAsserter.assertPositive(KVCollisionContract.self)
    }
    func test_negative() {
        DetectorContractAsserter.assertNegative(KVCollisionContract.self)
    }
    func test_boundary() {
        DetectorContractAsserter.assertBoundary(KVCollisionContract.self)
    }
    func test_adversarial() {
        DetectorContractAsserter.assertAdversarial(KVCollisionContract.self)
    }
}

// MARK: - EmptyVisibleAfterThinkDetector contract

enum EmptyVisibleAfterThinkContract: DetectorContract {
    static var detector: any Detector { EmptyVisibleAfterThinkDetector() }

    /// Positive: model thought, emitted tokens, rendered is whitespace —
    /// the classic `hasVisibleContent` bug shape.
    static var positiveFixture: RunRecord {
        ContractRecord.make(
            rendered: "   \n   ",
            raw: "<think>reasoning here</think>",
            thinkingRaw: "reasoning here",
            thinkingParts: ["reasoning here"],
            thinkingCompleteCount: 1,
            phase: "done"
        )
    }

    /// Negative: model thought AND produced visible output — rendered is
    /// non-empty, so nothing to flag.
    static var negativeFixture: RunRecord {
        ContractRecord.make(
            rendered: "The answer is 4.",
            raw: "<think>compute</think>The answer is 4.",
            thinkingRaw: "compute",
            thinkingParts: ["compute"],
            thinkingCompleteCount: 1,
            phase: "done"
        )
    }

    /// Boundary: rendered is exactly one whitespace character with raw and
    /// thinking both non-empty. The trim check MUST flag this; ten
    /// inspections return the same finding.
    static var boundaryFixture: RunRecord {
        ContractRecord.make(
            rendered: " ",
            raw: "<think>x</think>",
            thinkingRaw: "x",
            thinkingParts: ["x"],
            thinkingCompleteCount: 1,
            phase: "done"
        )
    }

    /// Adversarial: empty rendering but empty thinking too — this is the
    /// `EmptyOutputAfterWorkDetector`'s territory, not ours. The detector
    /// must stay silent because `thinkingRaw` is empty.
    static var adversarialFixture: RunRecord {
        ContractRecord.make(
            rendered: "",
            raw: "",
            thinkingRaw: "",
            phase: "done",
            totalMs: 10_000
        )
    }
}

final class EmptyVisibleAfterThinkContractTests: XCTestCase {
    func test_positive() {
        DetectorContractAsserter.assertPositive(EmptyVisibleAfterThinkContract.self)
    }
    func test_negative() {
        DetectorContractAsserter.assertNegative(EmptyVisibleAfterThinkContract.self)
    }
    func test_boundary() {
        DetectorContractAsserter.assertBoundary(EmptyVisibleAfterThinkContract.self)
    }
    func test_adversarial() {
        DetectorContractAsserter.assertAdversarial(EmptyVisibleAfterThinkContract.self)
    }
}

// MARK: - RaceStallDetector contract

enum RaceStallContract: DetectorContract {
    static var detector: any Detector { RaceStallDetector() }

    /// Positive: the harness recorded `phase = "stalled"` — unambiguous
    /// stream-stall signal.
    static var positiveFixture: RunRecord {
        ContractRecord.make(
            rendered: "",
            raw: "",
            phase: "stalled",
            totalMs: 120_000,
            stopReason: "unknown"
        )
    }

    /// Negative: fast first token, normal completion — nothing to flag.
    static var negativeFixture: RunRecord {
        ContractRecord.make(
            rendered: "The answer is 4.",
            raw: "The answer is 4.",
            phase: "done",
            totalMs: 800,
            firstTokenMs: 120
        )
    }

    /// Boundary: `firstTokenMs == 60_000` exactly. The detector's tie-break
    /// rule is strict-greater — 60_000 flat is NOT a stall — so ten
    /// inspections must return zero findings. The fixture also has
    /// phase=done, so the stalled-phase branch stays quiet.
    static var boundaryFixture: RunRecord {
        ContractRecord.make(
            rendered: "The answer is 4.",
            raw: "The answer is 4.",
            phase: "done",
            totalMs: 65_000,
            firstTokenMs: 60_000
        )
    }

    /// Adversarial: a genuinely slow cold-start (45s to first token). The
    /// detector must not fire — legitimate model warm-up is slow but not
    /// stalled.
    static var adversarialFixture: RunRecord {
        ContractRecord.make(
            rendered: "The answer is 4.",
            raw: "The answer is 4.",
            phase: "done",
            totalMs: 46_000,
            firstTokenMs: 45_000
        )
    }
}

final class RaceStallContractTests: XCTestCase {
    func test_positive() {
        DetectorContractAsserter.assertPositive(RaceStallContract.self)
    }
    func test_negative() {
        DetectorContractAsserter.assertNegative(RaceStallContract.self)
    }
    func test_boundary() {
        DetectorContractAsserter.assertBoundary(RaceStallContract.self)
    }
    func test_adversarial() {
        DetectorContractAsserter.assertAdversarial(RaceStallContract.self)
    }
}

// MARK: - ContextExhaustionSilentDetector contract

enum ContextExhaustionSilentContract: DetectorContract {
    static var detector: any Detector { ContextExhaustionSilentDetector() }

    /// Positive: the canonical `InferenceError.contextExhausted` error
    /// description. Today the detector has no prompt-token estimate to
    /// gate on, so any occurrence of this error fires.
    static var positiveFixture: RunRecord {
        ContractRecord.make(
            rendered: "",
            raw: "",
            phase: "error",
            error: "Prompt (120 tokens) plus requested output (256 tokens) exceeds context window (8192 tokens).",
            stopReason: "error"
        )
    }

    /// Negative: normal successful completion, no error.
    static var negativeFixture: RunRecord {
        ContractRecord.make(
            rendered: "The answer is 4.",
            raw: "The answer is 4.",
            totalMs: 500
        )
    }

    /// Boundary: the error message matches exactly, with no trailing text.
    /// Ten inspections must yield the same finding.
    static var boundaryFixture: RunRecord {
        ContractRecord.make(
            rendered: "",
            raw: "",
            phase: "error",
            error: "…exceeds context window…",
            stopReason: "error"
        )
    }

    /// Adversarial: a different error that mentions "context" but not the
    /// canonical phrase. Must not fire — we match only the exhaustion
    /// description.
    static var adversarialFixture: RunRecord {
        ContractRecord.make(
            rendered: "",
            raw: "",
            phase: "error",
            error: "Failed to initialize context with size 8192",
            stopReason: "error"
        )
    }
}

final class ContextExhaustionSilentContractTests: XCTestCase {
    func test_positive() {
        DetectorContractAsserter.assertPositive(ContextExhaustionSilentContract.self)
    }
    func test_negative() {
        DetectorContractAsserter.assertNegative(ContextExhaustionSilentContract.self)
    }
    func test_boundary() {
        DetectorContractAsserter.assertBoundary(ContextExhaustionSilentContract.self)
    }
    func test_adversarial() {
        DetectorContractAsserter.assertAdversarial(ContextExhaustionSilentContract.self)
    }
}

// MARK: - TimeoutDetector contract

enum TimeoutContract: DetectorContract {
    static var detector: any Detector { TimeoutDetector() }

    /// Positive: totalMs well over the 60s fallback.
    static var positiveFixture: RunRecord {
        ContractRecord.make(
            rendered: "eventually",
            raw: "eventually",
            phase: "done",
            totalMs: 180_000
        )
    }

    /// Negative: a fast run, nowhere near the threshold.
    static var negativeFixture: RunRecord {
        ContractRecord.make(
            rendered: "ok",
            raw: "ok",
            phase: "done",
            totalMs: 500
        )
    }

    /// Boundary: totalMs == 60_000 exactly. The detector's comparison is
    /// strict-greater, so this must NOT fire and must return the same
    /// (empty) findings across ten inspections.
    static var boundaryFixture: RunRecord {
        ContractRecord.make(
            rendered: "ok",
            raw: "ok",
            phase: "done",
            totalMs: 60_000
        )
    }

    /// Adversarial: a long legitimate generation (55s) — still under the
    /// crude fallback threshold. The real windowed-median design would be
    /// needed to distinguish outliers from slow-but-valid runs; until
    /// then, the detector stays silent.
    static var adversarialFixture: RunRecord {
        ContractRecord.make(
            rendered: "a long, thoughtful response",
            raw: "a long, thoughtful response",
            phase: "done",
            totalMs: 55_000
        )
    }
}

final class TimeoutContractTests: XCTestCase {
    func test_positive() {
        DetectorContractAsserter.assertPositive(TimeoutContract.self)
    }
    func test_negative() {
        DetectorContractAsserter.assertNegative(TimeoutContract.self)
    }
    func test_boundary() {
        DetectorContractAsserter.assertBoundary(TimeoutContract.self)
    }
    func test_adversarial() {
        DetectorContractAsserter.assertAdversarial(TimeoutContract.self)
    }
}
#endif
