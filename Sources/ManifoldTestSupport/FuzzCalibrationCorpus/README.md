# Fuzz Calibration Corpus

Labeled fixture records used by `CalibrationTests` to verify per-detector accuracy.

## Files

| File | Records | Purpose |
|------|---------|---------|
| `good.json` | ~210 | Known-good `RunRecord` captures — no single-turn detector should fire |
| `bad.json`  | ~55  | Known-bad captures labeled `{detectorId, note, record}` — each detector must fire on its labeled records |

## Accuracy gates

| Gate | Threshold | Meaning |
|------|-----------|---------|
| False-positive rate | < 2 % | Detector fires on fewer than 2 in 100 good records |
| True-positive rate  | ≥ 80 % | Detector fires on at least 8 in 10 of its labeled bad records |

A detector that passes both gates is eligible for promotion from `.flaky` to `.confirmed` severity.

## Record format

**`good.json`** — plain array of `RunRecord` objects:
```json
[
  { "runId": "g-a-001", ... }
]
```

**`bad.json`** — array of labeled wrappers:
```json
[
  {
    "detectorId": "looping",
    "note": "raw-looping — 3x 65-char unit repeated at tail",
    "record": { "runId": "b-loop-001", ... }
  }
]
```

`schemaVersion` is optional in stored records — `RunRecord` decodes a missing field as `1`. Omit it from new records unless you explicitly need to pin a future version.

## Adding records

1. Add entries to the appropriate file. Good records use `g-<group>-NNN` (group letter from the corpus-group table below). Bad records use a short detector slug + bug-class group, e.g. `b-tc-vl-001` for `thinking-classification` visible-leak, `b-loop-001` for `looping`. Follow the existing pattern in `bad.json` for that detector.
2. Run `swift test --filter ManifoldFuzzTests.CalibrationTests --disable-default-traits` — the FP/TP gate will catch mislabeled records immediately.
3. If a new detector is added to `DetectorRegistry.all`, the `test_badCorpusCoverage_allDetectorsCovered` test will fail until at least one bad record is added for that detector.

## Corpus groups (good records)

| Group | IDs | Description |
|-------|-----|-------------|
| A | `g-a-*` | Factual Q&A — short prose answers |
| B | `g-b-*` | Code-heavy markdown with fenced blocks |
| C | `g-c-*` | Template tokens present only in prompt or code fences |
| D | `g-d-*` | Correctly classified thinking responses |
| E | `g-e-*` | Thinking truncated by `maxTokens` — raw is empty |
| F | `g-f-*` | Fast empty responses (totalMs < 8 s, prompt non-empty) |
| G | `g-g-*` | Empty-prompt responses (EmptyOutputAfterWork guard) |
| H | `g-h-*` | Unicode-heavy prose |
| I | `g-i-*` | Extended markdown with nested headings and bullet lists |
| J | `g-j-*` | Template tokens isolated inside triple-backtick fences |
| K | `g-k-*` | Multi-turn conversations with assistant history |
| L | `g-l-*` | Partial / stopped responses |
