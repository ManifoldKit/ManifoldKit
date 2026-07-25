# Migration index

**Audience:** consumer
**Status:** living

Every retired or breaking-changed API in ManifoldKit gets a migration note
(Principle 9). This is the complete list, newest first, with **the release that
shipped the note** — start here when a version bump breaks your build.

For every row but one, the note shipped in the same commit as the change it
documents, so that release is also when the API changed. The wake-word row is
the exception and says so.

Find your error message with a repo search across this directory; most notes
are indexed by the literal compiler diagnostic you'll hit.

| Release | Migration note | What changed |
|---------|----------------|--------------|
| next | [`MIGRATION-llama-vision-probe.md`](MIGRATION-llama-vision-probe.md) | `BackendVisionCapability.llamaSupportsImageInput` Bool property → probed function `(projectorStaged:engineSupportsImageEmbedding:)` (#2381 / #2393). |
| v0.74.0 | [`MIGRATION-wake-word-removed.md`](MIGRATION-wake-word-removed.md)¹ | `ManifoldVoice` wake-word detection (`AppleWakeWordDetector`, `WakeWordDetector`, `WakeWordDetection`, `WakeWordToast`) removed — no core replacement. |
| v0.74.0 | [`MIGRATION-inert-surface-sweep-2026-07-22.md`](MIGRATION-inert-surface-sweep-2026-07-22.md) | Inert public surface removed (read paths with no writer). |
| v0.74.0 | [`MIGRATION-media-generation-seam-removed.md`](MIGRATION-media-generation-seam-removed.md) | Generic `MediaGeneration` seam + deprecated `MessagePart` media shims removed. |
| v0.74.0 | [`MIGRATION-enum-growth-sweep-2208.md`](MIGRATION-enum-growth-sweep-2208.md) | Cloud provider vocabulary struct-ified; 8 wire enums frozen (#2208). |
| v0.74.0 | [`MIGRATION-compression-policy-system-prompt.md`](MIGRATION-compression-policy-system-prompt.md) | `systemPrompt` added to `CompressionPolicy` / `PreTurnCompressionPolicy` (#1957, #2288). |
| v0.73.0 | [`MIGRATION-ui-refresh.md`](MIGRATION-ui-refresh.md) | The 2026 UI refresh — new default appearance; `.classic` restores the old look. |
| v0.73.0 | [`MIGRATION-history-through-hints.md`](MIGRATION-history-through-hints.md) | Conversation history moves onto `GenerationRuntimeHints.history` (#2312). |
| v0.72.0 | [`MIGRATION-background-task-scheduler-removed.md`](MIGRATION-background-task-scheduler-removed.md) | `BackgroundTaskScheduler` seam removed. |
| v0.71.0 | [`MIGRATION-api-demotions-0.71.md`](MIGRATION-api-demotions-0.71.md) | Phase A `public` → `package` demotions. |
| v0.59.0 | [`MIGRATION-cost-estimation-removed.md`](MIGRATION-cost-estimation-removed.md) | Built-in inference cost estimation removed. |
| v0.51.0 | [`MIGRATION-shims-retired.md`](MIGRATION-shims-retired.md) | Deprecated `@_exported` shims retired (P7) — `ManifoldBackends`, `DefaultBackends`, `ManifoldCloud` gone. **Read this before trusting any 0.48 "still compiles" note.** |
| v0.48.0 | [`MIGRATION-0.48.md`](MIGRATION-0.48.md) | "The Packaging Release" — traits retired, MLX / llama.cpp moved to companion packages. |

¹ The API was removed in **v0.59.0**; the migration note was written
retroactively in v0.74.0 after `DocClaimsAuditTest` caught
`docs/QUICKSTART-VOICE.md` still advertising the deleted type. The release
column above records when the *note* shipped — see the note itself for the
removal version.

## Adding a note

A retired API ships its migration note in the same PR as the removal, and adds
a row here. `DocClaimsAuditTest.auditIndexCoverage` fails if a `docs/*.md` is
reachable from no other Markdown file, so an unlisted note is a per-PR test
failure rather than something a consumer discovers on upgrade — but the audit
only proves the file is *mentioned* somewhere, not that this table is complete
or its versions correct. Keep it honest by hand.
