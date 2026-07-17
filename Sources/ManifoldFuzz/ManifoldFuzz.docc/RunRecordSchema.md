# Run Record Schema

The on-disk contract for `record.json` written by the ManifoldFuzz harness.

## Overview

Every fuzz run that produces a finding is serialised as a ``RunRecord`` to
`tmp/fuzz/findings/<detector>/<hash>/record.json`. These records are the
de-facto API between the harness and every external tool that consumes its
output — `--replay`, `--shrink`, triage UIs, and CI dashboards all decode the
same JSON. A change to this shape is a change to a public protocol even though
there is no Swift API boundary.

To keep the contract honest, ``RunRecord`` carries an explicit
``RunRecord/schemaVersion`` (current value: ``RunRecord/currentSchema``).
Records that omit the field are treated as version `1` so existing on-disk
captures decode unchanged. The ``RunRecord/validate(schemaVersion:)`` entry
point throws on records written by a future, unknown version and emits a log
warning when migrating an older version — consumers (starting with `--replay`
in #490) call it before acting on a decoded record.

## Field reference

| Field | Type | Description / invariant |
| --- | --- | --- |
| `schemaVersion` | `Int` | Version of the on-disk shape this record was written with. Legacy records decode as `1`. |
| `runId` | `String` | UUID for the single generation run. |
| `ts` | `String` | ISO-8601 timestamp in UTC of run start. |
| `harness` | `HarnessSnapshot` | `fuzzVersion`, git rev, swift/os build, thermal state at run time. |
| `model` | `ModelSnapshot` | Backend name, model id, URL, optional `fileSHA256` and `tokenizerHash`. |
| `config` | `ConfigSnapshot` | `seed`, `temperature`, `topP`, optional `maxTokens`, optional `systemPrompt`. |
| `prompt` | `PromptSnapshot` | Corpus id, applied mutator list, message turns (role + text). |
| `events` | `[EventSnapshot]` | Ordered stream of `{t, kind, v?}` observations. `t` is seconds since run start. |
| `raw` | `String` | Raw backend output with think/tool markers intact. |
| `rendered` | `String` | User-visible string produced by running `raw` through the same markdown / code-fence transform that `ManifoldUI`'s `AssistantMarkdownView` applies (see `MarkdownRendering.renderToVisibleString`). Diverges from `raw` in realistic ways: closing fences disappear, emphasis markers collapse, link targets are hidden. Records written before #543 had `rendered == raw`. |
| `thinkingRaw` | `String` | Concatenation of all thinking-channel text. |
| `thinkingParts` | `[String]` | Thinking deltas as a list, in stream order. |
| `thinkingCompleteCount` | `Int` | Number of `thinkingCompleted` events observed. |
| `templateMarkers` | `MarkerSnapshot?` | The `{open, close}` reasoning markers the backend/template advertises; `nil` if none. |
| `memory` | `MemorySnapshot` | `beforeBytes`, `peakBytes`, `afterBytes` — all optional; nil when the backend/platform can't measure. |
| `timing` | `TimingSnapshot` | `firstTokenMs?`, `totalMs`, `tokensPerSec?`. `totalMs` is always present; TPS is derived only when both token counts and first-token time are known. |
| `phase` | `String` | One of `started`, `streaming`, `done`, `failed`. Invariant: `phase == "failed"` ⇒ `error != nil`. |
| `error` | `String?` | Human-readable error message when `phase == "failed"`; otherwise `nil`. |
| `stopReason` | `String?` | Coarse stop classification: `naturalStop`, `maxTokens`, `userStop`, `error`, `timeout`, or `unknown`. Detectors gate on this to avoid false-positive findings caused by token-cap truncation. |
| `truncated` | `Bool` | `true` when `EventRecorder` dropped some of `raw`/`thinkingRaw`/`events` to stay under its buffering cap (a generation that never naturally stopped). Absent (legacy) records decode as `false`. Added without a `schemaVersion` bump — same additive `decodeIfPresent ?? <default>` precedent as `toolCalls`/`toolResults`/`toolDefinitions`, which also shipped without bumping `currentSchema` despite step 1 below. |

## Evolving the schema

Changes to the on-disk shape go through a three-step migration. The goal is
that **every older record ever written remains decodable** and that a loader
from an older build refuses (loudly) to consume a newer record rather than
silently misinterpreting it.

1. Bump ``RunRecord/currentSchema`` to the new integer and add the new/renamed
   field(s) to the Swift struct.
2. Extend the custom `init(from:)` with `decodeIfPresent ?? <legacy-default>`
   for each added field so v1 records keep decoding cleanly. For renamed
   fields, fall back to the old key when the new key is absent.
3. Add a round-trip test covering the old version's JSON in
   `RunRecordRoundTripTests` so the migration stays green forever.

Removing a field requires the same three steps *plus* a deprecation cycle:
leave the field in the struct for one minor release with a deprecation note,
then remove it in the following minor release.

## Topics

### Core types

- ``RunRecord``
- ``RunRecord/currentSchema``
- ``RunRecord/schemaVersion``
- ``RunRecord/validate(schemaVersion:)``
- ``RunRecord/SchemaError``
