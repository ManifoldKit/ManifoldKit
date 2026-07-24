# ManifoldKit Examples

## Advanced (Full Reference App)

The full-featured demo showing all ManifoldKit capabilities working together. This is also the host for UI tests. Start with `Examples/MinimalExample/` if you're new — open this once the minimal example makes sense.

1. Open `Advanced.xcodeproj` in Xcode
2. The project references `ManifoldKit` as a local package from `../../`
3. Build and run on iOS Simulator or Mac

### UI test debugging

From the repository root, use the fast rerun loop:

```bash
scripts/example-ui-tests.sh build-for-testing
scripts/example-ui-tests.sh test-without-building -only-testing:AdvancedUITests/ChatFlowUITests/testEmptyStateShowsWelcome
```

The helper auto-selects an available simulator destination. If you need to pin one manually, inspect `xcrun simctl list devices available` and pass `--destination 'platform=iOS Simulator,id=<SIMULATOR_ID>'`.

### Visual walkthrough (screenshot evidence for a design pass)

`AdvancedUITests/VisualWalkthroughUITests` drives the demo through every surface the 2026 UI refresh restyled and writes a numbered screenshot story, for a human comparison against the drawn spec (`docs/design/ui-refresh-2026.html`). Run it by hand whenever the chat surface changes — it is not part of any CI lane:

```bash
scripts/example-ui-tests.sh test -only-testing:AdvancedUITests/VisualWalkthroughUITests
```

Screenshots go to `/private/tmp/manifoldkit-ui-walkthrough` (also attached to the result bundle), and the path is printed at the start of each test. `/private/tmp` is periodically cleared by the system, so copy out anything worth keeping — or point the run somewhere durable:

```bash
scripts/example-ui-tests.sh test \
  -only-testing:AdvancedUITests/VisualWalkthroughUITests \
  TEST_RUNNER_MANIFOLD_WALKTHROUGH_DIR=~/Desktop/walkthrough
```

The `TEST_RUNNER_` prefix is required on a simulator destination — `xcodebuild test` does not propagate plain shell environment variables into the XCUITest runner process.

The suite's finale, `testDefineRealOllamaEndpointAndSendLiveMessage`, is **opt-in and not hermetic**: it launches without `--uitesting` (real backends, real SwiftData store), needs Ollama serving `llama3.1:8b` at `localhost:11434`, and persists an endpoint into the demo's real store. It skips with an explanatory message unless you opt in, matching how this target gates its real-model E2E:

```bash
touch ~/.manifoldkit_ui_walkthrough_live
```

### What This Demonstrates

- Configuring `ManifoldConfiguration` at startup
- Composing `ManifoldUI` views (ChatView, SessionListView, ModelManagementSheet)
- Setting up SwiftData with `ModelContainerFactory`
- Wiring view models via `@Environment`
- Cloud API endpoint management
- Multi-session chat with auto-rename
- Model download and storage management
- Share Extension + Action Extension handoff via App Group (see `Extensions/`)

### Share & Action Extensions

The demo includes two iOS app extensions that hand content into a new chat session:

- **ManifoldDemoShareExtension** — activated from the system Share sheet. Accepts text, URLs, and images.
- **ManifoldDemoActionExtension** — activated from the system action row. Accepts text and URLs.

Both extensions write a `PendingSharePayload` to an App Group `UserDefaults` key. The host app drains it on the next foreground transition and calls `ChatViewModel.ingestPendingPayload(_:intent:)` to open a pre-filled session.

See `docs/share-action-extension-recipe.md` for the full integration guide.

## Focused Examples

Small, purpose-built apps that each showcase a single feature. Open `Examples/ManifoldExamples.xcodeproj` in Xcode and select the scheme for the example you want to run.

| Example | Scheme | What It Shows |
|---------|--------|---------------|
| [MinimalExample](Examples/MinimalExample/) | `MinimalExample_iOS` / `MinimalExample_macOS` | Bare-minimum ManifoldKit app (~40 lines) |

More examples ship alongside new features — see each example's README for details.

## Customization

`quickStart()` already folds in the compiled-in default families (Ollama,
CloudSaaS, and Foundation on macOS 26 / iOS 26). To register them yourself on a
manual bootstrap, import the family modules and call each registrar with the
`InferenceService` from your bootstrap result:

```swift
import ManifoldFoundation
import ManifoldOllama
import ManifoldCloudSaaS

let result = try await ManifoldKit.quickStart()
OllamaBackends.register(with: result.bootstrap.inferenceService)
CloudSaaSBackends.register(with: result.bootstrap.inferenceService)
FoundationBackends.register(with: result.bootstrap.inferenceService)
```
