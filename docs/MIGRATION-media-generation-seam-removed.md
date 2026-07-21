# Migration: generic `MediaGeneration` seam + deprecated `MessagePart` media shims removed

**Audience:** consumer
**Status:** living

**This is a breaking change.** ManifoldKit no longer ships the generic
`MediaGeneration<Output>` / `MediaGenerationEvent<Preview>` abstraction, its
three modality typealiases, or the two deprecated `MessagePart` media
accessors.

## Why

`MediaGeneration<Output>` and `MediaGenerationEvent<Preview>` shipped in #1839
(P4a) as the target for a modality collapse that was never wired: no type in
ManifoldKit, the Example apps, or any consumer/companion repo ever conformed to
or emitted either. Per principle 10 ("shipped means live"), a public
abstraction with no producer or consumer is not coverage of a real path — and
Swift protocols cannot be generic, so it was never a viable collapse target in
the first place. The live per-modality pipelines
(`ImageGenerationConfig`/`ImageGenerationEvent`, the video and audio siblings)
and the persisted/render layer (`GeneratedMediaPayload` + `MediaKind`) never
used it. Rather than freeze a decorative generic into the 1.0 stability
promise, it is deleted (issue #1903, W1).

The two `MessagePart` accessors were `@available(*, deprecated)` shims left over
from the P4b `.generatedImage`/`.generatedVideo` → `.generatedMedia` collapse.
Pre-1.0 policy is delete, not deprecate (AGENTS.md Principle 9); both had zero
in-repo callers.

**Not affected:** the entire video-generation vertical (backend protocol,
service, runtime, tool source, progress/render UI) ships unchanged — it is
planned ahead-of-backend per `docs/UI-REFRESH-2026.md` and tracked by #2349.
The concrete per-modality config/event types, `GeneratedMediaPayload`,
`MediaKind`, and `VideoMessagePayload` are all unchanged.

## What was removed

| Removed | Where |
|---------|-------|
| `MediaGeneration<Output>` (enum + `.Config`) | `ManifoldModelCatalog` |
| `MediaGenerationEvent<Preview>` (enum) | `ManifoldModelCatalog` |
| `ImageGeneration` / `VideoGeneration` / `AudioGeneration` (typealiases) | `ManifoldModelCatalog` |
| `MessagePart.generatedImageContent` (deprecated var) | `ManifoldContract` |
| `MessagePart.generatedVideoContent` (deprecated var) | `ManifoldContract` |

## How to migrate

- **`MediaGeneration` / `MediaGenerationEvent` / the typealiases:** no
  replacement — nothing consumed them. Use the concrete per-modality types
  directly (`ImageGenerationConfig`/`ImageGenerationEvent`, etc.).
- **`part.generatedImageContent`:** use
  `part.generatedMediaContent` and check `.kind == .image`; reconstruct the
  legacy payload via `GeneratedMediaPayload.asImagePayload` if you still need
  the `ImageMessagePayload` shape.
- **`part.generatedVideoContent`:** same pattern with `.kind == .video` and
  `GeneratedMediaPayload.asVideoPayload`.
