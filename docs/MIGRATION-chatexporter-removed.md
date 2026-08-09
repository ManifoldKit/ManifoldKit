# Migration: `ChatExporter` removed

**Audience:** consumer
**Status:** living

**This is a breaking change.** `ChatExporter` and its error type
`ChatExporterError` (`Sources/ManifoldUI/Utilities/ChatExporter.swift`) are
removed as of this release (M1, issue #2453). Both had zero call sites
anywhere in this repo, `Tests/`, `Example/`, the companion packages
(manifold-mlx, manifold-llama, manifold-eval), or any of the surveyed
consumer apps — and the type's own doc comment already pointed readers at
its replacement.

## Why it was removed

`ChatExporter` was a lightweight, standalone string/file exporter. It was
superseded before this release by `ExportButton` (a ready-made SwiftUI
control) and `ConversationExporter` (`Sources/ManifoldRuntime`, the
lower-level export service both `ExportButton` and `ChatExportService` sit
on) — `ChatExporter`'s own doc comment said as much ("For richer export
needs... prefer `ExportButton` or call `ConversationExporter` directly").
With zero adopters and a documented superseding path already shipped, the
AGENTS.md § Public API design policy default (pre-1.0: delete, don't
deprecate) applied.

## What was removed

| Symbol | Kind | Was in |
|---|---|---|
| `ChatExporter` | `public enum` | `Sources/ManifoldUI/Utilities/ChatExporter.swift` (deleted) |
| `ChatExporter.string(title:messages:format:)` | `public static func` | same file |
| `ChatExporter.exportFile(title:messages:format:)` | `public static func` | same file |
| `ChatExporterError` | `public enum` | same file |

## Symptoms

```
cannot find type 'ChatExporter' in scope
cannot find type 'ChatExporterError' in scope
```

## What to do instead

Use `ExportButton` for a drop-in SwiftUI share control, or call
`ConversationExporter` (`Sources/ManifoldRuntime`) directly for the
underlying string/file serialisation — both remain public and cover
everything `ChatExporter` did, per its own prior doc comment.
