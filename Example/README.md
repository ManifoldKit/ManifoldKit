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

To add your own backends, import `ManifoldBackends` and call:

```swift
DefaultBackends.register(with: chatViewModel.inferenceService)
```
