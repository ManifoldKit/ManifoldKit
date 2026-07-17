# SourceKit stale module diagnostics

**Audience:** consumer
**Status:** living

Issue [#1109](https://github.com/ManifoldKit/ManifoldKit/issues/1109) tracks an
editor-only `No such module 'ManifoldPersistenceSwiftData'` diagnostic observed
after switching SwiftPM trait sets while `swift build` succeeds.

## Current working model

The package manifest always defines the `ManifoldPersistenceSwiftData` target.
When the diagnostic is stale, the failure is therefore outside the package graph:
SourceKit-LSP/Xcode is reading cached build settings or index-store state from a
previous trait configuration. Restarting SourceKit-LSP or cleaning Xcode's build
folder forces the editor to request fresh SwiftPM build settings.

## Non-destructive diagnostic script

Run a dry run first:

```bash
scripts/sourcekit-stale-module-diagnostics.sh
```

To exercise the suspected trait-switch path without deleting the normal
`.build` directory:

```bash
scripts/sourcekit-stale-module-diagnostics.sh --run
```

The script reuses an isolated scratch path,
`.build/sourcekit-1109-diagnostics`, across:

1. `swift build --target ManifoldKit`
2. `swift build --target ManifoldKit` (repeated, to mirror a settings change)
3. `sourcekit-lsp debug index --project .`

It then scans the SourceKit-LSP output for
`No such module 'ManifoldPersistenceSwiftData'`.

If Xcode reproduces the stale diagnostic but the headless script does not, that
points at the long-lived Xcode/SourceKit process or editor index-store cache
rather than SwiftPM target resolution.

## Checklist for a useful #1109 report

- Exact Xcode and Swift versions (`swift --version`).
- Whether the stale diagnostic appears in Xcode, VS Code SourceKit-LSP, or both.
- The trait-set transition immediately before the diagnostic appeared.
- Whether `swift build --target ManifoldKit` succeeds at the same commit.
- Whether restarting SourceKit-LSP clears the diagnostic.
- Whether `scripts/sourcekit-stale-module-diagnostics.sh --run` reproduces it.
