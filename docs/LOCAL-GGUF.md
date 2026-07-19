# Local GGUF storage and discovery

**Audience:** consumer
**Status:** living

How ManifoldKit finds local `.gguf` files on disk, where to put them, and what
goes wrong when discovery or load fails. Closes [#1468](https://github.com/ManifoldKit/ManifoldKit/issues/1468).

## Where ModelManagementSheet looks

`ModelStorageService.discoverModels()` — backing the `ModelManagementSheet`
"Storage" + "Select" tabs — scans **two** directories, in this order:

1. **App-scoped (primary):** `<Application Support>/<ManifoldConfiguration.shared.bundleIdentifier>/Models`
   This is where downloads land, where drag-and-drop imports go, and where the
   sheet writes when a user installs a model from the Download tab. It is
   scoped to your app's bundle identifier so two ManifoldKit-based apps on the
   same machine cannot see each other's downloads.

2. **User Documents (fallback):** `~/Documents/Models`
   This is the path the CLI quickstart documents and the path most users
   expect when they manually drop a `.gguf` they downloaded with a browser.
   When the directory exists, every `.gguf` (or MLX model directory) inside it
   is appended to the discovered list after the app-scoped scan. App-scoped
   entries always come first.

You don't need to choose between them — put models in either and the sheet
will surface both. The public `ModelStorageService` default **includes** the
Documents fallback. The `init(includeUserDocumentsFallback:)` overload is
`package` access only — host apps in external modules cannot call it; opting
out of the Documents scan is an in-package concern, not a consumer API.

## Actionable load errors

The throwing factory `ModelInfo.load(ggufURL:)` returns a typed
`ModelDiscoveryError` when a load fails:

| Case | Meaning | UI message |
|------|---------|------------|
| `.fileMissing(path:)` | The file is gone or was never written. | "Model file not found at …" |
| `.notReadable(path:reason:)` | The file is on disk but the process cannot open it. | "Model file at … exists but cannot be read — try importing the file into the app's models directory." |
| `.notGGUF(path:)` | The first four bytes are not the GGUF magic (`0x47 0x47 0x55 0x46`). | "File at … is not a valid GGUF — the file may be a renamed non-GGUF, a truncated download, or a placeholder stub." |
| `.metadataReadFailed(path:underlying:)` | Header magic is valid but the metadata section did not parse. | "Could not read GGUF header metadata: <reason>." |
| `.unexpectedFileKind(path:detail:)` | The path resolved to a directory or another non-file kind. | "Unexpected file kind at …" |

`ModelRegistry.refresh()` collects these into `lastDiscoveryErrors` so a
SwiftUI sheet can render a banner with the actionable text. The historical
"low-level GGUF metadata read failure" log line from before #1468 was the
result of swallowed errors; the new typed surface fixes that.

## Why the GGUF metadata reader sometimes failed silently

Before #1468, `GGUFMetadataReader.skipValue` rejected any GGUF array
containing more than 65 536 elements. Every modern open-weight model ships a
tokenizer vocab well above that ceiling:

- Llama 3: ~128 256 tokens
- Gemma 2: ~256 000 tokens
- Qwen 2/3: ~152 000 tokens

The metadata parse therefore threw `GGUFReaderError.readError("Array element
count … exceeds safety limit (65536)")`, the warning was logged at
`Log.inference.warning` level, and the `ModelInfo` was built without a
detected prompt template or context length. Backends then often loaded with a
wrong template and produced garbled output. The cap is now 1 000 000 — high
enough to accommodate every published GGUF tokenizer — and the regression is
guarded by `test_readMetadata_largeTokenizerArray_parses`.

## CLI vs SwiftUI: one storage contract

| Walkthrough | Default storage | Discoverable via |
|-------------|-----------------|------------------|
| `docs/QUICKSTART-CLI.md` | `~/Documents/Models` (user-managed) | Direct `ModelInfo.load(ggufURL:)` |
| `docs/QUICKSTART.md` (SwiftUI) | App-scoped `<App Support>/<bundle>/Models` | `ModelManagementSheet` (both directories) |

A user who follows the CLI quickstart and then opens a SwiftUI host built
with `ModelManagementSheet` will see their `~/Documents/Models` GGUFs in the
sheet without any extra setup. A user who installs a model via the SwiftUI
Download tab will see it in the same sheet; CLI hosts that read
`~/Documents/Models` directly will not see those app-scoped installs.

> TODO: once PR #1471 lands `docs/SWIFTUI-MULTI-SESSION.md`, fold this page's
> first two sections into a "Local GGUF" subsection there and link the rest
> from the quickstart.
